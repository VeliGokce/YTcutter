import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main() async {
  final yt = YoutubeExplode();
  try {
    final video = await yt.videos.get('https://www.youtube.com/watch?v=jNQXAC9IVRw');
    final manifest = await yt.videos.streamsClient.getManifest(video.id);
    final video720 = manifest.videoOnly
        .where((s) => s.container == StreamContainer.mp4 && s.videoResolution.height <= 720)
        .length;
    final audio = manifest.audioOnly.where((s) => s.container == StreamContainer.mp4).length;
    print('title=${video.title}; duration=${video.duration}; video720=$video720; audio=$audio');
    if (video720 == 0 || audio == 0) throw StateError('Suitable streams not found');
    final videoStream = manifest.videoOnly
        .where((s) => s.container == StreamContainer.mp4 && s.videoResolution.height <= 720)
        .reduce((a, b) => a.bitrate.compareTo(b.bitrate) > 0 ? a : b);
    final audioStream = manifest.audioOnly
        .where((s) => s.container == StreamContainer.mp4)
        .reduce((a, b) => a.bitrate.compareTo(b.bitrate) > 0 ? a : b);
    final output = File('${Directory.systemTemp.path}\\yt-cutter-smoke.mp4');
    if (output.existsSync()) output.deleteSync();
    final result = await Process.run('C:\\ffmpeg\\bin\\ffmpeg.exe', [
      '-y', '-ss', '00:00:03', '-i', videoStream.url.toString(),
      '-ss', '00:00:03', '-i', audioStream.url.toString(),
      '-t', '00:00:05', '-map', '0:v:0', '-map', '1:a:0',
      '-c', 'copy', '-movflags', '+faststart', output.path,
    ]);
    if (result.exitCode != 0 || !output.existsSync()) {
      throw StateError('FFmpeg cut failed: ${result.stderr}');
    }
    print('cut=${output.path}; bytes=${output.lengthSync()}');
  } finally {
    yt.close();
  }
}
