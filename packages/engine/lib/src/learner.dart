import 'dart:convert';
import 'dart:io';

import 'verdict.dart';

/// Which "kind of junk" a verdict belongs to for learning purposes, e.g.
/// "otherScreenshot:Instagram / Reels" or "blurry".
String bucketOf(Verdict v) => v.label == null ? v.category.name : '${v.category.name}:${v.label}';

class BucketStats {
  BucketStats([this.deleted = 0, this.kept = 0]);
  int deleted;
  int kept;
  int get total => deleted + kept;
}

/// Learns from the user's own keep/delete decisions, entirely on the phone.
///
/// - Per bucket it counts how often suggestions were deleted vs kept, and
///   nudges future confidence up or down (see [adjustmentFor]).
/// - It remembers individual photos the user chose to keep, so they are
///   never suggested again.
class Learner {
  Learner(this.file);

  final File file;
  final buckets = <String, BucketStats>{};

  /// Photo ids the user deliberately kept.
  final keptIds = <String>{};

  /// Photos we moved to Trash → their bucket and when, so an Undo/Restore
  /// can turn that "deleted" back into "kept".
  final _trashed = <String, ({String bucket, int atMs})>{};

  static const minDecisions = 5;

  void recordDeleted(String id, Verdict v) {
    final b = bucketOf(v);
    _stats(b).deleted++;
    _trashed[id] = (bucket: b, atMs: DateTime.now().millisecondsSinceEpoch);
  }

  void recordKept(String id, Verdict v) {
    _stats(bucketOf(v)).kept++;
    keptIds.add(id);
  }

  /// The user brought photos back (Undo or Restore): they weren't junk.
  void recordRestored(Iterable<String> ids) {
    for (final id in ids) {
      final t = _trashed.remove(id);
      if (t == null) continue;
      final s = _stats(t.bucket);
      if (s.deleted > 0) s.deleted--;
      s.kept++;
      keptIds.add(id);
    }
  }

  /// How much to shift confidence for this bucket.
  double adjustmentFor(String bucket) {
    final s = buckets[bucket];
    if (s == null || s.total < minDecisions) return 0;
    // Smoothed share of suggestions the user deleted.
    final deleteRate = (s.deleted + 1) / (s.total + 2);
    if (deleteRate < 0.4 && s.total >= 8) return -0.4; // mostly kept → stop suggesting
    if (deleteRate < 0.8) return -0.2; // often kept → never pre-select
    if (deleteRate >= 0.95 && s.total >= 10) return 0.15; // always deleted → pre-select
    return 0;
  }

  /// [v] adjusted by what this user has taught us, with the reason shown.
  Verdict apply(Verdict v) {
    final delta = adjustmentFor(bucketOf(v));
    if (delta == 0) return v;
    return v.adjusted(
      (v.confidence + delta).clamp(0.0, 0.99),
      [delta > 0 ? 'You usually delete these' : 'You often keep these'],
    );
  }

  BucketStats _stats(String bucket) => buckets.putIfAbsent(bucket, BucketStats.new);

  /// Forget kept photos that no longer exist.
  void retainOnly(Set<String> galleryIds) => keptIds.removeWhere((id) => !galleryIds.contains(id));

  static Future<Learner> load(File file) async {
    final l = Learner(file);
    try {
      if (!await file.exists()) return l;
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in (j['buckets'] as Map<String, dynamic>).entries) {
        final v = value as List<dynamic>;
        l.buckets[key] = BucketStats(v[0] as int, v[1] as int);
      }
      l.keptIds.addAll((j['kept'] as List<dynamic>).cast<String>());
      // Android empties its Trash after 30 days; older entries can't be restored.
      final cutoff = DateTime.now().subtract(const Duration(days: 31)).millisecondsSinceEpoch;
      for (final MapEntry(:key, :value) in (j['trashed'] as Map<String, dynamic>).entries) {
        final t = value as List<dynamic>;
        if ((t[1] as int) > cutoff) l._trashed[key] = (bucket: t[0] as String, atMs: t[1] as int);
      }
    } catch (_) {
      // Corrupt file: start learning afresh rather than crash.
      return Learner(file);
    }
    return l;
  }

  Future<void> save() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'buckets': {for (final MapEntry(:key, :value) in buckets.entries) key: [value.deleted, value.kept]},
      'kept': keptIds.toList(),
      'trashed': {for (final MapEntry(:key, :value) in _trashed.entries) key: [value.bucket, value.atMs]},
    }));
    await tmp.rename(file.path);
  }
}
