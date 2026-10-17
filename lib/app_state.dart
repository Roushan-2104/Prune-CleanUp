import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'learn/learner.dart';
import 'scan/scanner.dart';
import 'scan/verdict.dart';
import 'trash/system_trash.dart';

enum ScanStatus { idle, noPermission, scanning, done }

/// Holds the scan results and the user's selections for the whole app.
class AppState extends ChangeNotifier {
  final _scanner = Scanner();
  Learner? _learner;

  Future<Learner> _getLearner() async => _learner ??= await Learner.load(
      File('${(await getApplicationSupportDirectory()).path}/learning.json'));

  ScanStatus status = ScanStatus.idle;
  ScanProgress progress = const ScanProgress(0, 0, 0);
  List<ScanItem> items = [];

  /// Asset ids the user has ticked for deletion.
  final selected = <String>{};

  /// On app start: if we've scanned before, refresh right away. Only new
  /// photos get analysed, so this takes seconds, not minutes.
  Future<void> openApp() async {
    if (await _scanner.hasPreviousScan()) await startScan();
  }

  Future<void> startScan() async {
    if (status == ScanStatus.scanning) return;
    if (!await _scanner.requestAccess()) {
      status = ScanStatus.noPermission;
      notifyListeners();
      return;
    }
    status = ScanStatus.scanning;
    notifyListeners();

    final results = await _scanner.scan(onProgress: (p) {
      progress = p;
      notifyListeners();
    });

    // Apply what this user has taught us: skip photos they chose to keep,
    // and shift confidence for kinds of junk they usually keep or delete.
    final learner = await _getLearner();
    items = results
        .where((i) => !learner.keptIds.contains(i.asset.id))
        .map((i) => i.withVerdict(learner.apply(i.verdict)))
        .where((i) => i.verdict.tier != Tier.hidden)
        .toList()
      ..sort((a, b) => b.verdict.confidence.compareTo(a.verdict.confidence));
    selected
      ..clear()
      ..addAll(items.where((i) => i.verdict.tier == Tier.sure).map((i) => i.asset.id));
    status = ScanStatus.done;
    notifyListeners();
  }

  List<ScanItem> itemsIn(JunkCategory c) =>
      items.where((i) => i.verdict.category == c).toList();

  int bytesOf(Iterable<ScanItem> list) => list.fold(0, (sum, i) => sum + i.bytes);

  int get selectedBytes => bytesOf(items.where((i) => selected.contains(i.asset.id)));

  void toggle(String id) {
    selected.contains(id) ? selected.remove(id) : selected.add(id);
    notifyListeners();
  }

  void setAll(Iterable<ScanItem> list, bool value) {
    for (final i in list) {
      value ? selected.add(i.asset.id) : selected.remove(i.asset.id);
    }
    notifyListeners();
  }

  /// Moves the selected items of [category] to Trash. Returns the ids moved.
  ///
  /// Also a lesson for the learner: deleted items were junk, and "sure"
  /// items the user unticked before deleting the rest were not.
  Future<List<String>> trashSelected(JunkCategory category) async {
    final inCategory = itemsIn(category);
    final chosen = inCategory.where((i) => selected.contains(i.asset.id)).toList();
    if (chosen.isEmpty) return [];
    final moved = await moveToTrash(chosen.map((i) => i.asset).toList());
    final movedSet = moved.toSet();
    if (movedSet.isEmpty) return []; // user cancelled the system dialog

    final learner = await _getLearner();
    for (final i in chosen.where((i) => movedSet.contains(i.asset.id))) {
      learner.recordDeleted(i.asset.id, i.verdict);
    }
    final unticked = inCategory
        .where((i) => i.verdict.tier == Tier.sure && !selected.contains(i.asset.id))
        .toList();
    for (final i in unticked) {
      learner.recordKept(i.asset.id, i.verdict);
    }
    await learner.save();

    final gone = {...movedSet, ...unticked.map((i) => i.asset.id)};
    items.removeWhere((i) => gone.contains(i.asset.id));
    selected.removeAll(movedSet);
    notifyListeners();
    return moved;
  }

  /// "Keep — don't suggest again" on a single photo.
  Future<void> keep(ScanItem item) async {
    final learner = await _getLearner();
    learner.recordKept(item.asset.id, item.verdict);
    await learner.save();
    items.removeWhere((i) => i.asset.id == item.asset.id);
    selected.remove(item.asset.id);
    notifyListeners();
  }

  /// Puts trashed photos back, then refreshes results (only those few get re-checked).
  Future<bool> undoTrash(List<String> ids) async {
    if (!await SystemTrash.restore(ids)) return false;
    await restored(ids);
    return true;
  }

  /// Photos came back from Trash (Undo or the Trash screen): they weren't junk.
  Future<void> restored(List<String> ids) async {
    final learner = await _getLearner();
    learner.recordRestored(ids);
    await learner.save();
    await startScan();
  }

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }
}

String formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
