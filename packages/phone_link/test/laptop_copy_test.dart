import 'dart:io';

import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

/// Copies to the laptop never replace a file already there. No phone needed:
/// each refusal happens before adb would run.
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('prune_copy_test'));
  tearDown(() async => dir.delete(recursive: true));

  const f = PhoneFile(path: '/storage/emulated/0/DCIM/a.jpg', folder: 'DCIM/', bytes: 3, mime: 'image/jpeg', modifiedSec: 1);

  test('a free place is free', () {
    expect(() => Adb.ensureFree('${dir.path}${Platform.pathSeparator}new.jpg'), returnsNormally);
  });

  test('a file already there is never replaced', () async {
    final there = File('${dir.path}${Platform.pathSeparator}a.jpg')..writeAsStringSync('mine');
    expect(() => Adb.ensureFree(there.path), throwsA(isA<FileSystemException>()));
    // 'no-such-adb.exe' is never run: the copy is refused first.
    await expectLater(Adb('no-such-adb.exe').copyToLaptop('emulator-5554', f, there.path),
        throwsA(isA<FileSystemException>()));
    expect(there.readAsStringSync(), 'mine');
    expect(dir.listSync(), hasLength(1), reason: 'no part file left behind');
  });

  test('a short name for another file counts as taken', () async {
    final long = File('${dir.path}${Platform.pathSeparator}IMG_20240101_123456_long_name.jpg')..writeAsStringSync('mine');
    final short = await _shortName(long.path);
    if (short == null) return markTestSkipped('this drive keeps no short names');
    expect(() => Adb.ensureFree('${dir.path}${Platform.pathSeparator}$short'), throwsA(isA<FileSystemException>()));
    expect(long.readAsStringSync(), 'mine');
  }, testOn: 'windows');
}

/// The Windows 8.3 short name of [path], or null if the drive keeps none.
Future<String?> _shortName(String path) async {
  final r = await Process.run('cmd', ['/c', 'for %I in ("$path") do @echo %~snxI']);
  final name = (r.stdout as String).trim();
  return r.exitCode == 0 && name.contains('~') ? name : null;
}
