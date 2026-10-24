// Day-1 proof of concept: connect, read storage, list everything, and copy a
// small sample to the laptop — all strictly read-only on the phone.
//
// Usage: dart run bin/probe.dart <adb.exe> <output folder> [sample size]
import 'dart:io';

import 'package:phone_link/phone_link.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: probe <adb.exe> <output folder> [sample size]');
    exit(64);
  }
  final adb = Adb(args[0]);
  final out = Directory(args[1]);
  final sampleSize = args.length > 2 ? int.parse(args[2]) : 20;

  try {
    final phones = await adb.devices();
    if (phones.isEmpty) return fail('No phone found. Plug it in with USB debugging on.');
    final phone = phones.first;
    if (!phone.ready) {
      return fail('Phone is "${phone.state}". Unlock it and tap "Allow USB debugging".');
    }

    final info = await adb.info(phone.serial);
    print('Phone: ${info.brand} ${info.model}, Android ${info.androidVersion}');
    print('Storage: ${gb(info.usedBytes)} used of ${gb(info.totalBytes)} (${gb(info.freeBytes)} free)');

    final sw = Stopwatch()..start();
    final files = await adb.listFiles(phone.serial);
    print('Listed ${files.length} files in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
    for (final (label, test) in [
      ('photos', (PhoneFile f) => f.isImage),
      ('videos', (PhoneFile f) => f.isVideo),
      ('audio', (PhoneFile f) => f.isAudio),
      ('other files', (PhoneFile f) => !f.isImage && !f.isVideo && !f.isAudio),
    ]) {
      final group = files.where(test);
      print('  $label: ${group.length} · ${gb(group.fold(0, (s, f) => s + f.bytes))}');
    }

    // Sample: newest photos plus a few videos, to measure real copy speed.
    final byNewest = [...files]..sort((a, b) => b.modifiedSec.compareTo(a.modifiedSec));
    final sample = [
      ...byNewest.where((f) => f.isImage).take(sampleSize),
      ...byNewest.where((f) => f.isVideo && f.bytes < 200 << 20).take(3),
    ];
    final total = sample.fold(0, (s, f) => s + f.bytes);
    print('\nCopying ${sample.length} files (${mb(total)}) to ${out.path} …');

    sw.reset();
    var done = 0;
    for (final f in sample) {
      final dest = '${out.path}${Platform.pathSeparator}${f.id}_${f.name}';
      await adb.copyToLaptop(phone.serial, f, dest);
      if (await File(dest).length() != f.bytes) return fail('Size mismatch for ${f.name}');
      done += f.bytes;
    }
    final secs = sw.elapsedMilliseconds / 1000;
    print('Copied ${mb(done)} in ${secs.toStringAsFixed(1)} s = ${(done / (1 << 20) / secs).toStringAsFixed(1)} MB/s');
    print('All sizes match. Nothing on the phone was changed.');
  } on PhoneDisconnected catch (e) {
    fail('$e\nNothing on the phone was changed; partial copies on the laptop were removed.');
  }
}

void fail(String msg) {
  stderr.writeln(msg);
  exitCode = 1;
}

String gb(int b) => '${(b / (1 << 30)).toStringAsFixed(2)} GB';
String mb(int b) => '${(b / (1 << 20)).toStringAsFixed(1)} MB';
