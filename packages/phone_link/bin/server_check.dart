// Read-only check of PhoneFileServer the way a video player uses it, with
// curl: open (Range 0-), hang up after 1 MB, jump to the end, switch to a
// second video. Prints headers and timings. Nothing on the phone changes.
// Usage: dart run bin/server_check.dart <adb.exe> <serial>
import 'dart:io';

import 'package:phone_link/phone_link.dart';

Future<void> main(List<String> args) async {
  final adb = Adb(args[0]);
  final serial = args[1];
  final videos = (await adb.listFiles(serial)).where((f) => f.isVideo && f.bytes > 50 << 20).toList()
    ..sort((a, b) => b.bytes.compareTo(a.bytes));
  final server = await PhoneFileServer.start(PhoneStreamer(adb.adbPath, serial));

  Future<void> curl(String label, PhoneFile f, String range, {int? maxBytes}) async {
    final url = server.urlFor(f).toString();
    final sw = Stopwatch()..start();
    final r = await Process.run('curl.exe', [
      '-s', '-D', '-', '-o', 'NUL', '-r', range,
      if (maxBytes != null) ...['--max-filesize', '$maxBytes', '--limit-rate', '20M', '-m', '3'],
      '-w', 'GOT %{size_download} bytes, first byte after %{time_starttransfer}s\n',
      url,
    ]);
    final head = (r.stdout as String).split('\n').where((l) =>
        l.startsWith('HTTP/') || l.toLowerCase().startsWith('content-') || l.toLowerCase().startsWith('accept-') ||
        l.toLowerCase().startsWith('transfer-') || l.startsWith('GOT'));
    print('— $label (${sw.elapsedMilliseconds} ms, server busy with ${server.active} request(s) after)');
    for (final l in head) {
      print('   ${l.trim()}');
    }
  }

  final a = videos[0], b = videos[1];
  print('Video A ${(a.bytes / (1 << 20)).round()} MB, video B ${(b.bytes / (1 << 20)).round()} MB');
  await curl('A: open, then hang up after ~1 MB (like a player seeking)', a, '0-', maxBytes: 3 << 20);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await curl('A: the last 64 KB (where the index often is)', a, '${a.bytes - 65536}-');
  await curl('A: 1 MB from the middle', a, '${a.bytes ~/ 2}-${a.bytes ~/ 2 + (1 << 20) - 1}');
  await curl('B: switch videos, open, hang up after ~1 MB', b, '0-', maxBytes: 3 << 20);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  print('Requests still being served after everyone hung up: ${server.active}');
  await server.close();
  await server.streamer.close();
  print('Nothing on the phone was changed.');
}
