import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() => runApp(const YtCutterApp());

class YtCutterApp extends StatelessWidget {
  const YtCutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'YT Cutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffef4444),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff0f1115),
        useMaterial3: true,
      ),
      home: const CutterPage(),
    );
  }
}

class CutterPage extends StatefulWidget {
  const CutterPage({super.key});

  @override
  State<CutterPage> createState() => _CutterPageState();
}

class _CutterPageState extends State<CutterPage> {
  final _url = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _yt = YoutubeExplode();
  bool _busy = false;
  double? _progress;
  String _status = 'Başlamak için video bağlantısını ve zamanları girin.';

  Duration? get _startValue => _parseTime(_start.text);
  Duration? get _endValue => _parseTime(_end.text);

  Duration? _parseTime(String raw) {
    final match = RegExp(r'^(\d{2})[.:](\d{2})[.:](\d{2})$').firstMatch(raw.trim());
    if (match == null) return null;
    final hours = int.parse(match.group(1)!);
    final minutes = int.parse(match.group(2)!);
    final seconds = int.parse(match.group(3)!);
    if (minutes > 59 || seconds > 59) return null;
    return Duration(hours: hours, minutes: minutes, seconds: seconds);
  }

  String _durationLabel() {
    final start = _startValue;
    final end = _endValue;
    if (start == null || end == null || end <= start) return '—';
    final value = end - start;
    final parts = <String>[];
    if (value.inHours > 0) parts.add('${value.inHours} sa');
    if (value.inMinutes.remainder(60) > 0) {
      parts.add('${value.inMinutes.remainder(60)} dk');
    }
    if (value.inSeconds.remainder(60) > 0 || parts.isEmpty) {
      parts.add('${value.inSeconds.remainder(60)} sn');
    }
    return parts.join(' ');
  }

  String _estimateLabel() {
    final start = _startValue;
    final end = _endValue;
    if (start == null || end == null || end <= start) return '—';

    final clipSeconds = (end - start).inSeconds;
    // Bağlantı/YouTube hazırlık payı ile kesit uzunluğuna bağlı aktarım
    // süresini bir aralık olarak sunar; bu bir geri sayım değildir.
    final minimum = (8 + clipSeconds * .30).round().clamp(10, 3600).toInt();
    final maximum = (15 + clipSeconds * .75).round().clamp(15, 7200).toInt();
    return '${_compactTime(minimum)} – ${_compactTime(maximum)}';
  }

  String _compactTime(int totalSeconds) {
    if (totalSeconds < 60) return '$totalSeconds sn';
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds.remainder(60);
    return seconds == 0 ? '$minutes dk' : '$minutes dk $seconds sn';
  }

  String _ffTime(Duration value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.inHours)}:${two(value.inMinutes.remainder(60))}:${two(value.inSeconds.remainder(60))}';
  }

  String _quote(String value) => '"${value.replaceAll('"', r'\"')}"';

  Future<Directory> _outputDirectory() async {
    if (Platform.isWindows) {
      final downloads = '${Platform.environment['USERPROFILE']}\\Downloads';
      final directory = Directory(downloads);
      if (await directory.exists()) return directory;
    }
    return (await getDownloadsDirectory()) ?? await getApplicationDocumentsDirectory();
  }

  Future<void> _download() async {
    final start = _startValue;
    final end = _endValue;
    if (_url.text.trim().isEmpty || start == null || end == null) {
      _showError('Bağlantı, başlangıç ve bitiş zorunludur. Zaman biçimi: 00.00.00');
      return;
    }
    if (end <= start) {
      _showError('Bitiş zamanı başlangıçtan büyük olmalıdır.');
      return;
    }

    setState(() {
      _busy = true;
      _progress = null;
      _status = 'Video bilgileri ve 720p akışları alınıyor…';
    });

    try {
      final video = await _yt.videos
          .get(_url.text.trim())
          .timeout(const Duration(seconds: 30));
      if (video.duration != null && end > video.duration!) {
        throw const FormatException('Bitiş zamanı video süresini aşıyor.');
      }
      final manifest = await _yt.videos.streamsClient
          .getManifest(video.id)
          .timeout(const Duration(seconds: 45));
      final videos = manifest.videoOnly
          .where((s) => s.container == StreamContainer.mp4 && s.videoResolution.height <= 720)
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      final audios = manifest.audioOnly
          .where((s) => s.container == StreamContainer.mp4)
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      if (videos.isEmpty || audios.isEmpty) {
        throw StateError('Uygun 720p MP4 video veya ses akışı bulunamadı.');
      }

      final directory = await _outputDirectory();
      await directory.create(recursive: true);
      final safeTitle = video.title
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final output = '${directory.path}${Platform.pathSeparator}${safeTitle}_kesit_$stamp.mp4';
      final length = end - start;

      setState(() {
        _progress = 0;
        _status = 'Yalnızca seçilen aralık indiriliyor ve birleştiriliyor…';
      });

      // -ss girdilerden önce olduğu için FFmpeg, HTTP range istekleriyle
      // hedef zamana atlar; videonun tamamını indirmez. -c copy kaynak
      // akışlarını yeniden kodlamadan MP4 içinde birleştirir.
      final command = '-y -rw_timeout 30000000 -ss ${_ffTime(start)} '
          '-i ${_quote(videos.first.url.toString())} '
          '-rw_timeout 30000000 -ss ${_ffTime(start)} '
          '-i ${_quote(audios.first.url.toString())} '
          '-t ${_ffTime(length)} -map 0:v:0 -map 1:a:0 -c copy -movflags +faststart '
          '${_quote(output)}';

      final completion = Completer<FFmpegSession>();
      final session = await FFmpegKit.executeAsync(
        command,
        (finishedSession) {
          if (!completion.isCompleted) completion.complete(finishedSession);
        },
        null,
        (statistics) {
          if (!mounted || length.inMilliseconds == 0) return;
          final ratio = (statistics.getTime() / length.inMilliseconds).clamp(0.0, 1.0);
          setState(() {
            _progress = ratio;
            _status = 'Seçilen aralık indiriliyor… %${(ratio * 100).round()}';
          });
        },
      );
      final timeoutSeconds = (120 + length.inSeconds * 2).clamp(120, 900).toInt();
      late FFmpegSession finishedSession;
      try {
        finishedSession = await completion.future.timeout(Duration(seconds: timeoutSeconds));
      } on TimeoutException {
        await FFmpegKit.cancel(session.getSessionId());
        throw TimeoutException(
          'İşlem beklenenden uzun sürdü ve durduruldu. İnternet bağlantısını kontrol edip tekrar deneyin.',
        );
      }
      final returnCode = await finishedSession.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await finishedSession.getAllLogsAsString();
        throw StateError('FFmpeg işlemi tamamlanamadı.\n$logs');
      }
      setState(() {
        _progress = 1;
        _status = 'Tamamlandı: $output';
      });
    } on FormatException catch (error) {
      _showError(error.message);
    } on TimeoutException catch (error) {
      _showError(error.message ?? 'Bağlantı zaman aşımına uğradı.');
    } catch (error) {
      _showError('Video indirilemedi: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade800),
    );
  }

  @override
  void dispose() {
    _url.dispose();
    _start.dispose();
    _end.dispose();
    _yt.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Card(
              elevation: 12,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.content_cut_rounded, size: 54, color: Color(0xffef4444)),
                    const SizedBox(height: 12),
                    Text('YT Cutter', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 6),
                    const Text('Videonun tamamını indirmeden istediğiniz bölümü alın.', textAlign: TextAlign.center),
                    const SizedBox(height: 28),
                    TextField(
                      controller: _url,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'YouTube video bağlantısı',
                        hintText: 'https://www.youtube.com/watch?v=...',
                        prefixIcon: Icon(Icons.link),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(child: _timeField(_start, 'Başlangıç')),
                        const SizedBox(width: 14),
                        Expanded(child: _timeField(_end, 'Bitiş')),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .05), borderRadius: BorderRadius.circular(10)),
                      child: Row(
                        children: [
                          const Icon(Icons.timer_outlined),
                          const SizedBox(width: 10),
                          const Text('Kesit süresi:'),
                          const Spacer(),
                          Text(_durationLabel(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xffef4444).withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xffef4444).withValues(alpha: .22)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.speed_rounded, color: Color(0xffef4444)),
                          const SizedBox(width: 10),
                          const Text('Tahmini işlem süresi:'),
                          const Spacer(),
                          Text(
                            _estimateLabel(),
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _busy ? null : _download,
                      icon: _busy
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download_rounded),
                      label: Text(_busy ? 'İşleniyor…' : '720p MP4 indir'),
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                    ),
                    if (_progress != null) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(value: _progress),
                    ],
                    const SizedBox(height: 14),
                    Text(_status, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _timeField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      enabled: !_busy,
      onChanged: (_) => setState(() {}),
      keyboardType: TextInputType.datetime,
      maxLength: 8,
      decoration: InputDecoration(
        labelText: label,
        hintText: '00.00.00',
        counterText: '',
        prefixIcon: const Icon(Icons.schedule),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
