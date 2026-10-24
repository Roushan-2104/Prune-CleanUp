// Measures batched copy speed on a real phone. Read-only on the phone: it
// only copies files *to* the laptop.
//
// Usage: dart run bin/copy_speed.dart <adb.exe> <output folder> [count]
import 'dart:io';

import 'package:phone_link/phone_link.dart';

Future<void> main(List<String> args) async {
  final adb = Adb(args[0]);
  final out = args[1];
  final count = args.length > 2 ? int.parse(args[2]) : 300;
  final phone = (await adb.devices()).where((d) => d.ready).first;

  final files = (await adb.listFiles(phone.serial)).where((f) => f.isImage || f.isVideo).toList()
    ..sort((a, b) => b.modifiedSec.compareTo(a.modifiedSec));
  final sample = files.where((f) => f.bytes < 150 << 20).take(count).toList();
  final total = sample.fold(0, (s, f) => s + f.bytes);
  print('Copying ${sample.length} newest photos/videos (${(total / (1 << 20)).toStringAsFixed(0)} MB) in batches…');

  final sw = Stopwatch()..start();
  final report = await adb.copyManyToLaptop(
    phone.serial,
    sample,
    (f) => '$out${Platform.pathSeparator}${f.folder.replaceAll('/', Platform.pathSeparator)}${f.name}',
    onProgress: (n, b) => stdout.write('\r  $n/${sample.length} files'),
  );
  final secs = sw.elapsedMilliseconds / 1000;
  print('\nCopied ${report.copied.length} files, ${(report.bytes / (1 << 20)).toStringAsFixed(0)} MB in '
      '${secs.toStringAsFixed(1)} s = ${(report.bytes / (1 << 20) / secs).toStringAsFixed(1)} MB/s, '
      '${(report.copied.length / secs).toStringAsFixed(0)} files/s');
  if (report.failed.isNotEmpty) print('Failed: ${report.failed.length}, e.g. ${report.failed.values.first}');
  print('Nothing on the phone was changed.');
}
