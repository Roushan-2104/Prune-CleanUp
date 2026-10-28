import 'dart:io';

import 'package:declutter_store/declutter_store.dart';
import 'package:phone_link/phone_link.dart';

import 'friendly_error.dart';

/// What a clean-up will do, shown to the user before anything happens.
class CleanPlan {
  CleanPlan(List<PhoneFile> items)
      : toTrash = items.where((f) => f.id != null).toList(),
        toDelete = items.where((f) => f.id == null).toList();

  /// In Android's media list: go to the phone's Trash (30 days to restore).
  final List<PhoneFile> toTrash;

  /// Hidden from Android's media list: no Trash, deleted outright.
  final List<PhoneFile> toDelete;

  int get bytes => [...toTrash, ...toDelete].fold(0, (s, f) => s + f.bytes);
  int get deleteBytes => toDelete.fold(0, (s, f) => s + f.bytes);
}

class CleanResult {
  CleanResult(this.session, this.done, this.failed, this.bytesFreed, {this.stoppedBy});
  final int session;
  final int done;
  final Map<String, String> failed; // path → why
  final int bytesFreed;

  /// Why the clean-up stopped before the end (a pulled cable), or null if
  /// it ran to the end. What was already done can still be undone.
  final Object? stoppedBy;
}

/// %USERPROFILE%\Prune Backups
String get backupRoot =>
    '${Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path}\\Prune Backups';

/// Where each file of one clean-up is backed up:
/// `Prune Backups\<phone>\<date time>\<path on phone>`.
///
/// Every part of the phone's path (and the phone's own name) is made safe,
/// so no file name can place a backup outside this folder. Each clean-up
/// gets its own folder and no two files ever share a backup: names Windows
/// treats as the same (`IMG.jpg` / `img.jpg`, `x.jpg.` / `x.jpg`) get
/// " (2)", " (3)"… Otherwise one backup would overwrite another while both
/// phone files were deleted.
Map<String, String> backupPathsFor(String phoneLabel, List<PhoneFile> files, {DateTime? at}) {
  final t = at ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}.${two(t.second)}';
  final used = <String>{};
  return {
    for (final f in files)
      f.path: () {
        final parts = '${f.folder}${f.name}'.split('/').where((p) => p.isNotEmpty).toList();
        final base = inside(backupRoot, [phoneLabel, stamp, ...parts]);
        final dot = base.lastIndexOf('.');
        final hasExt = dot > base.lastIndexOf('\\');
        var path = base;
        for (var n = 2; !used.add(path.toLowerCase()) || File(path).existsSync(); n++) {
          path = hasExt ? '${base.substring(0, dot)} ($n)${base.substring(dot)}' : '$base ($n)';
        }
        return path;
      }(),
  };
}

/// Runs a clean-up: optional backup → journal → change the phone → record.
///
/// Every step is written to the journal before it happens, so if the app
/// or cable stops midway, the next connection knows exactly what was done.
class CleanRunner {
  CleanRunner({
    required this.store,
    required this.adb,
    required this.serial,
    required this.phoneLabel,
    this.allowRealPhone = false,
  });

  final Store store;
  final Adb adb;
  final String serial;
  final String phoneLabel;

  /// Whether a real (non-virtual) phone may be changed. Only the clean-up
  /// dialog sets it, for a clean-up the user confirmed. Off by default, so
  /// tests and any other caller can only ever change a virtual phone.
  final bool allowRealPhone;

  /// Throws [RealPhoneLocked] for a real phone unless [allowRealPhone].
  late final PhoneCleaner cleaner = PhoneCleaner(adb.adbPath, serial, allowRealPhone: allowRealPhone);

  Future<CleanResult> run(CleanPlan plan, {required bool backup, void Function(String step, double progress)? onProgress}) async {
    await cleaner.confirmVirtualPhone(); // fail fast on the safety lock, before any copying
    final items = [...plan.toTrash, ...plan.toDelete];
    final backups = <String, String>{};

    if (backup) {
      onProgress?.call('Backing up ${items.length} files to this laptop…', 0);
      final targets = backupPathsFor(phoneLabel, items);
      final report = await adb.copyManyToLaptop(serial, items, (f) => targets[f.path]!,
          onProgress: (n, _) => onProgress?.call('Backing up… $n of ${items.length}', 0.5 * n / items.length));
      for (final f in report.copied) {
        backups[f.path] = targets[f.path]!;
      }
    }

    // Hidden files can't go to the phone's Trash: with backup on, only the
    // ones that were actually backed up are deleted.
    final deletable = backup ? plan.toDelete.where((f) => backups.containsKey(f.path)).toList() : plan.toDelete;
    final skipped = {
      for (final f in plan.toDelete.where((f) => !deletable.contains(f))) f.path: 'Not deleted, because its backup to this laptop didn\'t finish.',
    };

    final session = store.startSession(serial);
    _running.add(session);
    try {
      return await _clean(plan.toTrash, deletable, session, backups, skipped, onProgress);
    } finally {
      _running.remove(session);
    }
  }

  /// Clean-ups running right now, which [settleUnfinished] leaves alone.
  static final _running = <int>{};

  Future<CleanResult> _clean(List<PhoneFile> toTrash, List<PhoneFile> deletable, int session,
      Map<String, String> backups, Map<String, String> skipped,
      void Function(String step, double progress)? onProgress) async {
    final work = [
      for (final f in toTrash) (f, CleanMethod.trash),
      for (final f in deletable) (f, CleanMethod.delete),
    ];
    final ids = store.planCleanOps(session, serial, [
      for (final (f, m) in work) PlannedOp(f.path, f.bytes, m, backup: backups[f.path], mediaId: f.id),
    ]);

    var done = 0, freed = 0;
    Object? stoppedBy;
    final failed = <String, String>{...skipped};
    for (final (i, (f, method)) in work.indexed) {
      onProgress?.call('Cleaning… ${i + 1} of ${work.length}', 0.5 + 0.5 * (i + 1) / work.length);
      try {
        method == CleanMethod.trash ? await cleaner.moveToTrash(f) : await cleaner.deleteForever(f);
        store.markOp(ids[i], OpState.done);
        done++;
        freed += f.bytes;
      } on PhoneDisconnected catch (e) {
        // The rest stay 'planned' in the journal and are settled when the
        // phone is next read (see [settleUnfinished]). What was done so far
        // is recorded below, so it can still be undone.
        stoppedBy = e;
        break;
      } catch (e) {
        store.markOp(ids[i], OpState.failed, error: '$e'); // full detail, kept on this laptop
        failed[f.path] = friendlyError(e);
      }
    }
    store.finishSession(session, itemsRemoved: done, bytesFreed: freed);
    return CleanResult(session, done, failed, freed, stoppedBy: stoppedBy);
  }

  /// Settles what an interrupted clean-up (pulled cable, closed app) left
  /// 'planned' in the journal: a file no longer at its path was removed
  /// (trashed files are renamed by Android), one still there was left in
  /// place. Only reads the phone. Returns how many were settled.
  static Future<int> settleUnfinished(Store store, Adb adb, String serial) async {
    final sessions = <int>{};
    var settled = 0;
    for (final op in store.unfinishedOps(serial)) {
      if (_running.contains(op.session)) continue;
      bool there;
      try {
        // A file that is there answers with its size. Anything else (an
        // error some phones print as ordinary output) is asked again later.
        final out = await adb.shell(serial, 'stat -c %s ${shellQuote(op.path)}');
        if (!RegExp(r'^\d+$').hasMatch(out.trim())) continue;
        there = true;
      } on PhoneDisconnected {
        rethrow;
      } on ProcessException catch (e) {
        // Only a clear "no such file" counts as gone; anything else is
        // left 'planned' and asked again next time.
        if (!e.message.toLowerCase().contains('no such file')) continue;
        there = false;
      }
      store.markOp(op.id, there ? OpState.failed : OpState.done,
          error: there ? 'left in place: the clean-up was interrupted' : null);
      sessions.add(op.session);
      settled++;
    }
    // Recount each touched clean-up, so space freed and Undo include them.
    for (final s in sessions) {
      // Counted as when a clean-up ends: an undo later doesn't change these.
      final removed = store.opsOf(s).where((o) => o.state == OpState.done || o.state == OpState.restored).toList();
      store.finishSession(s,
          itemsRemoved: removed.length, bytesFreed: removed.fold(0, (sum, o) => sum + o.bytes));
    }
    return settled;
  }

  /// Undoes a clean-up: takes files out of the phone's Trash, and copies
  /// deleted ones back from the laptop backup. Returns how many came back.
  Future<int> undo(int session, {void Function(String step)? onProgress}) async {
    var back = 0;
    final ops = store.opsOf(session).where((o) => o.state == OpState.done).toList();
    for (final (i, op) in ops.indexed) {
      onProgress?.call('Putting back ${i + 1} of ${ops.length}…');
      try {
        if (op.method == CleanMethod.trash) {
          await cleaner.restoreFromTrash(PhoneFile(id: op.mediaId, path: op.path, folder: '', bytes: op.bytes, mime: '', modifiedSec: 0));
        } else if (op.backup != null) {
          await cleaner.putBack(op.backup!, op.path, index: !op.path.contains('/Android/media/'));
        } else {
          continue; // deleted without a backup: cannot come back
        }
        store.markOp(op.id, OpState.restored);
        back++;
      } on PhoneDisconnected {
        rethrow;
      } catch (_) {
        // leave as 'done'; shown as not restored
      }
    }
    return back;
  }
}
