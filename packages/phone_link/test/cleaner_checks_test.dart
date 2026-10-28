import 'dart:io';

import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

/// The cleaner's checks before any change, against a fake adb: no phone is
/// needed and no real adb ever runs.
class FakeAdb {
  FakeAdb({this.virtual = true, this.statAnswer});

  /// Whether getprop says "virtual phone".
  final bool virtual;

  /// What `stat` on the put-back path answers; null = "No such file".
  final String? statAnswer;

  final calls = <String>[];

  Future<ProcessResult> call(List<String> args) async {
    final command = args.skip(2).join(' ');
    calls.add(command);
    if (command.contains('getprop ro.kernel.qemu')) return ProcessResult(0, 0, virtual ? '1\n\n' : '\n\n', '');
    if (command.startsWith('shell stat')) {
      final s = statAnswer;
      return s == null
          ? ProcessResult(0, 1, '', "stat: '/x': No such file or directory")
          : ProcessResult(0, 0, '$s\n', '');
    }
    if (command.contains('content query')) return ProcessResult(0, 0, 'Row: 0 _data=/storage/emulated/0/DCIM/a.jpg\n', '');
    return ProcessResult(0, 0, '', '');
  }

  /// Commands that could change the phone.
  List<String> get changes => [
        for (final c in calls)
          if (c.startsWith('push') || c.contains('content update') || c.contains('content delete') || c.contains(' rm ') ||
              c.contains('scan_file'))
            c,
      ];
}

void main() {
  const serial = 'emulator-5554'; // a name adb also gives real phones forwarded to local ports
  const f = PhoneFile(id: '12', path: '/storage/emulated/0/DCIM/a.jpg', folder: 'DCIM/', bytes: 5, mime: 'image/jpeg', modifiedSec: 1);
  const hidden = PhoneFile(path: '/storage/emulated/0/x/b.jpg', folder: 'x/', bytes: 5, mime: 'image/jpeg', modifiedSec: 1);

  group('a device named emulator-… that is not a virtual phone', () {
    late FakeAdb adb;
    late PhoneCleaner cleaner;
    setUp(() {
      adb = FakeAdb(virtual: false);
      cleaner = PhoneCleaner('adb.exe', serial, runAdb: adb.call);
    });

    test('is refused for Trash', () async {
      await expectLater(cleaner.moveToTrash(f), throwsA(isA<RealPhoneLocked>()));
      expect(adb.changes, isEmpty);
    });
    test('is refused for restoring from Trash', () async {
      await expectLater(cleaner.restoreFromTrash(f), throwsA(isA<RealPhoneLocked>()));
      expect(adb.changes, isEmpty);
    });
    test('is refused for deleting', () async {
      await expectLater(cleaner.deleteForever(f), throwsA(isA<RealPhoneLocked>()));
      await expectLater(cleaner.deleteForever(hidden), throwsA(isA<RealPhoneLocked>()));
      expect(adb.changes, isEmpty);
    });
    test('is refused for putting back', () async {
      await expectLater(cleaner.putBack('backup.jpg', f.path), throwsA(isA<RealPhoneLocked>()));
      expect(adb.changes, isEmpty);
    });
  });

  test('a virtual phone is asked once, then remembered', () async {
    final adb = FakeAdb();
    final cleaner = PhoneCleaner('adb.exe', serial, runAdb: adb.call);
    await cleaner.restoreFromTrash(f);
    await cleaner.restoreFromTrash(f);
    expect(adb.calls.where((c) => c.contains('getprop')), hasLength(1));
    expect(adb.changes, hasLength(2));
  });

  test('an allowed real phone is not asked', () async {
    final adb = FakeAdb(virtual: false);
    final cleaner = PhoneCleaner('adb.exe', 'TESTREAL0001', allowRealPhone: true, runAdb: adb.call);
    await cleaner.restoreFromTrash(f);
    expect(adb.calls.where((c) => c.contains('getprop')), isEmpty);
  });

  group('putting a backup back', () {
    test('never overwrites a file now in its place', () async {
      final adb = FakeAdb(statAnswer: '999');
      final cleaner = PhoneCleaner('adb.exe', serial, runAdb: adb.call);
      await expectLater(
          cleaner.putBack('backup.jpg', f.path),
          throwsA(isA<PlaceTaken>()
              .having((e) => e.message, 'message', 'a newer file is in its place; the backup is still on this laptop')));
      expect(adb.changes, isEmpty);
    });

    test('copies back when the place is free', () async {
      final adb = FakeAdb();
      final cleaner = PhoneCleaner('adb.exe', serial, runAdb: adb.call);
      await cleaner.putBack('backup.jpg', f.path);
      expect(adb.changes.first, startsWith('push backup.jpg'));
    });

    test('an unclear answer counts as taken', () async {
      final adb = FakeAdb(statAnswer: 'stat: permission denied');
      final cleaner = PhoneCleaner('adb.exe', serial, runAdb: adb.call);
      await expectLater(cleaner.putBack('backup.jpg', f.path), throwsA(isA<PlaceTaken>()));
      expect(adb.changes, isEmpty);
    });
  });

  test('a virtual phone says so through getprop', () {
    expect(PhoneCleaner.saysVirtual('1\n\n'), isTrue);
    expect(PhoneCleaner.saysVirtual('\n1\n'), isTrue);
    expect(PhoneCleaner.saysVirtual('\n\n'), isFalse);
    expect(PhoneCleaner.saysVirtual('0\n'), isFalse);
  });
}
