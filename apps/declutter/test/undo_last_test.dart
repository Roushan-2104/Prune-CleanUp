import 'package:declutter/clean_dialog.dart';
import 'package:declutter/cleaning.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_link/phone_link.dart';

/// What "Undo last clean-up" on the home screen offers. Store only: no
/// phone, nothing runs adb.
void main() {
  const phone = 'TESTPHONE0001', other = 'TESTPHONE0002'; // made up

  int cleanUp(Store store, String serial, List<(PlannedOp, OpState)> ops) {
    final s = store.startSession(serial);
    final ids = store.planCleanOps(s, serial, [for (final (op, _) in ops) op]);
    for (final (i, (_, state)) in ops.indexed) {
      store.markOp(ids[i], state);
    }
    store.finishSession(s, itemsRemoved: ops.length, bytesFreed: 0);
    return s;
  }

  test('nothing to offer before any clean-up', () {
    expect(UndoableCleanUp.of(Store.inMemory(), phone), isNull);
  });

  test('counts trashed items and backed-up deletions, not the rest', () {
    final store = Store.inMemory();
    final s = cleanUp(store, phone, [
      (const PlannedOp('/sdcard/DCIM/a.jpg', 10, CleanMethod.trash, mediaId: '1'), OpState.done),
      (const PlannedOp('/sdcard/DCIM/b.jpg', 10, CleanMethod.trash, mediaId: '2'), OpState.restored),
      (const PlannedOp('/sdcard/x/c.jpg', 10, CleanMethod.delete, backup: r'C:\b\c.jpg'), OpState.done),
      (const PlannedOp('/sdcard/x/d.jpg', 10, CleanMethod.delete), OpState.done), // no backup
      (const PlannedOp('/sdcard/x/e.jpg', 10, CleanMethod.trash, mediaId: '5'), OpState.failed),
    ]);
    final u = UndoableCleanUp.of(store, phone)!;
    expect(u.session, s);
    expect((u.fromTrash, u.fromBackup, u.count), (1, 1, 2));
    expect(undoSummary(u), 'Put back 2 items from your last clean-up.');
  });

  test('only for the phone that made the clean-up', () {
    final store = Store.inMemory();
    cleanUp(store, phone, [(const PlannedOp('/sdcard/a.jpg', 1, CleanMethod.trash, mediaId: '1'), OpState.done)]);
    expect(UndoableCleanUp.of(store, other), isNull);
    expect(undoSummary(UndoableCleanUp.of(store, phone)!), 'Put back 1 item from your last clean-up.');
  });

  test('gone once everything has been put back', () {
    final store = Store.inMemory();
    cleanUp(store, phone, [(const PlannedOp('/sdcard/a.jpg', 1, CleanMethod.trash, mediaId: '1'), OpState.restored)]);
    expect(UndoableCleanUp.of(store, phone), isNull);
  });

  test('remembers which phone the clean-up was made on', () {
    final store = Store.inMemory();
    cleanUp(store, phone, [(const PlannedOp('/sdcard/a.jpg', 1, CleanMethod.trash, mediaId: '1'), OpState.done)]);
    expect(UndoableCleanUp.of(store, phone)!.phone, phone);
  });

  test('leaves out items kept because a newer file is in their place', () {
    final store = Store.inMemory();
    final s = cleanUp(store, phone, [
      (const PlannedOp('/sdcard/x/a.jpg', 1, CleanMethod.delete, backup: 'C:/b/a.jpg'), OpState.done),
      (const PlannedOp('/sdcard/x/b.jpg', 1, CleanMethod.delete, backup: 'C:/b/b.jpg'), OpState.done),
    ]);
    store.markOp(store.opsOf(s).first.id, OpState.done, error: keptNewerFile);
    final u = UndoableCleanUp.of(store, phone)!;
    expect((u.fromTrash, u.fromBackup, u.count), (0, 1, 1));

    store.markOp(store.opsOf(s).last.id, OpState.done, error: keptNewerFile);
    expect(UndoableCleanUp.of(store, phone), isNull);
  });

  test('says why items were not put back', () {
    expect(keptLine(1), startsWith('1 was not put back: a newer file is in its place.'));
    expect(keptLine(3), startsWith('3 were not put back'));
  });

  group('undo refuses a clean-up of another phone', () {
    // Real-looking serials with the lock open, as in the app; the adb path
    // does not exist, so reaching the phone at all would fail differently.
    CleanRunner runnerFor(Store store, String serial) => CleanRunner(
        store: store, adb: Adb('no-such-adb.exe'), serial: serial, phoneLabel: 'test', allowRealPhone: true);

    test('a clean-up made on another phone', () async {
      final store = Store.inMemory();
      final s = cleanUp(store, phone, [
        (const PlannedOp('/sdcard/DCIM/a.jpg', 1, CleanMethod.trash, mediaId: '1'), OpState.done),
        (const PlannedOp('/sdcard/x/b.jpg', 1, CleanMethod.delete, backup: 'C:/b/b.jpg'), OpState.done),
      ]);
      await expectLater(runnerFor(store, other).undo(s), throwsA(isA<CleanError>()));
      expect(store.opsOf(s).map((o) => (o.state, o.error)), everyElement((OpState.done, null)));
      expect(UndoableCleanUp.of(store, phone)!.count, 2);
    });

    test('an unknown clean-up', () async {
      await expectLater(runnerFor(Store.inMemory(), phone).undo(42), throwsA(isA<CleanError>()));
    });
  });
}
