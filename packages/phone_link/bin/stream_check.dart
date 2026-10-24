// Read-only check of PhoneStreamer on a real phone: reads slices of the
// biggest video (start, end, middle), compares them with direct dd reads,
// and times them. Usage: dart run bin/stream_check.dart <adb.exe> [serial]
import 'dart:io';

import 'package:phone_link/phone_link.dart';

Future<void> main(List<String> args) async {
  final adb = Adb(args[0]);
  final serial = args.length > 1 ? args[1] : (await adb.devices()).firstWhere((d) => d.ready).serial;
  final videos = (await adb.listFiles(serial)).where((f) => f.isVideo).toList()..sort((a, b) => b.bytes.compareTo(a.bytes));
  final v = videos.first;
  print('Video: ${(v.bytes / (1 << 20)).toStringAsFixed(0)} MB');
  final s = PhoneStreamer(adb.adbPath, serial);

  Future<void> timed(String label, int offset, int length) async {
    final sw = Stopwatch()..start();
    final data = await s.read(v.path, v.bytes, offset, length);
    print('$label: ${data.length} bytes in ${sw.elapsedMilliseconds} ms');
  }

  await timed('first read (opens connection), 64 KB at start', 0, 64 << 10);
  await timed('64 KB at the end', v.bytes - (64 << 10), 64 << 10);
  await timed('4 MB in the middle', v.bytes ~/ 2, 4 << 20);
  await timed('same 4 MB again (from memory)', v.bytes ~/ 2, 4 << 20);
  s.readAhead(v.path, v.bytes, v.bytes ~/ 4, 4 << 20);
  await Future<void>.delayed(const Duration(seconds: 1));
  await timed('4 MB that was read ahead', v.bytes ~/ 4, 4 << 20);

  // Correctness: compare a slice with a direct one-off dd read.
  final off = 3 * PhoneStreamer.blockSize + 123;
  final mine = await s.read(v.path, v.bytes, off, 1000);
  final r = await Process.run(adb.adbPath,
      ['-s', serial, 'exec-out', 'dd if=${shellQuote(v.path)} bs=1 skip=$off count=1000 status=none'],
      stdoutEncoding: null);
  final direct = r.stdout as List<int>;
  var same = mine.length == direct.length;
  for (var i = 0; same && i < mine.length; i++) {
    same = mine[i] == direct[i];
  }
  print('Bytes identical to a direct read: $same');

  // The case that failed in the app: watch video A for a while (reading
  // 1 MB at a time with read-ahead, like the player), then switch to B.
  final b = videos[1];
  s.focus(v.path);
  var pos = 0;
  for (var i = 0; i < 40 && pos < v.bytes; i++) {
    await s.read(v.path, v.bytes, pos, 1 << 20);
    pos += 1 << 20;
    s.readAhead(v.path, v.bytes, pos, 2 << 20);
  }
  s.focus(b.path);
  final sw = Stopwatch()..start();
  await s.read(b.path, b.bytes, 0, 64 << 10);
  print('After watching 40 MB of video A, first 64 KB of video B: ${sw.elapsedMilliseconds} ms');
  sw.reset();
  await s.read(b.path, b.bytes, b.bytes - (64 << 10), 64 << 10);
  print('…and the end of video B (where its index often is): ${sw.elapsedMilliseconds} ms');
  await s.close();
  print('Nothing on the phone was changed.');
}
