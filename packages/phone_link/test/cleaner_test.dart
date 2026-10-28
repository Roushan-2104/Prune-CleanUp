import 'dart:io';

import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

/// Runs against a running virtual phone (emulator) ONLY. Skips if none.
///
/// Tagged 'emulator', which dart_test.yaml skips by default, so a plain
/// `dart test` never runs it. To run it on purpose, with a virtual phone
/// running:  dart test -P emulator test/cleaner_test.dart
///
/// A device counts as a virtual phone only if it is named `emulator-…` AND
/// says so through getprop (a real phone forwarded to a local port gets an
/// `emulator-…` name too). It creates its own test files in
/// /sdcard/Pictures/PruneTest and a fake WhatsApp "Sent" file, refuses to
/// start if any of them already exists, and removes only what it made.
void main() {
  final adbPath = '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe';
  final adb = Adb(adbPath);
  String? emulator; // set only once the device has said it is virtual
  String? skipReason = 'no virtual phone running';
  late PhoneCleaner cleaner;
  late Directory backups;

  const pics = '/storage/emulated/0/Pictures/PruneTest';
  const sent = '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/Sent';
  const made = ['$pics/a.png', '$pics/b.png', '$pics/c.png', '$sent/sent.png'];
  final madeFolders = <String>[]; // folders this test created, deepest first

  /// Raw shell on the test device. Refuses anything but a confirmed
  /// virtual phone.
  Future<ProcessResult> sh(String c) {
    final serial = emulator;
    if (serial == null || !PhoneCleaner.isVirtualPhone(serial)) {
      throw StateError('refusing to run "$c": not a confirmed virtual phone');
    }
    return Process.run(adbPath, ['-s', serial, 'shell', c]);
  }

  /// The fake "Sent" file as Prune sees hidden files on a real phone: no
  /// media id, and size and date from the file system (`find`), not from
  /// Android's media list. (The virtual phone happens to list it, and the
  /// list's date can differ from the file's, which Prune would rightly
  /// read as "changed".)
  Future<PhoneFile> hiddenSent() async {
    final f = (await adb.listAllFiles(emulator!)).singleWhere((x) => x.path == '$sent/sent.png');
    final stat = '${(await sh("stat -c '%s %Y' '$sent/sent.png'")).stdout}'.trim().split(RegExp(r'\s+'));
    return PhoneFile(
        path: f.path, folder: f.folder, bytes: int.parse(stat[0]), mime: f.mime, modifiedSec: int.parse(stat[1]));
  }

  Future<PhoneFile> listed(String name) async {
    await sh("content call --uri content://media/external/file --method scan_file --arg '$pics/$name'");
    return (await adb.listFiles(emulator!)).singleWhere((f) => f.path == '$pics/$name');
  }

  test('refuses real phones unless explicitly allowed', () {
    expect(() => PhoneCleaner(adbPath, 'TESTREAL0001'), throwsA(isA<RealPhoneLocked>()));
  });

  group('on a virtual phone', () {
    setUpAll(() async {
      for (final d in await adb.devices()) {
        if (!d.ready || !PhoneCleaner.isVirtualPhone(d.serial)) continue;
        final c = PhoneCleaner(adbPath, d.serial);
        try {
          await c.confirmVirtualPhone();
        } on RealPhoneLocked {
          continue; // named emulator-…, but not a virtual phone
        }
        emulator = d.serial;
        cleaner = c;
        break;
      }
      if (emulator == null) return;
      for (final p in made) {
        if (await cleaner.exists(p)) {
          emulator = null;
          skipReason = '$p is already on the virtual phone; not touching it';
          return;
        }
      }
      for (final folder in [sent, pics]) {
        var d = folder;
        while (d.length > '/storage/emulated/0'.length && !await cleaner.exists(d)) {
          if (!madeFolders.contains(d)) madeFolders.add(d);
          d = d.substring(0, d.lastIndexOf('/'));
        }
      }
      madeFolders.sort((a, b) => b.length.compareTo(a.length));
      skipReason = null;
      backups = await Directory.systemTemp.createTemp('declutter_cleaner_test');
      await sh("mkdir -p $pics '$sent'");
      for (final n in ['a.png', 'b.png', 'c.png']) {
        await sh('screencap -p $pics/$n');
      }
      await sh("cp $pics/a.png '$sent/sent.png'");
    });

    tearDownAll(() async {
      if (emulator == null) return;
      await sh('rm -f ${made.map(shellQuote).join(' ')}');
      for (final d in madeFolders) {
        await sh('rmdir ${shellQuote(d)}'); // only empty folders this test made
      }
      await backups.delete(recursive: true);
    });

    test('trash, then restore from trash', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final f = await listed('a.png');
      await cleaner.moveToTrash(f);
      expect(await cleaner.exists(f.path), isFalse);
      expect((await adb.listFiles(emulator!)).any((x) => x.path == f.path), isFalse);
      await cleaner.restoreFromTrash(f);
      expect(await cleaner.exists(f.path), isTrue);
    });

    test('delete a listed file, then put it back from a laptop backup', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final f = await listed('b.png');
      final backup = '${backups.path}${Platform.pathSeparator}b.png';
      await adb.copyToLaptop(emulator!, f, backup);
      await cleaner.deleteForever(f);
      expect(await cleaner.exists(f.path), isFalse);
      await cleaner.putBack(backup, f.path);
      expect(await cleaner.exists(f.path), isTrue);
      expect((await adb.listFiles(emulator!)).singleWhere((x) => x.path == f.path).bytes, File(backup).lengthSync());
    });

    test('putting back never overwrites a file now in its place', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final f = await listed('c.png');
      final backup = File('${backups.path}${Platform.pathSeparator}c-old.png')..writeAsBytesSync([1, 2, 3]);
      await expectLater(cleaner.putBack(backup.path, f.path), throwsA(isA<PlaceTaken>()));
      expect((await adb.listFiles(emulator!)).singleWhere((x) => x.path == f.path).bytes, f.bytes);
    });

    test('delete a hidden file (no media id), then put it back', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final hidden = await hiddenSent();
      final backup = '${backups.path}${Platform.pathSeparator}sent.png';
      await adb.copyToLaptop(emulator!, hidden, backup);
      await cleaner.deleteForever(hidden);
      expect(await cleaner.exists(hidden.path), isFalse);
      await cleaner.putBack(backup, hidden.path, index: false);
      expect(await cleaner.exists(hidden.path), isTrue);
    });

    test('hidden files have no Trash: asking for it is an error, not a delete', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final hidden = await hiddenSent();
      await expectLater(cleaner.moveToTrash(hidden), throwsA(isA<CleanError>()));
      expect(await cleaner.exists(hidden.path), isTrue);
    });
  }, tags: ['emulator']);
}
