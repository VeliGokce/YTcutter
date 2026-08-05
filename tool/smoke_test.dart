import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class RangeProxy {
  RangeProxy._(this.server, this.client, this.target, this.chunkSize);
  final HttpServer server;
  final HttpClient client;
  final Uri target;
  final int chunkSize;
  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/media');

  static Future<RangeProxy> start(Uri target, {required int chunkSize}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient()
      ..userAgent =
          'com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US) gzip';
    final proxy = RangeProxy._(server, client, target, chunkSize);
    server.listen(proxy.forward);
    return proxy;
  }

  Future<void> forward(HttpRequest incoming) async {
    try {
      final requested = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(
        incoming.headers.value(HttpHeaders.rangeHeader) ?? 'bytes=0-',
      );
      var cursor = int.parse(requested?.group(1) ?? '0');
      final requestedEnd = requested?.group(2)?.isEmpty ?? true
          ? null
          : int.parse(requested!.group(2)!);
      final totalLength = int.parse(target.queryParameters['clen']!);
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
      while (cursor <= finalEnd) {
        final chunkEnd = (cursor + chunkSize - 1).clamp(cursor, finalEnd);
        final upstream = await fetchChunk(cursor, chunkEnd);
        if (upstream.statusCode != HttpStatus.partialContent) {
          throw const HttpException('Invalid upstream chunk response');
        }
        await incoming.response.addStream(upstream);
        cursor = chunkEnd + 1;
      }
      await incoming.response.close();
    } catch (_) {
      try {
        incoming.response.statusCode = HttpStatus.badGateway;
        await incoming.response.close();
      } catch (_) {}
    }
  }

  Future<HttpClientResponse> fetchChunk(int start, int end) async {
    final outgoing = await client.getUrl(target);
    outgoing.persistentConnection = false;
    outgoing.headers.set(HttpHeaders.refererHeader, 'https://www.youtube.com/');
    outgoing.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final response = await outgoing.close();
    print('chunk bytes=$start-$end status=${response.statusCode} '
        'contentRange=${response.headers.value(HttpHeaders.contentRangeHeader)}');
    return response;
  }

  Future<void> close() async {
    await server.close(force: true);
    client.close(force: true);
  }
}

Future<int> probe(Uri url) async {
  final client = HttpClient();
  client.userAgent =
      'com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US) gzip';
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    request.headers.set(HttpHeaders.refererHeader, 'https://www.youtube.com/');
    final response = await request.close().timeout(const Duration(seconds: 15));
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final yt = YoutubeExplode();
  try {
    final url = args.isEmpty
        ? 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
        : args.first;
    final startSeconds = args.length > 1 ? int.parse(args[1]) : 0;
    final quality = args.length > 2 ? int.parse(args[2]) : 720;
    final video = await yt.videos.get(url);
    final manifest = await yt.videos.streamsClient.getManifest(
      video.id,
      ytClients: [YoutubeApiClient.androidVr],
    );
    print('title=${video.title}; duration=${video.duration}');
    for (final stream in manifest.videoOnly) {
      final status = await probe(stream.url);
      print(
          'video itag=${stream.tag} ${stream.container} ${stream.videoResolution.height}p '
          '${stream.videoCodec} status=$status');
    }
    for (final stream in manifest.audioOnly) {
      final status = await probe(stream.url);
      print(
          'audio itag=${stream.tag} ${stream.container} ${stream.audioCodec} status=$status');
    }
    for (final stream in manifest.muxed) {
      final status = await probe(stream.url);
      print(
          'muxed itag=${stream.tag} ${stream.container} ${stream.videoResolution.height}p '
          'status=$status');
    }

    final selectedVideo = manifest.videoOnly.firstWhere(
      (s) =>
          s.container == StreamContainer.mp4 &&
          s.videoResolution.height == quality &&
          s.videoCodec.toString().startsWith('avc1'),
    );
    final audioCandidates = manifest.audioOnly
        .where(
          (s) =>
              s.container == StreamContainer.mp4 &&
              s.audioCodec.toString().startsWith('mp4a'),
        )
        .toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final selectedAudio = audioCandidates.first;
    print(
        'video query keys=${selectedVideo.url.queryParameters.keys.toList()}');
    final videoProxy = await RangeProxy.start(
      selectedVideo.url,
      chunkSize: 1024 * 1024,
    );
    final audioProxy = await RangeProxy.start(
      selectedAudio.url,
      chunkSize: 256 * 1024,
    );
    final output =
        File('${Directory.systemTemp.path}\\yt-cutter-proxy-smoke.mp4');
    final audioOutput =
        File('${Directory.systemTemp.path}\\yt-cutter-proxy-smoke.mp3');
    try {
      if (output.existsSync()) output.deleteSync();
      if (audioOutput.existsSync()) audioOutput.deleteSync();
      final stopwatch = Stopwatch()..start();
      final result = await Process.run('C:\\ffmpeg\\bin\\ffmpeg.exe', [
        '-y',
        '-ss',
        startSeconds.toString(),
        '-i',
        videoProxy.url.toString(),
        '-ss',
        startSeconds.toString(),
        '-i',
        audioProxy.url.toString(),
        '-t',
        '00:00:33',
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-c',
        'copy',
        '-avoid_negative_ts',
        'make_zero',
        '-movflags',
        '+faststart',
        output.path,
      ]);
      stopwatch.stop();
      if (result.exitCode != 0 || !output.existsSync()) {
        throw StateError('Proxy FFmpeg cut failed: ${result.stderr}');
      }
      final blackScan = await Process.run('C:\\ffmpeg\\bin\\ffmpeg.exe', [
        '-i',
        output.path,
        '-vf',
        'blackdetect=d=1:pix_th=0.98',
        '-an',
        '-f',
        'null',
        '-',
      ]);
      final blackLines = blackScan.stderr
          .toString()
          .split(RegExp(r'[\r\n]+'))
          .where((line) => line.contains('black_start'))
          .toList();
      print(
          'proxy-cut bytes=${output.lengthSync()} elapsed=${stopwatch.elapsed} '
          'blackSegments=${blackLines.length}');
      for (final line in blackLines) {
        print(line);
      }
      final audioResult = await Process.run('C:\\ffmpeg\\bin\\ffmpeg.exe', [
        '-y',
        '-ss',
        startSeconds.toString(),
        '-i',
        audioProxy.url.toString(),
        '-t',
        '00:00:33',
        '-vn',
        '-codec:a',
        'libmp3lame',
        '-q:a',
        '0',
        '-id3v2_version',
        '3',
        audioOutput.path,
      ]);
      if (audioResult.exitCode != 0 || !audioOutput.existsSync()) {
        throw StateError('Proxy MP3 cut failed: ${audioResult.stderr}');
      }
      print('proxy-mp3 bytes=${audioOutput.lengthSync()}');
    } finally {
      await videoProxy.close();
      await audioProxy.close();
      if (output.existsSync()) output.deleteSync();
      if (audioOutput.existsSync()) audioOutput.deleteSync();
    }
  } finally {
    yt.close();
  }
}
