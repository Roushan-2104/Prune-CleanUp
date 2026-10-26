@Tags(['phone'])
library;

import 'dart:io';

import 'package:declutter/phone_session.dart';
import 'package:declutter/photo_scan.dart';
import 'package:declutter_engine/declutter_engine.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_link/phone_link.dart';

/// The photo check on a connected phone (a real one if plugged in, else the
/// virtual one). Read-only: photos are copied off, measured, and the copies
/// deleted. Uses a throwaway database. Set DECLUTTER_PHOTO_LIMIT to cap how
/// many images are checked (default 400).
void main() {
  final adbPath = '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe';
  final adb = Adb(adbPath);

  test('copy → measure → judge, with timing', () async {
    final ready = (await adb.devices()).where((d) => d.ready).toList();
    final phone = ready.where((d) => !PhoneCleaner.isVirtualPhone(d.serial)).firstOrNull ?? ready.firstOrNull;
    if (phone == null) {
      markTestSkipped('No phone connected');
      return;
    }
    final limit = int.tryParse(Platform.environment['DECLUTTER_PHOTO_LIMIT'] ?? '') ?? 400;
    final dir = Directory.systemTemp.createTempSync('declutter_photo_');
    final store = Store.open('${dir.path}\\test.db');
    addTearDown(() {
      store.close();
      dir.deleteSync(recursive: true);
    });

    final all = await adb.listAllFiles(phone.serial);
    final images = PhotoScan.imagesOf(all);
    // A mix: every screenshot-ish image first, then camera photos, up to the limit.
    final picked = [
      ...all.where((f) => images.containsKey(f.path) && mightBeScreenshot(images[f.path]!)).take(limit ~/ 2),
      ...all.where((f) => images.containsKey(f.path) && !mightBeScreenshot(images[f.path]!)),
    ].take(limit).toList();
    store.syncInventory(phone.serial, picked);

    final scan = PhotoScan(adb: adb, serial: phone.serial, store: store);
    final sw = Stopwatch()..start();
    await scan.run(picked);
    sw.stop();
    expect(scan.error, isNull);
    expect(scan.done, picked.length);

    final verdicts = scan.judge(picked);
    final byCat = <JunkCategory, int>{};
    for (final v in verdicts.values) {
      byCat.update(v.verdict.category, (n) => n + 1, ifAbsent: () => 1);
    }
    final mb = PhoneSummary.bytes(picked) / (1 << 20);
    // ignore: avoid_print
    print('${phone.serial}: ${picked.length} images (${mb.toStringAsFixed(0)} MB) of ${images.length} '
        'in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s '
        '= ${(sw.elapsedMilliseconds / picked.length).toStringAsFixed(0)} ms each\n'
        'found: ${byCat.entries.map((e) => '${e.key.name} ${e.value}').join(', ')}\n'
        'measurements saved: ${store.measurements(phone.serial).length}, still to check: ${scan.pending()}');
    expect(scan.pending(), 0);
    final work = PhotoScan.workRoot;
    expect(work.existsSync() ? work.listSync(recursive: true).whereType<File>() : <File>[], isEmpty,
        reason: 'copies are deleted');
  }, timeout: const Timeout(Duration(hours: 3)));
}
