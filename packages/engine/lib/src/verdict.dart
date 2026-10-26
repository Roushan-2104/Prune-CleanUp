/// What kind of junk an item looks like.
enum JunkCategory {
  paymentScreenshot('Payment screenshots'),
  chatScreenshot('Chat screenshots'),
  otherScreenshot('Other screenshots'),
  blurry('Blurry photos'),
  exactDuplicate('Exact duplicates'),
  nearDuplicate('Similar photos'),
  whatsappSent('WhatsApp sent copies'),
  shortClip('Accidental short clips'),
  screenRecording('Old screen recordings'),
  largeVideo('Very large videos'),
  oldInstaller('Old app installers'),
  oldVoiceNote('Old voice notes'),
  oldDocument('Old documents & downloads'),
  cacheFiles('Caches that rebuild themselves');

  const JunkCategory(this.label);
  final String label;
}

/// How sure we are. Only [sure] items are pre-selected for deletion.
enum Tier { sure, maybe, hidden }

/// The engine's opinion about one gallery item.
class Verdict {
  const Verdict(this.category, this.confidence, this.reasons, {this.label, this.evidence = const {}});

  final JunkCategory category;

  /// The facts behind the verdict, shown as "How we know", in order —
  /// e.g. {"Content fingerprint": "3f2a…9c1e on both", "Size": "2,345,678 bytes on both"}.
  final Map<String, String> evidence;

  /// The same verdict with a different confidence and extra reasons.
  Verdict adjusted(double confidence, List<String> moreReasons) =>
      Verdict(category, confidence, [...reasons, ...moreReasons], label: label, evidence: evidence);

  /// Finer grouping inside a category, e.g. "Instagram / Reels" for an
  /// [JunkCategory.otherScreenshot]. Null when there is nothing more specific.
  final String? label;

  /// 0.0 – 1.0
  final double confidence;

  /// Human-readable reasons shown to the user, e.g. "Has UPI reference number".
  final List<String> reasons;

  Tier get tier => Thresholds.defaults.tierFor(this);

  @override
  String toString() =>
      'Verdict(${category.name}, ${confidence.toStringAsFixed(2)}, $reasons)';
}

/// Confidence cut-offs per tier. Kept conservative: a wrongly flagged good
/// photo costs far more trust than a missed junk one.
///
/// Phase 2 will adjust these per category from the user's keep/delete history.
class Thresholds {
  const Thresholds({this.sure = 0.9, this.maybe = 0.6, this.perCategory = const {}});

  final double sure;
  final double maybe;

  /// Optional per-category override of the "sure" cut-off.
  final Map<JunkCategory, double> perCategory;

  static const defaults = Thresholds();

  Tier tierFor(Verdict v) {
    final sureCut = perCategory[v.category] ?? sure;
    if (v.confidence >= sureCut) return Tier.sure;
    if (v.confidence >= maybe) return Tier.maybe;
    return Tier.hidden;
  }
}
