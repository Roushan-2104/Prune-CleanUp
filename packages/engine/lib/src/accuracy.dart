import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'verdict.dart';

/// What a photo really is, according to the user.
enum TrueLabel {
  payment('Payment screenshot'),
  chat('Chat screenshot'),
  otp('OTP screenshot'),
  otherScreenshot('Other screenshot'),
  blurry('Blurry photo'),
  duplicate('Duplicate / similar'),
  keep('Good photo — keep');

  const TrueLabel(this.text);
  final String text;

  bool get isJunk => this != keep;

  /// Whether the app's [category] guess agrees with this label.
  bool matches(JunkCategory category) => switch (category) {
        JunkCategory.paymentScreenshot => this == payment,
        JunkCategory.chatScreenshot => this == chat,
        JunkCategory.otpScreenshot => this == otp,
        JunkCategory.otherScreenshot => this == otherScreenshot,
        JunkCategory.blurry => this == blurry,
        JunkCategory.exactDuplicate || JunkCategory.nearDuplicate => this == duplicate,
      };
}

/// The user's answers, kept on the phone in accuracy_labels.json.
/// Never used for learning — only for measuring.
class LabelStore {
  LabelStore(this.file, {this.version = currentVersion});
  final File file;
  final labels = <String, TrueLabel>{};

  /// 1: duplicates were judged without seeing the matched photo.
  /// 2: duplicates are judged side by side with their match.
  int version;
  static const currentVersion = 2;

  static Future<LabelStore> load(File file) async {
    try {
      if (!await file.exists()) return LabelStore(file);
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // Version 1 files were a flat {id: label} map.
      final version = raw['v'] as int? ?? 1;
      final entries = version == 1 ? raw : raw['labels'] as Map<String, dynamic>;
      final s = LabelStore(file, version: version);
      for (final MapEntry(:key, :value) in entries.entries) {
        final label = TrueLabel.values.asNameMap()[value];
        if (label != null) s.labels[key] = label;
      }
      return s;
    } catch (_) {
      return LabelStore(file);
    }
  }

  /// Drops answers for photos the app now calls duplicates if they were
  /// judged before the side-by-side view existed — they deserve a fair re-look.
  bool upgrade(Map<String, Verdict> predictions) {
    if (version >= currentVersion) return false;
    labels.removeWhere((id, _) => switch (predictions[id]?.category) {
          JunkCategory.exactDuplicate || JunkCategory.nearDuplicate => true,
          _ => false,
        });
    version = currentVersion;
    return true;
  }

  Future<void> save() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'v': version,
      'labels': {for (final MapEntry(:key, :value) in labels.entries) key: value.name},
    }));
    await tmp.rename(file.path);
  }
}

/// Picks a mixed batch to label: a few photos from each flagged category,
/// topped up with unflagged photos (to find junk the app missed). Shuffled,
/// so the order gives nothing away.
List<String> pickSample({
  required Map<String, Verdict> predictions,
  required List<String> galleryIds,
  required Set<String> alreadyLabeled,
  int size = 50,
  int perCategory = 6,
  Random? random,
}) {
  final rnd = random ?? Random();
  final byCategory = <JunkCategory, List<String>>{};
  for (final MapEntry(key: id, value: v) in predictions.entries) {
    if (alreadyLabeled.contains(id)) continue;
    byCategory.putIfAbsent(v.category, () => []).add(id);
  }

  final picked = <String>[];
  for (final ids in byCategory.values) {
    ids.shuffle(rnd);
    picked.addAll(ids.take(perCategory));
  }

  final unflagged = galleryIds
      .where((id) => !predictions.containsKey(id) && !alreadyLabeled.contains(id))
      .toList()
    ..shuffle(rnd);
  picked.addAll(unflagged.take(max(0, size - picked.length)));

  return (picked.take(size).toList())..shuffle(rnd);
}

class CategoryScore {
  int flagged = 0;

  /// The user agreed with the category.
  int correct = 0;

  /// Junk, but a different kind (e.g. a payment screenshot filed under chat).
  int wrongKind = 0;

  /// A good photo the app suggested deleting — the mistake that matters most.
  int goodPhotoFlagged = 0;

  int sureFlagged = 0;
  int sureCorrect = 0;
  int sureGoodPhotoFlagged = 0;

  double? get accuracy => flagged == 0 ? null : correct / flagged;
  double? get sureAccuracy => sureFlagged == 0 ? null : sureCorrect / sureFlagged;
}

class AccuracyReport {
  final perCategory = <JunkCategory, CategoryScore>{};

  /// Labeled photos the app did not flag at all.
  int unflaggedChecked = 0;

  /// Junk among those, by what it really was.
  final missed = <TrueLabel, int>{};

  int get labeled => perCategory.values.fold(0, (s, c) => s + c.flagged) + unflaggedChecked;

  int get sureFlagged => perCategory.values.fold(0, (s, c) => s + c.sureFlagged);
  int get sureCorrect => perCategory.values.fold(0, (s, c) => s + c.sureCorrect);
  int get goodPhotosFlagged => perCategory.values.fold(0, (s, c) => s + c.goodPhotoFlagged);
  int get goodPhotosFlaggedSure => perCategory.values.fold(0, (s, c) => s + c.sureGoodPhotoFlagged);
  int get missedTotal => missed.values.fold(0, (s, n) => s + n);

  double? get sureAccuracy => sureFlagged == 0 ? null : sureCorrect / sureFlagged;
}

/// Scores the app's *current* guesses against the user's labels. Because
/// guesses are recomputed from saved measurements, improving the rules
/// re-scores old labels instantly.
///
/// [predictions] holds what the app shows the user; photos not in it were
/// not flagged. [galleryIds] drops labels for photos that no longer exist.
AccuracyReport evaluate(Map<String, TrueLabel> labels, Map<String, Verdict> predictions, Set<String> galleryIds) {
  final report = AccuracyReport();
  for (final MapEntry(key: id, value: truth) in labels.entries) {
    if (!galleryIds.contains(id)) continue;
    final v = predictions[id];
    if (v == null) {
      report.unflaggedChecked++;
      if (truth.isJunk) report.missed.update(truth, (n) => n + 1, ifAbsent: () => 1);
      continue;
    }

    final s = report.perCategory.putIfAbsent(v.category, CategoryScore.new);
    final sure = v.tier == Tier.sure;
    s.flagged++;
    if (sure) s.sureFlagged++;
    if (truth.matches(v.category)) {
      s.correct++;
      if (sure) s.sureCorrect++;
    } else if (truth.isJunk) {
      s.wrongKind++;
    } else {
      s.goodPhotoFlagged++;
      if (sure) s.sureGoodPhotoFlagged++;
    }
  }
  return report;
}
