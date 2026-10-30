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

  group('many files at once', () {
    // A fake phone: ids 1 and 2 belong to their files, id 3 now names another
    // file; the second change prints an error; a.jpg is gone afterwards,
    // b.jpg is still there.
    PhoneFile file(String id, String name) =>
        PhoneFile(id: id, path: '/storage/emulated/0/DCIM/$name', folder: 'DCIM/', bytes: 5, mime: 'image/jpeg', modifiedSec: 1);
    final a = file('1', 'a.jpg'), b = file('2', 'b.jpg'), c = file('3', 'c.jpg');
    final calls = <String>[];
    Future<ProcessResult> phone(List<String> args) async {
      final command = args.skip(3).join(' ');
      calls.add(command);
      if (command.contains('getprop')) return ProcessResult(0, 0, '1\n', '');
      if (command.startsWith('content query')) {
        return ProcessResult(0, 0,
            'Row: 0 _id=1, _data=${a.path}\nRow: 1 _id=2, _data=${b.path}\nRow: 2 _id=3, _data=/storage/emulated/0/other.jpg\n', '');
      }
      if (command.startsWith('stat')) return ProcessResult(0, 1, '5 1 ${b.path}\n', "stat: '${a.path}': No such file");
      return ProcessResult(0, 0, 'ok 0\nno 1\n', ''); // the batch of changes
    }

    test('changes only files whose id is still theirs, and reports what failed', () async {
      calls.clear();
      final cleaner = PhoneCleaner('adb.exe', serial, runAdb: phone);
      final failed = await cleaner.moveManyToTrash([a, b, c]);
      expect(failed.keys, unorderedEquals([b.path, c.path]));
      expect(failed[c.path]!.message, contains('lists a different file'));
      final batch = calls.singleWhere((c) => c.contains('is_trashed'));
      expect(batch, contains('file/1 '));
      expect(batch, contains('file/2 '));
      expect(batch, isNot(contains('file/3 ')), reason: 'a file whose id changed is never touched');
    });

    test('a file the phone says it changed but is still there counts as failed', () async {
      final cleaner = PhoneCleaner('adb.exe', serial, runAdb: (args) async {
        final r = await phone(args);
        return args.skip(3).join(' ').contains('is_trashed') ? ProcessResult(0, 0, 'ok 0\nok 1\n', '') : r;
      });
      final failed = await cleaner.moveManyToTrash([a, b]);
      expect(failed.keys, [b.path]);
      expect(failed[b.path]!.message, contains('still in its place'));
    });

    test('a pulled cable stops with PhoneDisconnected, not "failed"', () async {
      final cleaner = PhoneCleaner('adb.exe', serial, runAdb: (args) async {
        if (args.skip(3).join(' ').contains('is_trashed')) return ProcessResult(0, 1, '', 'error: device offline');
        return phone(args);
      });
      await expectLater(cleaner.moveManyToTrash([a, b]), throwsA(isA<PhoneDisconnected>()));
    });

    test('a device that is not a virtual phone is refused before anything runs', () async {
      final adb = FakeAdb(virtual: false);
      final cleaner = PhoneCleaner('adb.exe', serial, runAdb: adb.call);
      await expectLater(cleaner.moveManyToTrash([a]), throwsA(isA<RealPhoneLocked>()));
      await expectLater(cleaner.deleteManyForever([a, hidden]), throwsA(isA<RealPhoneLocked>()));
      await expectLater(cleaner.restoreManyFromTrash([a]), throwsA(isA<RealPhoneLocked>()));
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
