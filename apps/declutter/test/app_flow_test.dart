@Tags(['emulator'])
library;

import 'dart:io';

import 'package:declutter/clean_dialog.dart' show UndoableCleanUp;
import 'package:declutter/cleaning.dart';
import 'package:declutter/phone_session.dart';
import 'package:declutter_engine/declutter_engine.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_link/phone_link.dart';

/// The whole app flow on a running VIRTUAL phone, through the same
/// [PhoneSession] the window uses: connect → read → photo check → the pick
/// → clean, cancel midway → clean → read again → Undo → read again →
/// Forget. Prints how long each step took.
///
/// Runs only when the virtual phone is the only phone connected (the
/// session reads whichever phone is there), and cleans through a runner
/// locked to virtual phones. Seeds its own files, refuses to start if any
/// is already there, and removes only what it made.
///   flutter test --run-skipped --tags emulator test/app_flow_test.dart
void main() {
  final adbPath = '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe';
  final adb = Adb(adbPath);
  const root = '/storage/emulated/0';
  const sent = '$root/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Sent';
  const original = '$root/DCIM/Camera/IMG_flow_original.png';
  final seeded = ['$sent/IMG-flow-sent-1.png', '$sent/IMG-flow-sent-2.png', '$root/Download/flow-copy.png'];
  final made = [...seeded, original, '$sent/.nomedia'];
  String? emu;

  Future<ProcessResult> sh(String c) {
    final s = emu;
    if (s == null || !PhoneCleaner.isVirtualPhone(s)) throw StateError('not a confirmed virtual phone');
    return Process.run(adbPath, ['-s', s, 'shell', c]);
  }

  Future<String?> sizeAndDate(String p) async {
    final r = await sh("stat -c '%s %Y' '$p'");
    return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
  }

  test('connect → read → pick → clean, cancel → clean → Undo → Forget', () async {
    final ready = (await adb.devices()).where((d) => d.ready).toList();
    if (ready.length != 1 || !PhoneCleaner.isVirtualPhone(ready.single.serial)) {
      return markTestSkipped('needs exactly one phone connected, and it must be the virtual one');
    }
    try {
      await PhoneCleaner(adbPath, ready.single.serial).confirmVirtualPhone();
    } on RealPhoneLocked {
      return markTestSkipped('the connected device is not a virtual phone');
    }
    emu = ready.single.serial;
    for (final p in made) {
      if (await sizeAndDate(p) != null) return markTestSkipped('$p is already there; not touching it');
    }
    await sh("mkdir -p '$sent' $root/Download $root/DCIM/Camera");
    await sh("touch '$sent/.nomedia'");
    await sh('screencap -p $original');
    await sh('cp $original $root/Download/flow-copy.png');
    await sh("screencap -p '${seeded[0]}'");
    await sh("screencap -p '${seeded[1]}'");
    await sh('content call --uri content://media/external/file --method scan_volume --arg external_primary');
    final dir = Directory.systemTemp.createTempSync('prune_flow_');
    addTearDown(() async {
      await sh('rm -f ${made.map(shellQuote).join(' ')}');
      dir.deleteSync(recursive: true);
      final b = Directory('$backupRoot\\virtual-flow');
      if (b.existsSync()) b.deleteSync(recursive: true);
    });
    final before = {for (final p in seeded) p: await sizeAndDate(p)};

    final times = <String, Duration>{};
    final sw = Stopwatch()..start();
    void lap(String name) {
      times[name] = sw.elapsed;
      sw.reset();
    }

    Future<void> until(PhoneSession s, bool Function() ok, String what, {int seconds = 300}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!ok()) {
        if (s.state == LinkState.error) fail('$what: ${s.error}');
        if (DateTime.now().isAfter(end)) fail('$what: timed out (state ${s.state}, step "${s.readingStep}")');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    final session = PhoneSession(Store.open('${dir.path}\\prune.db'));
    addTearDown(session.dispose);

    // 1. Connect and read.
    await until(session, () => session.state == LinkState.ready, 'reading');
    expect(session.serial, emu);
    lap('read the phone');

    // 2. Photo check, then the pick.
    await until(session, () => session.photos != null && !session.photos!.running, 'photo check', seconds: 900);
    await until(session, () => seeded.every(session.suggestions.containsKey), 'suggestions', seconds: 60);
    lap('photo check');
    final sure = [
      for (final e in session.suggestions.entries)
        if (e.value.verdict.tier == Tier.sure) e.key,
    ];
    expect(sure, containsAll([seeded[2]]), reason: 'the exact copy is picked as sure');
    expect(session.suggestions.containsKey(original), isFalse, reason: 'the original is kept');

    // 3. Clean, cancelled midway: everything back.
    final items = session.summary!.files.where((f) => seeded.contains(f.path)).toList();
    final runner = CleanRunner(store: session.store, adb: adb, serial: emu!, phoneLabel: 'virtual-flow', batch: 1);
    final cancelled = await runner.run(CleanPlan(items), backup: true, onProgress: (step, _) {
      if (step.startsWith('Cleaning… 2 of')) runner.cancel();
    });
    expect(cancelled.cancelled, isTrue);
    expect(cancelled.done, 0);
    for (final p in seeded) {
      expect(await sizeAndDate(p), before[p], reason: 'after cancel, $p is back as it was');
    }
    lap('clean, then cancel');

    // 4. Clean for real, read again: the cleaned files are no longer offered.
    final runner2 = CleanRunner(store: session.store, adb: adb, serial: emu!, phoneLabel: 'virtual-flow');
    final cleaned = await runner2.run(CleanPlan(items), backup: true);
    expect(cleaned.failed, isEmpty);
    expect(cleaned.done, seeded.length);
    lap('clean');
    await session.rescan();
    await until(session, () => session.state == LinkState.ready, 'reading again');
    expect(session.summary!.files.where((f) => seeded.contains(f.path) || f.name.startsWith('.trashed-')), isEmpty);
    expect(session.sinceLastTime, isNotNull, reason: 'the second read knows what changed');
    lap('read again after clean');

    // 5. Undo from the journal (as "Undo last clean-up" does), read again.
    final undo = UndoableCleanUp.of(session.store, emu!);
    expect(undo?.count, seeded.length);
    expect(await runner2.undo(undo!.session), seeded.length);
    for (final p in seeded) {
      expect(await sizeAndDate(p), before[p], reason: 'after Undo, $p is back as it was');
    }
    await session.rescan();
    await until(session, () => session.state == LinkState.ready, 'reading after Undo');
    expect(UndoableCleanUp.of(session.store, emu!), isNull, reason: 'nothing left to undo');
    lap('Undo and read again');

    // 6. Forget this phone.
    await session.forgetPhone();
    expect(session.state, LinkState.forgotten);
    expect(session.store.fileCount(emu!), 0);
    lap('forget');

    // ignore: avoid_print
    print([for (final e in times.entries) '${e.key}: ${(e.value.inMilliseconds / 1000).toStringAsFixed(1)} s'].join('\n'));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
