import 'dart:io';

import 'package:declutter_store/declutter_store.dart';
import 'package:phone_link/phone_link.dart';

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
  CleanResult(this.session, this.done, this.failed, this.bytesFreed);
  final int session;
  final int done;
  final Map<String, String> failed; // path → why
  final int bytesFreed;
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
  CleanRunner({required this.store, required this.adb, required this.serial, required this.phoneLabel});

  final Store store;
  final Adb adb;
  final String serial;
  final String phoneLabel;

  /// Throws [RealPhoneLocked] for real phones in this build.
  late final PhoneCleaner cleaner = PhoneCleaner(adb.adbPath, serial);

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
      for (final f in plan.toDelete.where((f) => !deletable.contains(f))) f.path: 'Not deleted: backup failed',
    };

    final session = store.startSession(serial);
    final work = [
      for (final f in plan.toTrash) (f, CleanMethod.trash),
      for (final f in deletable) (f, CleanMethod.delete),
    ];
    final ids = store.planCleanOps(session, serial, [
      for (final (f, m) in work) PlannedOp(f.path, f.bytes, m, backup: backups[f.path], mediaId: f.id),
    ]);

    var done = 0, freed = 0;
    final failed = <String, String>{...skipped};
    for (final (i, (f, method)) in work.indexed) {
      onProgress?.call('Cleaning… ${i + 1} of ${work.length}', 0.5 + 0.5 * (i + 1) / work.length);
      try {
        method == CleanMethod.trash ? await cleaner.moveToTrash(f) : await cleaner.deleteForever(f);
        store.markOp(ids[i], OpState.done);
        done++;
        freed += f.bytes;
      } on PhoneDisconnected {
        rethrow; // the rest stay 'planned' in the journal and are checked next time
      } catch (e) {
        store.markOp(ids[i], OpState.failed, error: '$e');
        failed[f.path] = '$e';
      }
    }
    store.finishSession(session, itemsRemoved: done, bytesFreed: freed);
    return CleanResult(session, done, failed, freed);
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
