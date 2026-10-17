import 'package:flutter/foundation.dart';

import 'scan/scanner.dart';
import 'scan/verdict.dart';
import 'trash/system_trash.dart';

enum ScanStatus { idle, noPermission, scanning, done }

/// Holds the scan results and the user's selections for the whole app.
class AppState extends ChangeNotifier {
  final _scanner = Scanner();

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

    items = results.where((i) => i.verdict.tier != Tier.hidden).toList()
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
  Future<List<String>> trashSelected(JunkCategory category) async {
    final chosen = itemsIn(category).where((i) => selected.contains(i.asset.id)).toList();
    if (chosen.isEmpty) return [];
    final moved = await moveToTrash(chosen.map((i) => i.asset).toList());
    final movedSet = moved.toSet();
    items.removeWhere((i) => movedSet.contains(i.asset.id));
    selected.removeAll(movedSet);
    notifyListeners();
    return moved;
  }

  /// Puts trashed photos back, then refreshes results (only those few get re-checked).
  Future<bool> undoTrash(List<String> ids) async {
    if (!await SystemTrash.restore(ids)) return false;
    await startScan();
    return true;
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
