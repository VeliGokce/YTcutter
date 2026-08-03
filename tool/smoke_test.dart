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
      ..userAgent = 'com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US) gzip';
    final proxy = RangeProxy._(server, client, target, chunkSize);
    server.listen(proxy.forward);
    return proxy;
  }

  Future<void> forward(HttpRequest incoming) async {
    final outgoing = await client.openUrl(incoming.method, target);
    outgoing.headers.set(HttpHeaders.refererHeader, 'https://www.youtube.com/');
    final range = incoming.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range.trim());
      if (match != null) {
        final start = int.parse(match.group(1)!);
        final rawEnd = match.group(2)!;
        final requestedEnd = rawEnd.isEmpty ? null : int.parse(rawEnd);
        final maximumEnd = start + chunkSize - 1;
        final end = requestedEnd == null || requestedEnd > maximumEnd
            ? maximumEnd
            : requestedEnd;
        outgoing.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      } else {
        outgoing.headers.set(HttpHeaders.rangeHeader, range);
      }
    } else {
      outgoing.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${chunkSize - 1}');
    }
    final upstream = await outgoing.close();
    print('proxy ${incoming.method} incomingRange=$range '
        'outgoingRange=${outgoing.headers.value(HttpHeaders.rangeHeader)} '
        'status=${upstream.statusCode}');
    incoming.response.statusCode = upstream.statusCode;
    upstream.headers.forEach((name, values) {
      if ({'accept-ranges', 'content-length', 'content-range', 'content-type'}.contains(name)) {
        incoming.response.headers.set(name, values.join(', '));
      }
    });
    await upstream.pipe(incoming.response);
  }

  Future<void> close() async {
    await server.close(force: true);
    client.close(force: true);
  }
}

Future<int> probe(Uri url) async {
  final client = HttpClient();
  client.userAgent = 'com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US) gzip';
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
    final video = await yt.videos.get(url);
    final manifest = await yt.videos.streamsClient.getManifest(video.id);
    print('title=${video.title}; duration=${video.duration}');
    for (final stream in manifest.videoOnly) {
      final status = await probe(stream.url);
      print('video itag=${stream.tag} ${stream.container} ${stream.videoResolution.height}p '
          '${stream.videoCodec} status=$status');
    }
    for (final stream in manifest.audioOnly) {
      final status = await probe(stream.url);
      print('audio itag=${stream.tag} ${stream.container} ${stream.audioCodec} status=$status');
    }
    for (final stream in manifest.muxed) {
      final status = await probe(stream.url);
      print('muxed itag=${stream.tag} ${stream.container} ${stream.videoResolution.height}p '
          'status=$status');
    }

    final selectedVideo = manifest.videoOnly.firstWhere(
      (s) => s.container == StreamContainer.mp4 && s.videoResolution.height == 720,
    );
    final selectedAudio = manifest.audioOnly.firstWhere(
      (s) => s.container == StreamContainer.mp4,
    );
    final videoProxy = await RangeProxy.start(
      selectedVideo.url,
      chunkSize: 1024 * 1024,
    );
    final audioProxy = await RangeProxy.start(
      selectedAudio.url,
      chunkSize: 64 * 1024,
    );
    final output = File('${Directory.systemTemp.path}\\yt-cutter-proxy-smoke.mp4');
    try {
      if (output.existsSync()) output.deleteSync();
      final result = await Process.run('C:\\ffmpeg\\bin\\ffmpeg.exe', [
        '-y', '-ss', '00:00:03', '-i', videoProxy.url.toString(),
        '-ss', '00:00:03', '-i', audioProxy.url.toString(),
        '-t', '00:00:05', '-map', '0:v:0', '-map', '1:a:0',
        '-c', 'copy', '-movflags', '+faststart', output.path,
      ]);
      if (result.exitCode != 0 || !output.existsSync()) {
        throw StateError('Proxy FFmpeg cut failed: ${result.stderr}');
      }
      print('proxy-cut bytes=${output.lengthSync()}');
    } finally {
      await videoProxy.close();
      await audioProxy.close();
      if (output.existsSync()) output.deleteSync();
    }
  } finally {
    yt.close();
  }
}
