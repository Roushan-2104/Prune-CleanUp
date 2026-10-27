@Tags(['phone'])
library;

import 'dart:io';
import 'dart:math';

import 'package:declutter/photo_scan.dart';
import 'package:declutter_engine/declutter_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_link/phone_link.dart';
import 'package:vision_helper/vision_helper.dart';

/// Where the photo check's time goes on a connected phone, and whether
/// reading text from smaller copies of big images changes any verdict.
/// Read-only on the phone; copies live in a temp folder, deleted at the end.
/// Prints timings and counts only: no names, paths or text.
void main() {
  final adb = Adb('${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe');

  test('copy speed and text-reading size', () async {
    final ready = (await adb.devices()).where((d) => d.ready).toList();
    final phone = ready.where((d) => !PhoneCleaner.isVirtualPhone(d.serial)).firstOrNull;
    if (phone == null) {
      markTestSkipped('No phone connected');
      return;
    }
    final all = await adb.listAllFiles(phone.serial);
    final images = PhotoScan.imagesOf(all);
    final candidates = [for (final f in all) if (images[f.path] case final i? when mightBeScreenshot(i)) f]..shuffle(Random(1));
    final dir = Directory.systemTemp.createTempSync('prune_speed_');
    addTearDown(() => dir.deleteSync(recursive: true));
    String local(String run, PhoneFile f) => '${dir.path}\\$run\\${f.path.hashCode.toUnsigned(32).toRadixString(16)}_${f.name}';

    // 1. Copy speed: three different sets of 200 files (so no run is helped
    //    by the phone's cache), with 1, 2 and 3 pulls side by side.
    for (final (k, parallel) in [(0, 1), (1, 2), (2, 3)]) {
      final set = candidates.skip(k * 200).take(200).toList();
      final sw = Stopwatch()..start();
      final r = await adb.copyManyToLaptop(phone.serial, set, (f) => local('copy$k', f), parallel: parallel);
      final mb = r.bytes / (1 << 20);
      // ignore: avoid_print
      print('copy, $parallel at once: ${set.length} files, ${mb.toStringAsFixed(0)} MB in '
          '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s = ${(mb * 1000 / sw.elapsedMilliseconds).toStringAsFixed(1)} MB/s');
      Directory('${dir.path}\\copy$k').deleteSync(recursive: true);
    }

    // 2. Text reading: the same images at full size and shrunk, verdicts compared.
    final long = [
      for (final f in candidates)
        if (f.width != null && f.height != null && max(f.width!, f.height!) > 2000) f
    ].take(150);
    final sample = {...long, ...candidates.take(250)}.toList();
    await adb.copyManyToLaptop(phone.serial, sample, (f) => local('read', f), parallel: 2);
    final copied = [for (final f in sample) if (File(local('read', f)).existsSync()) f];
    final vision = Vision(PhotoScan.findVisionHelper()!, parallel: 8, batchSize: 5);

    Future<(int ms, List<VisionResult>)> read(int? size) async {
      final sw = Stopwatch()..start();
      final r = await vision.analyseEach(
          [for (final f in copied) VisionJob(local('read', f), gray: true, text: true, textMaxSide: size)]);
      return (sw.elapsedMilliseconds, r);
    }

    String verdictOf(PhoneFile f, VisionResult r) {
      final g = r.gray;
      if (!r.ok || g == null) return 'unreadable';
      final v = screenshotVerdict(images[f.path]!, r.text, width: g.width, height: g.height);
      return v == null ? 'not a screenshot' : '${v.category.name}|${v.label}|${v.tier.name}';
    }

    final (fullMs, full) = await read(null);
    final base = [for (final (i, f) in copied.indexed) verdictOf(f, full[i])];
    final bigOnes = {for (final f in long) f.path};
    // ignore: avoid_print
    print('text reading, full size: ${copied.length} images (${bigOnes.length} over 2000 px) in ${fullMs ~/ 1000} s');
    for (final size in [2560, 2000, 1600]) {
      final (ms, shrunk) = await read(size);
      var same = 0, differ = 0, differBig = 0;
      for (final (i, f) in copied.indexed) {
        if (verdictOf(f, shrunk[i]) == base[i]) {
          same++;
        } else {
          differ++;
          if (bigOnes.contains(f.path)) differBig++;
        }
      }
      // ignore: avoid_print
      print('text reading at $size px: ${ms ~/ 1000} s (${(100 * ms / fullMs).round()}% of full); '
          'same verdict $same, different $differ (of them over 2000 px: $differBig)');
    }
  }, timeout: const Timeout(Duration(hours: 1)));
}
