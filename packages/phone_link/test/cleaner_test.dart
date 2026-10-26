@Tags(['emulator'])
library;

import 'dart:io';

import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

/// Runs against a running virtual phone (emulator) ONLY. Skips if none.
/// It creates its own test files in /sdcard/Pictures/PruneTest and a
/// fake WhatsApp "Sent" folder; it never touches anything else.
void main() {
  final adbPath = '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe';
  final adb = Adb(adbPath);
  String? emulator;
  late PhoneCleaner cleaner;
  late Directory backups;

  const pics = '/storage/emulated/0/Pictures/PruneTest';
  const sent = '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/Sent';

  Future<void> sh(String c) => Process.run(adbPath, ['-s', emulator!, 'shell', c]);

  /// The fake "Sent" file as Prune sees hidden files on a real phone:
  /// no media id. (The virtual phone happens to list it, so drop the id.)
  Future<PhoneFile> hiddenSent() async {
    final f = (await adb.listAllFiles(emulator!)).singleWhere((x) => x.path == '$sent/sent.png');
    return PhoneFile(path: f.path, folder: f.folder, bytes: f.bytes, mime: f.mime, modifiedSec: f.modifiedSec);
  }

  Future<PhoneFile> listed(String name) async {
    await sh("content call --uri content://media/external/file --method scan_file --arg '$pics/$name'");
    return (await adb.listFiles(emulator!)).singleWhere((f) => f.path == '$pics/$name');
  }

  setUpAll(() async {
    emulator = (await adb.devices()).where((d) => d.ready && PhoneCleaner.isVirtualPhone(d.serial)).firstOrNull?.serial;
    if (emulator == null) return;
    cleaner = PhoneCleaner(adbPath, emulator!);
    backups = await Directory.systemTemp.createTemp('declutter_cleaner_test');
    await sh("mkdir -p $pics '$sent'");
    for (final n in ['a.png', 'b.png', 'c.png']) {
      await sh('screencap -p $pics/$n');
    }
    await sh("cp $pics/a.png '$sent/sent.png'");
  });
  tearDownAll(() async {
    if (emulator == null) return;
    await sh("rm -rf $pics '/storage/emulated/0/Android/media/com.whatsapp'"); // all of it is test-made
    await backups.delete(recursive: true);
  });

  test('refuses real phones unless explicitly allowed', () {
    expect(() => PhoneCleaner(adbPath, 'R5CT12345678'), throwsA(isA<RealPhoneLocked>()));
  });

  test('trash, then restore from trash', () async {
    if (emulator == null) return markTestSkipped('no virtual phone running');
    final f = await listed('a.png');
    await cleaner.moveToTrash(f);
    expect(await cleaner.exists(f.path), isFalse);
    expect((await adb.listFiles(emulator!)).any((x) => x.path == f.path), isFalse);
    await cleaner.restoreFromTrash(f);
    expect(await cleaner.exists(f.path), isTrue);
  }, skip: false);

  test('delete a listed file, then put it back from a laptop backup', () async {
    if (emulator == null) return markTestSkipped('no virtual phone running');
    final f = await listed('b.png');
    final backup = '${backups.path}${Platform.pathSeparator}b.png';
    await adb.copyToLaptop(emulator!, f, backup);
    await cleaner.deleteForever(f);
    expect(await cleaner.exists(f.path), isFalse);
    await cleaner.putBack(backup, f.path);
    expect(await cleaner.exists(f.path), isTrue);
    expect((await adb.listFiles(emulator!)).singleWhere((x) => x.path == f.path).bytes, File(backup).lengthSync());
  });

  test('delete a hidden file (no media id), then put it back', () async {
    if (emulator == null) return markTestSkipped('no virtual phone running');
    final hidden = await hiddenSent();
    final backup = '${backups.path}${Platform.pathSeparator}sent.png';
    await adb.copyToLaptop(emulator!, hidden, backup);
    await cleaner.deleteForever(hidden);
    expect(await cleaner.exists(hidden.path), isFalse);
    await cleaner.putBack(backup, hidden.path, index: false);
    expect(await cleaner.exists(hidden.path), isTrue);
  });

  test('hidden files have no Trash: asking for it is an error, not a delete', () async {
    if (emulator == null) return markTestSkipped('no virtual phone running');
    final hidden = await hiddenSent();
    await expectLater(cleaner.moveToTrash(hidden), throwsA(isA<CleanError>()));
    expect(await cleaner.exists(hidden.path), isTrue);
  });
}
