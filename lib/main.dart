import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _RangeProxy {
  _RangeProxy._(this._server, this._client, this._target, this._chunkSize);

  final HttpServer _server;
  final HttpClient _client;
  final Uri _target;
  final int _chunkSize;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/media');

  static Future<_RangeProxy> start(Uri target, {required int chunkSize}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient()
      ..userAgent =
          'com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US) gzip';
    final proxy = _RangeProxy._(server, client, target, chunkSize);
    server.listen(proxy._forward);
    return proxy;
  }

  Future<void> _forward(HttpRequest incoming) async {
    try {
      final requested = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(
        incoming.headers.value(HttpHeaders.rangeHeader) ?? 'bytes=0-',
      );
      var cursor = int.parse(requested?.group(1) ?? '0');
      final requestedEnd = requested?.group(2)?.isEmpty ?? true
          ? null
          : int.parse(requested!.group(2)!);

      var upstream = await _fetchChunk(cursor, requestedEnd);
      if (upstream.statusCode != HttpStatus.partialContent) {
        throw HttpException('Medya sunucusu ${upstream.statusCode} döndürdü');
      }
      final contentRange = upstream.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      final parsedRange = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(contentRange ?? '');
      if (parsedRange == null) {
        throw const FormatException('Geçersiz Content-Range');
      }
      final totalLength = int.parse(parsedRange.group(3)!);
      final finalEnd = requestedEnd == null || requestedEnd >= totalLength
          ? totalLength - 1
          : requestedEnd;

      incoming.response.statusCode = HttpStatus.partialContent;
      incoming.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      incoming.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $cursor-$finalEnd/$totalLength',
      );
      incoming.response.contentLength = finalEnd - cursor + 1;
      final contentType = upstream.headers.contentType;
      if (contentType != null) {
        incoming.response.headers.contentType = contentType;
      }

      while (cursor <= finalEnd) {
        final chunkRange = upstream.headers.value(
          HttpHeaders.contentRangeHeader,
        );
        final chunkMatch = RegExp(
          r'^bytes (\d+)-(\d+)/(\d+)$',
        ).firstMatch(chunkRange ?? '');
        if (chunkMatch == null) break;
        final chunkEnd = int.parse(chunkMatch.group(2)!);
        await incoming.response.addStream(upstream);
        cursor = chunkEnd + 1;
        if (cursor <= finalEnd) upstream = await _fetchChunk(cursor, finalEnd);
      }
      await incoming.response.close();
    } catch (_) {
      try {
        incoming.response.statusCode = HttpStatus.badGateway;
        await incoming.response.close();
      } catch (_) {}
    }
  }

  Future<HttpClientResponse> _fetchChunk(int start, int? requestedEnd) async {
    final maximumEnd = start + _chunkSize - 1;
    final end = requestedEnd == null || requestedEnd > maximumEnd
        ? maximumEnd
        : requestedEnd;
    final outgoing = await _client.getUrl(_target);
    outgoing.persistentConnection = false;
    outgoing.headers.set(HttpHeaders.refererHeader, 'https://www.youtube.com/');
    outgoing.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    return outgoing.close();
  }

  Future<void> close() async {
    await _server.close(force: true);
    _client.close(force: true);
  }
}

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
  static const _storage = MethodChannel('com.veligokce.ytcutter/storage');
  final _url = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _yt = YoutubeExplode();
  bool _busy = false;
  bool _audioOnlyJob = false;
  double? _progress;
  String? _lastOutputDirectory;
  String _status = 'Başlamak için video bağlantısını ve zamanları girin.';

  Duration? get _startValue => _parseTime(_start.text);
  Duration? get _endValue => _parseTime(_end.text);

  Duration? _parseTime(String raw) {
    final value = raw.trim();
    final shortDigits = RegExp(r'^(\d{2})(\d{2})$').firstMatch(value);
    final shortSeparated = RegExp(r'^(\d{2})[.:](\d{2})$').firstMatch(value);
    final shortMatch = shortDigits ?? shortSeparated;
    if (shortMatch != null) {
      final minutes = int.parse(shortMatch.group(1)!);
      final seconds = int.parse(shortMatch.group(2)!);
      if (seconds > 59) return null;
      return Duration(minutes: minutes, seconds: seconds);
    }

    return null;
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
    if (Platform.isAndroid) return getTemporaryDirectory();
    if (Platform.isWindows) {
      final downloads = '${Platform.environment['USERPROFILE']}\\Downloads';
      final directory = Directory(downloads);
      if (await directory.exists()) return directory;
    }
    return (await getDownloadsDirectory()) ??
        await getApplicationDocumentsDirectory();
  }

  Future<void> _download({bool audioOnly = false}) async {
    final start = _startValue;
    final end = _endValue;
    if (_url.text.trim().isEmpty || start == null || end == null) {
      _showError(
        'Bağlantı, başlangıç ve bitiş zorunludur. '
        'Zamanı 00.00 veya 0000 biçiminde girin.',
      );
      return;
    }
    if (end <= start) {
      _showError('Bitiş zamanı başlangıçtan büyük olmalıdır.');
      return;
    }

    setState(() {
      _busy = true;
      _audioOnlyJob = audioOnly;
      _progress = null;
      _lastOutputDirectory = null;
      _status = audioOnly
          ? 'Video bilgileri ve en kaliteli ses akışı alınıyor…'
          : 'Video bilgileri ve 720p akışları alınıyor…';
    });

    _RangeProxy? videoProxy;
    _RangeProxy? audioProxy;
    try {
      final video = await _yt.videos
          .get(_url.text.trim())
          .timeout(const Duration(seconds: 30));
      if (video.duration != null && end > video.duration!) {
        throw const FormatException('Bitiş zamanı video süresini aşıyor.');
      }
      final manifest = await _yt.videos.streamsClient
          .getManifest(video.id, ytClients: [YoutubeApiClient.androidVr])
          .timeout(const Duration(seconds: 45));
      final videos =
          manifest.videoOnly
              .where(
                (s) =>
                    s.container == StreamContainer.mp4 &&
                    s.videoResolution.height <= 720 &&
                    s.videoCodec.toString().startsWith('avc1'),
              )
              .toList()
            ..sort((a, b) {
              final resolution = b.videoResolution.height.compareTo(
                a.videoResolution.height,
              );
              return resolution != 0
                  ? resolution
                  : b.bitrate.compareTo(a.bitrate);
            });
      final audios = manifest.audioOnly.toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      if ((!audioOnly && videos.isEmpty) || audios.isEmpty) {
        throw StateError('Uygun 720p MP4 video veya ses akışı bulunamadı.');
      }

      setState(() => _status = 'Güvenli medya bağlantısı hazırlanıyor…');
      if (!audioOnly) {
        videoProxy = await _RangeProxy.start(
          videos.first.url,
          chunkSize: 1024 * 1024,
        );
      }
      audioProxy = await _RangeProxy.start(
        audios.first.url,
        chunkSize: 256 * 1024,
      );

      final directory = await _outputDirectory();
      await directory.create(recursive: true);
      final safeTitle = video.title
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final extension = audioOnly ? 'mp3' : 'mp4';
      final fileName = '${safeTitle}_kesit_$stamp.$extension';
      final output = '${directory.path}${Platform.pathSeparator}$fileName';
      final length = end - start;
      final youtubeUserAgent = _quote(
        'com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US) gzip',
      );
      final youtubeReferer = _quote('https://www.youtube.com/');

      setState(() {
        _progress = 0;
        _status = audioOnly
            ? 'Seçilen ses aralığı yüksek kaliteli MP3’e çevriliyor…'
            : 'Yalnızca seçilen aralık indiriliyor ve birleştiriliyor…';
      });

      // -ss girdilerden önce olduğu için FFmpeg, HTTP range istekleriyle
      // hedef zamana atlar; videonun tamamını indirmez. -c copy kaynak
      // akışlarını yeniden kodlamadan MP4 içinde birleştirir.
      final audioInput =
          '-rw_timeout 30000000 -user_agent $youtubeUserAgent '
          '-referer $youtubeReferer -ss ${_ffTime(start)} '
          '-i ${_quote(audioProxy.url.toString())} ';
      final command = audioOnly
          ? '-y $audioInput-t ${_ffTime(length)} -vn '
                '-codec:a libmp3lame -q:a 0 -id3v2_version 3 ${_quote(output)}'
          : '-y -rw_timeout 30000000 -user_agent $youtubeUserAgent '
                '-referer $youtubeReferer -ss ${_ffTime(start)} '
                '-i ${_quote(videoProxy!.url.toString())} $audioInput'
                '-t ${_ffTime(length)} -map 0:v:0 -map 1:a:0 -c copy '
                '-avoid_negative_ts make_zero -movflags +faststart '
                '${_quote(output)}';

      final completion = Completer<bool>();
      String? ffmpegError;
      final session = await FFmpegKit.executeAsync(
        command,
        (finishedSession) async {
          final returnCode = await finishedSession.getReturnCode();
          final success = ReturnCode.isSuccess(returnCode);
          if (!success) {
            final logs = await finishedSession.getAllLogsAsString() ?? '';
            ffmpegError =
                logs.contains('403 Forbidden') || logs.contains('access denied')
                ? 'YouTube medya bağlantısını reddetti. Lütfen tekrar deneyin.'
                : '${audioOnly ? 'Ses' : 'Video'} işlemi tamamlanamadı. İnternet bağlantısını kontrol edip tekrar deneyin.';
          }
          if (!completion.isCompleted) completion.complete(success);
        },
        null,
        (statistics) {
          if (!mounted || length.inMilliseconds == 0) return;
          final ratio = (statistics.getTime() / length.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
          setState(() {
            _progress = ratio;
            _status = 'Seçilen aralık indiriliyor… %${(ratio * 100).round()}';
          });
        },
      );
      final timeoutSeconds = (120 + length.inSeconds * 2)
          .clamp(120, 900)
          .toInt();
      late bool success;
      try {
        success = await completion.future.timeout(
          Duration(seconds: timeoutSeconds),
        );
      } on TimeoutException {
        await FFmpegKit.cancel(session.getSessionId());
        throw TimeoutException(
          'İşlem beklenenden uzun sürdü ve durduruldu. İnternet bağlantısını kontrol edip tekrar deneyin.',
        );
      }
      if (!success) {
        throw StateError(ffmpegError ?? 'Video işlemi tamamlanamadı.');
      }
      var savedLocation = output;
      if (Platform.isAndroid) {
        await _storage.invokeMethod<String>('saveToDownloads', {
          'path': output,
          'name': fileName,
          'mimeType': audioOnly ? 'audio/mpeg' : 'video/mp4',
        });
        final temporaryFile = File(output);
        if (await temporaryFile.exists()) await temporaryFile.delete();
        savedLocation = 'Download/YTCutter/$fileName';
      }
      setState(() {
        _progress = 1;
        _status = 'Tamamlandı: $savedLocation';
        _lastOutputDirectory = Platform.isAndroid
            ? 'Download/YTCutter'
            : directory.path;
      });
    } on FormatException catch (error) {
      _showError(error.message);
    } on TimeoutException catch (error) {
      _showError(error.message ?? 'Bağlantı zaman aşımına uğradı.');
    } on StateError catch (error) {
      _showError(error.message);
    } catch (error) {
      _showError('${audioOnly ? 'Ses' : 'Video'} indirilemedi: $error');
    } finally {
      await videoProxy?.close();
      await audioProxy?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openOutputDirectory() async {
    try {
      if (Platform.isAndroid) {
        await _storage.invokeMethod<void>('openDownloads');
      } else if (Platform.isWindows && _lastOutputDirectory != null) {
        await Process.start('explorer.exe', [_lastOutputDirectory!]);
      }
    } catch (_) {
      _showError('İndirilenler klasörü açılamadı.');
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
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) => SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.symmetric(
              horizontal: viewport.maxWidth < 420 ? 12 : 24,
              vertical: 16,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Card(
                  elevation: 12,
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(
                          Icons.content_cut_rounded,
                          size: 54,
                          color: Color(0xffef4444),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'YT Cutter',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Videonun tamamını indirmeden istediğiniz bölümü alın.',
                          textAlign: TextAlign.center,
                        ),
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
                        LayoutBuilder(
                          builder: (context, fields) => fields.maxWidth < 360
                              ? Column(
                                  children: [
                                    _timeField(_start, 'Başlangıç'),
                                    const SizedBox(height: 14),
                                    _timeField(_end, 'Bitiş'),
                                  ],
                                )
                              : Row(
                                  children: [
                                    Expanded(
                                      child: _timeField(_start, 'Başlangıç'),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(child: _timeField(_end, 'Bitiş')),
                                  ],
                                ),
                        ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .05),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.timer_outlined),
                              const SizedBox(width: 10),
                              const Expanded(child: Text('Kesit süresi:')),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _durationLabel(),
                                  textAlign: TextAlign.end,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 17,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xffef4444,
                            ).withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(
                                0xffef4444,
                              ).withValues(alpha: .22),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.speed_rounded,
                                color: Color(0xffef4444),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text('Tahmini işlem süresi:'),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _estimateLabel(),
                                  textAlign: TextAlign.end,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        LayoutBuilder(
                          builder: (context, buttons) {
                            final mp4Button = FilledButton.icon(
                              onPressed: _busy ? null : () => _download(),
                              icon: _busy && !_audioOnlyJob
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.video_file_rounded),
                              label: Text(
                                _busy && !_audioOnlyJob
                                    ? 'İşleniyor…'
                                    : '720p MP4 indir',
                              ),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                              ),
                            );
                            final mp3Button = OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _download(audioOnly: true),
                              icon: _busy && _audioOnlyJob
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.audio_file_rounded),
                              label: Text(
                                _busy && _audioOnlyJob
                                    ? 'İşleniyor…'
                                    : 'MP3 indir',
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                              ),
                            );
                            if (buttons.maxWidth < 430) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  mp4Button,
                                  const SizedBox(height: 10),
                                  mp3Button,
                                ],
                              );
                            }
                            return Row(
                              children: [
                                Expanded(child: mp4Button),
                                const SizedBox(width: 10),
                                Expanded(child: mp3Button),
                              ],
                            );
                          },
                        ),
                        if (_progress != null) ...[
                          const SizedBox(height: 16),
                          LinearProgressIndicator(value: _progress),
                        ],
                        const SizedBox(height: 14),
                        Text(
                          _status,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (_lastOutputDirectory != null) ...[
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _openOutputDirectory,
                            icon: const Icon(Icons.folder_open_rounded),
                            label: const Text('Klasöre git'),
                          ),
                        ],
                      ],
                    ),
                  ),
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
      scrollPadding: const EdgeInsets.only(bottom: 140),
      maxLength: 5,
      decoration: InputDecoration(
        labelText: '$label (Dakika.Saniye)',
        hintText: '00.00',
        helperText: '00.00 veya 0000',
        counterText: '',
        border: const OutlineInputBorder(),
      ),
    );
  }
}
