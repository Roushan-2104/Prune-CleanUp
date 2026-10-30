@Tags(['emulator'])
library;

import 'dart:io';

import 'package:declutter/cleaning.dart';
import 'package:declutter_engine/declutter_engine.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_link/phone_link.dart';

/// End to end on a running VIRTUAL phone only: seed junk → find it →
/// clean with backup → undo. Skips when no virtual phone is running.
///
/// Tagged 'emulator', which dart_test.yaml skips by default, so a plain
/// `flutter test` never runs it (the no-phone lock check is in
/// clean_runner_lock_test.dart). To run it on purpose, with a virtual phone
/// running:  flutter test --run-skipped --tags emulator test/cleaning_test.dart
///
/// A device counts as a virtual phone only if it is named `emulator-…` AND
/// says so through getprop (a real phone forwarded to a local port gets an
/// `emulator-…` name too). The test refuses to start if any file it would
/// make is already there, and removes only what it made.
void main() {
  final adbPath = '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe';
  final adb = Adb(adbPath);
  String? emu; // set only once the device has said it is virtual
  String? skipReason = 'no virtual phone running';
  const root = '/storage/emulated/0';
  const sent = '$root/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Sent';
  final seeded = [
    '$sent/IMG-sent-1.png', '$sent/IMG-sent-2.png', // WhatsApp sent copies (hidden)
    '$root/Download/copy-of-photo.png', // exact duplicate of the camera photo (goes to Trash)
  ];
  const original = '$root/DCIM/Camera/IMG_original.png';
  final made = [...seeded, original, '$sent/.nomedia'];
  final madeFolders = <String>[]; // folders this test created, deepest first
  // (Accidental-clip detection is covered by engine unit tests: the virtual
  // phone's test recordings report a duration of 0, i.e. "unknown".)

  /// Raw shell on the test device. Refuses anything but a confirmed
  /// virtual phone.
  Future<ProcessResult> sh(String c) {
    final serial = emu;
    if (serial == null || !PhoneCleaner.isVirtualPhone(serial)) {
      throw StateError('refusing to run "$c": not a confirmed virtual phone');
    }
    return Process.run(adbPath, ['-s', serial, 'shell', c]);
  }

  group('on a virtual phone', () {
    setUpAll(() async {
      PhoneCleaner? checker;
      for (final d in await adb.devices()) {
        if (!d.ready || !PhoneCleaner.isVirtualPhone(d.serial)) continue;
        final c = PhoneCleaner(adbPath, d.serial);
        try {
          await c.confirmVirtualPhone();
        } on RealPhoneLocked {
          continue; // named emulator-…, but not a virtual phone
        }
        emu = d.serial;
        checker = c;
        break;
      }
      if (checker == null) return;
      for (final p in made) {
        if (await checker.exists(p)) {
          emu = null;
          skipReason = '$p is already on the virtual phone; not touching it';
          return;
        }
      }
      for (final folder in [sent, '$root/Download', '$root/DCIM/Camera']) {
        var d = folder;
        while (d.length > root.length && !await checker.exists(d)) {
          if (!madeFolders.contains(d)) madeFolders.add(d);
          d = d.substring(0, d.lastIndexOf('/'));
        }
      }
      madeFolders.sort((a, b) => b.length.compareTo(a.length));
      skipReason = null;
      await sh("mkdir -p '$sent' $root/Download $root/DCIM/Camera");
      await sh("touch '$sent/.nomedia'");
      await sh('screencap -p $original');
      await sh('cp $original $root/Download/copy-of-photo.png');
      await sh("screencap -p '$sent/IMG-sent-1.png'");
      await sh("screencap -p '$sent/IMG-sent-2.png'");
      await sh('content call --uri content://media/external/file --method scan_volume --arg external_primary');
    });

    tearDownAll(() async {
      if (emu == null) return;
      await sh('rm -f ${made.map(shellQuote).join(' ')}');
      for (final d in madeFolders) {
        await sh('rmdir ${shellQuote(d)}'); // only empty folders this test made
      }
    });

    test('find → clean with backup → undo', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);

      // 1. Find, exactly as the app does.
      final files = await adb.listAllFiles(emu!);
      final facts = [
        for (final f in files)
          FileFacts(path: f.path, folder: f.folder, bytes: f.bytes, mime: f.mime, modifiedSec: f.modifiedSec, durationMs: f.durationMs),
      ];
      final hashes = await adb.fingerprints(emu!, [for (final c in sameSizeCandidates(facts)) c.path]);
      final found = classifyFiles(facts, now: DateTime.now(), contentHash: hashes);
      for (final p in seeded) {
        expect(found.containsKey(p), isTrue, reason: 'should suggest $p');
      }
      expect(found.containsKey(original), isFalse, reason: 'the original is kept');

      // 2. Clean the seeded items with backup on.
      final store = Store.inMemory()..rememberPhone(emu!, await adb.info(emu!));
      final runner = CleanRunner(store: store, adb: adb, serial: emu!, phoneLabel: 'virtual-test');
      final items = files.where((f) => seeded.contains(f.path)).toList();
      final sizes = {for (final f in items) f.path: f.bytes};
      final dates = {for (final p in seeded) p: '${(await sh("stat -c %Y '$p'")).stdout}'.trim()};
      final result = await runner.run(CleanPlan(items), backup: true);
      expect(result.failed, isEmpty);
      expect(result.done, seeded.length);
      for (final p in seeded) {
        expect((await sh("ls '$p'")).exitCode, isNot(0), reason: '$p gone');
      }

      // Re-reading after a clean must not offer the trashed files again
      // (they sit on disk as ".trashed-…" until Android removes them).
      final again = await adb.listAllFiles(emu!);
      expect(again.where((f) => f.name.startsWith('.trashed-')), isEmpty);
      final againFacts = [
        for (final f in again)
          FileFacts(path: f.path, folder: f.folder, bytes: f.bytes, mime: f.mime, modifiedSec: f.modifiedSec),
      ];
      final againHashes = await adb.fingerprints(emu!, [for (final c in sameSizeCandidates(againFacts)) c.path]);
      final againFound = classifyFiles(againFacts, now: DateTime.now(), contentHash: againHashes);
      expect(againFound.keys.where((p) => p.contains('.trashed-')), isEmpty);

      // 3. Undo puts everything back, byte for byte.
      expect(await runner.undo(result.session!), seeded.length);
      final after = {for (final f in await adb.listAllFiles(emu!)) f.path: f.bytes};
      for (final p in seeded) {
        expect(after[p], sizes[p], reason: '$p restored with the same size');
        expect('${(await sh("stat -c %Y '$p'")).stdout}'.trim(), dates[p], reason: '$p keeps its date');
      }
      expect(store.opsOf(result.session!).every((o) => o.state == OpState.restored), isTrue);

      // Laptop backups are cleaned up by the test (the app keeps them).
      for (final o in store.opsOf(result.session!)) {
        if (o.backup case final b? when File(b).existsSync()) File(b).deleteSync();
      }
      final testFolder = Directory('$backupRoot\\virtual-test');
      if (testFolder.existsSync()) testFolder.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('cancel midway puts everything back, with the same sizes and dates', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      Future<String> sizeAndDate(String p) async => '${(await sh("stat -c '%s %Y' '$p'")).stdout}'.trim();

      final files = await adb.listAllFiles(emu!);
      final items = files.where((f) => seeded.contains(f.path)).toList();
      expect(items.length, seeded.length, reason: 'the seeded files are back from the first test');
      final before = {for (final p in seeded) p: await sizeAndDate(p)};

      final store = Store.inMemory()..rememberPhone(emu!, await adb.info(emu!));
      final runner = CleanRunner(store: store, adb: adb, serial: emu!, phoneLabel: 'virtual-cancel-test', batch: 1);
      final result = await runner.run(CleanPlan(items), backup: true, onProgress: (step, _) {
        if (step.startsWith('Cleaning… 2 of')) runner.cancel(); // pressed while item 2 is cleaned
      });

      expect(result.cancelled, isTrue);
      expect(result.putBack, 2, reason: 'both cleaned items came back');
      expect(result.done, 0, reason: 'nothing is left removed');
      for (final p in seeded) {
        expect(await sizeAndDate(p), before[p], reason: '$p is back with the same size and date');
      }
      final ops = store.opsOf(result.session!);
      expect(ops.where((o) => o.state == OpState.planned), isEmpty, reason: 'nothing left pending in the journal');
      expect(ops.where((o) => o.state == OpState.restored).length, 2);
      expect(ops.where((o) => o.error == notCleanedCancelled).length, seeded.length - 2);
      expect(Directory('$backupRoot\\virtual-cancel-test').existsSync(), isFalse,
          reason: 'backups no longer needed are removed');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('cancel while backing up changes nothing and leaves no backups', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final files = await adb.listAllFiles(emu!);
      final items = files.where((f) => seeded.contains(f.path)).toList();
      final store = Store.inMemory()..rememberPhone(emu!, await adb.info(emu!));
      final runner = CleanRunner(store: store, adb: adb, serial: emu!, phoneLabel: 'virtual-cancel-test');
      runner.cancel(); // pressed before the first batch finished
      final result = await runner.run(CleanPlan(items), backup: true);
      expect(result.cancelled, isTrue);
      expect(result.session, isNull, reason: 'the phone was never touched');
      for (final p in seeded) {
        expect((await sh("ls '$p'")).exitCode, 0, reason: '$p untouched');
      }
      expect(Directory('$backupRoot\\virtual-cancel-test').existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
