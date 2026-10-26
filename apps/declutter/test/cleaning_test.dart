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
void main() {
  final adbPath = '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe';
  final adb = Adb(adbPath);
  String? emu;
  const root = '/storage/emulated/0';
  const sent = '$root/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Sent';
  final seeded = [
    '$sent/IMG-sent-1.png', '$sent/IMG-sent-2.png', // WhatsApp sent copies (hidden)
    '$root/Download/copy-of-photo.png', // exact duplicate of the camera photo (goes to Trash)
  ];
  // (Accidental-clip detection is covered by engine unit tests: the virtual
  // phone's test recordings report a duration of 0, i.e. "unknown".)

  Future<void> sh(String c) => Process.run(adbPath, ['-s', emu!, 'shell', c]);

  setUpAll(() async {
    emu = (await adb.devices()).where((d) => d.ready && PhoneCleaner.isVirtualPhone(d.serial)).firstOrNull?.serial;
    if (emu == null) return;
    await sh("mkdir -p '$sent' $root/Download $root/DCIM/Camera");
    await sh("touch '$sent/.nomedia'");
    await sh('screencap -p $root/DCIM/Camera/IMG_original.png');
    await sh('cp $root/DCIM/Camera/IMG_original.png $root/Download/copy-of-photo.png');
    await sh("screencap -p '$sent/IMG-sent-1.png'");
    await sh("screencap -p '$sent/IMG-sent-2.png'");
    await sh('content call --uri content://media/external/file --method scan_volume --arg external_primary');
  });

  tearDownAll(() async {
    if (emu == null) return;
    await sh("rm -rf '$root/Android/media/com.whatsapp' $root/Download/copy-of-photo.png "
        '$root/DCIM/Camera/IMG_original.png');
  });

  test('find → clean with backup → undo, on the virtual phone', () async {
    if (emu == null) return markTestSkipped('no virtual phone running');

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
    expect(found.containsKey('$root/DCIM/Camera/IMG_original.png'), isFalse, reason: 'the original is kept');

    // 2. Clean the seeded items with backup on.
    final store = Store.inMemory()..rememberPhone(emu!, await adb.info(emu!));
    final runner = CleanRunner(store: store, adb: adb, serial: emu!, phoneLabel: 'virtual-test');
    final items = files.where((f) => seeded.contains(f.path)).toList();
    final sizes = {for (final f in items) f.path: f.bytes};
    final result = await runner.run(CleanPlan(items), backup: true);
    expect(result.failed, isEmpty);
    expect(result.done, seeded.length);
    for (final p in seeded) {
      expect((await Process.run(adbPath, ['-s', emu!, 'shell', "ls '$p'"])).exitCode, isNot(0), reason: '$p gone');
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
    expect(await runner.undo(result.session), seeded.length);
    final after = {for (final f in await adb.listAllFiles(emu!)) f.path: f.bytes};
    for (final p in seeded) {
      expect(after[p], sizes[p], reason: '$p restored with the same size');
    }
    expect(store.opsOf(result.session).every((o) => o.state == OpState.restored), isTrue);

    // Laptop backups are cleaned up by the test (the app keeps them).
    for (final o in store.opsOf(result.session)) {
      if (o.backup case final b? when File(b).existsSync()) File(b).deleteSync();
    }
    final testFolder = Directory('$backupRoot\\virtual-test');
    if (testFolder.existsSync()) testFolder.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a real phone is refused before anything is copied or changed', () {
    final store = Store.inMemory();
    final runner = CleanRunner(store: store, adb: adb, serial: 'R5CT12345678', phoneLabel: 'real');
    expect(() => runner.cleaner, throwsA(isA<RealPhoneLocked>()));
  });
}
