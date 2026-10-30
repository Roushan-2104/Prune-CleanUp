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
  CleanResult(this.session, this.done, this.failed, this.bytesFreed,
      {this.stoppedBy, this.cancelled = false, this.putBack = 0});

  /// The journal entry, or null when it was cancelled before the phone was
  /// touched.
  final int? session;

  /// Items removed from the phone (after a cancel: the ones that could not
  /// be put back).
  final int done;
  final Map<String, String> failed; // path → why
  final int bytesFreed;

  /// Why the clean-up stopped before the end (a pulled cable), or null if
  /// it ran to the end. What was already done can still be undone.
  final Object? stoppedBy;

  /// Cancelled by the user: what was already cleaned was put back.
  final bool cancelled;

  /// After a cancel, how many cleaned items were put back.
  final int putBack;
}

/// Why Undo kept an item where it is: a newer file now sits at its place
/// on the phone. Saved in the journal, so "Undo last clean-up" can leave
/// these out instead of offering them again and again.
const keptNewerFile = 'A newer file is in its place. The backup is still on this laptop.';

/// Why an item of a cancelled clean-up was never touched.
const notCleanedCancelled = 'Not cleaned: the clean-up was cancelled.';

/// Removes laptop backups that aren't needed any more, then the folders
/// they leave empty inside "Prune Backups". Folders holding anything else
/// (another clean-up's backups) stay.
void dropBackups(Iterable<String> paths) {
  final root = backupRoot.toLowerCase();
  final folders = <String>{};
  for (final p in paths) {
    if (!p.toLowerCase().startsWith('$root\\')) continue; // only ever our own folder
    final f = File(p);
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      continue;
    }
    for (var d = f.parent; d.path.length > backupRoot.length && d.path.toLowerCase().startsWith(root); d = d.parent) {
      folders.add(d.path);
    }
  }
  for (final d in folders.toList()..sort((a, b) => b.length.compareTo(a.length))) {
    try {
      Directory(d).deleteSync(); // not recursive: only if empty
    } on FileSystemException {
      // still holds something: kept
    }
  }
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
    this.batch = 32,
  });

  /// Items changed per step. Each step runs several changes side by side
  /// on the phone (one at a time took about a second per file); Cancel is
  /// checked between steps.
  final int batch;

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

  var _cancelled = false;

  /// Asks a running clean-up to stop. It stops after the step it is on,
  /// never in the middle of a file, then puts back everything it already
  /// cleaned (see [run]).
  void cancel() => _cancelled = true;

  /// Progress below 0 means "no fraction to show" (putting back after a cancel).
  Future<CleanResult> run(CleanPlan plan, {required bool backup, void Function(String step, double progress)? onProgress}) async {
    await cleaner.confirmVirtualPhone(); // fail fast on the safety lock, before any copying
    final items = [...plan.toTrash, ...plan.toDelete];
    final backups = <String, String>{};

    if (backup) {
      onProgress?.call('Backing up ${items.length} files to this laptop…', 0);
      final targets = backupPathsFor(phoneLabel, items);
      try {
        final report = await adb.copyManyToLaptop(serial, items, (f) => targets[f.path]!,
            onProgress: (n, _) => onProgress?.call('Backing up… $n of ${items.length}', 0.5 * n / items.length),
            stop: () => _cancelled);
        for (final f in report.copied) {
          backups[f.path] = targets[f.path]!;
        }
      } on PhoneDisconnected {
        // Nothing on the phone was changed yet; the partial copies go.
        dropBackups(targets.values);
        rethrow;
      }
    }
    if (_cancelled) {
      // Cancelled while backing up: the phone was never changed, and the
      // copies made so far aren't needed.
      dropBackups(backups.values);
      return CleanResult(null, 0, const {}, 0, cancelled: true);
    }

    // Hidden files can't go to the phone's Trash: with backup on, only the
    // ones that were actually backed up are deleted.
    final deletable = backup ? plan.toDelete.where((f) => backups.containsKey(f.path)).toList() : plan.toDelete;
    final skipped = {
      if (backup)
        for (final f in plan.toDelete)
          if (!backups.containsKey(f.path)) f.path: 'Not deleted, because its backup to this laptop didn\'t finish.',
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
    for (var start = 0; start < work.length; start += batch) {
      if (_cancelled) {
        // Never started: recorded as left in place, so nothing is pending.
        for (final id in ids.skip(start)) {
          store.markOp(id, OpState.failed, error: notCleanedCancelled);
        }
        break;
      }
      final end = (start + batch).clamp(0, work.length);
      final part = work.sublist(start, end);
      onProgress?.call('Cleaning… $end of ${work.length}', 0.5 + 0.5 * end / work.length);
      Map<String, Object> refused;
      try {
        refused = {
          ...await cleaner.moveManyToTrash([for (final (f, m) in part) if (m == CleanMethod.trash) f]),
          ...await cleaner.deleteManyForever([for (final (f, m) in part) if (m == CleanMethod.delete) f]),
        };
      } on PhoneDisconnected catch (e) {
        // This step and the rest stay 'planned' in the journal and are
        // settled when the phone is next read (see [settleUnfinished]).
        // What was done before is recorded below, so it can be undone.
        stoppedBy = e;
        break;
      } catch (e) {
        refused = {for (final (f, _) in part) f.path: e};
      }
      for (final (j, (f, _)) in part.indexed) {
        if (refused[f.path] case final e?) {
          store.markOp(ids[start + j], OpState.failed, error: '$e'); // full detail, kept on this laptop
          failed[f.path] = friendlyError(e);
        } else {
          store.markOp(ids[start + j], OpState.done);
          done++;
          freed += f.bytes;
        }
      }
    }
    store.finishSession(session, itemsRemoved: done, bytesFreed: freed);
    if (!_cancelled || stoppedBy != null) return CleanResult(session, done, failed, freed, stoppedBy: stoppedBy);
    return _putBackAfterCancel(session, backups, onProgress);
  }

  /// Puts back everything a cancelled clean-up already cleaned, the same way
  /// Undo does, then records the clean-up as what is still removed (usually
  /// nothing). Laptop copies of items that are back on the phone, or that
  /// were never cleaned, are removed; copies of anything still missing stay.
  Future<CleanResult> _putBackAfterCancel(
      int session, Map<String, String> backups, void Function(String step, double progress)? onProgress) async {
    var back = 0;
    Object? stoppedBy;
    try {
      back = await undo(session, onProgress: (s) => onProgress?.call(s, -1));
    } on PhoneDisconnected catch (e) {
      stoppedBy = e; // the rest can be put back with "Undo last clean-up"
    }
    final ops = store.opsOf(session);
    final still = ops.where((o) => o.state == OpState.done).toList();
    final freed = still.fold(0, (s, o) => s + o.bytes);
    store.finishSession(session, itemsRemoved: still.length, bytesFreed: freed);
    final keep = {for (final o in still) o.path};
    dropBackups([for (final e in backups.entries) if (!keep.contains(e.key)) e.value]);
    return CleanResult(session, still.length,
        {
          for (final o in still)
            o.path: o.error ??
                (o.method == CleanMethod.delete && o.backup == null
                    ? 'Deleted without a backup, so it can\'t come back.'
                    : 'Couldn\'t be put back yet. "Undo last clean-up" tries again.'),
        },
        freed,
        stoppedBy: stoppedBy, cancelled: true, putBack: back);
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
  ///
  /// A backup is never copied over a file now at its place on the phone:
  /// that item is skipped, stays 'done' (not counted as put back), and the
  /// reason ([keptNewerFile]) is kept in the journal and passed to [onSkipped].
  ///
  /// Only a clean-up of this runner's own phone is undone; any other is
  /// refused before the phone is touched, so one phone's Trash ids and
  /// laptop backups never reach another phone.
  Future<int> undo(int session,
      {void Function(String step)? onProgress, void Function(String path, String why)? onSkipped}) async {
    if (store.phoneOf(session) != serial) {
      throw CleanError('this clean-up was made on another phone, so nothing was changed');
    }
    var back = 0;
    final ops = store.opsOf(session).where((o) => o.state == OpState.done).toList();
    for (var start = 0; start < ops.length; start += batch) {
      final part = ops.sublist(start, (start + batch).clamp(0, ops.length));
      onProgress?.call('Putting back ${start + part.length} of ${ops.length}…');

      // Out of the Trash, several side by side.
      final fromTrash = [for (final op in part) if (op.method == CleanMethod.trash) op];
      Map<String, CleanError> notBack;
      try {
        notBack = await cleaner.restoreManyFromTrash([
          for (final op in fromTrash)
            PhoneFile(id: op.mediaId, path: op.path, folder: '', bytes: op.bytes, mime: '', modifiedSec: 0),
        ]);
      } on PhoneDisconnected {
        rethrow;
      } catch (e) {
        notBack = {for (final op in fromTrash) op.path: CleanError('$e')}; // left as 'done'; shown as not restored
      }
      for (final op in fromTrash.where((op) => !notBack.containsKey(op.path))) {
        store.markOp(op.id, OpState.restored);
        back++;
      }

      // Copied back from the laptop one by one (fast), then listed in the
      // gallery side by side (slow one at a time).
      final toIndex = <String>[];
      for (final op in part.where((op) => op.method != CleanMethod.trash && op.backup != null)) {
        try {
          await cleaner.putBack(op.backup!, op.path, index: false);
          if (!op.path.contains('/Android/media/')) toIndex.add(op.path);
          store.markOp(op.id, OpState.restored);
          back++;
        } on PhoneDisconnected {
          rethrow;
        } on PlaceTaken {
          // Something newer is there now; it is kept, and so is the backup.
          store.markOp(op.id, OpState.done, error: keptNewerFile);
          onSkipped?.call(op.path, keptNewerFile);
        } catch (_) {
          // leave as 'done'; shown as not restored
        }
      }
      // Deleted without a backup: cannot come back, stays 'done'.
      try {
        await cleaner.indexMany(toIndex);
      } on PhoneDisconnected {
        rethrow;
      } catch (_) {
        // The files are back; the gallery lists them on its own later.
      }
    }
    return back;
  }
}
