/// What kind of junk an item looks like.
enum JunkCategory {
  paymentScreenshot('Payment screenshots'),
  chatScreenshot('Chat screenshots'),
  otpScreenshot('OTP screenshots'),
  otherScreenshot('Other screenshots'),
  blurry('Blurry photos'),
  exactDuplicate('Exact duplicates'),
  nearDuplicate('Similar photos'),
  whatsappSent('WhatsApp sent copies'),
  shortClip('Accidental short clips'),
  screenRecording('Old screen recordings'),
  largeVideo('Very large videos');

  const JunkCategory(this.label);
  final String label;
}

/// How sure we are. Only [sure] items are pre-selected for deletion.
enum Tier { sure, maybe, hidden }

/// The engine's opinion about one gallery item.
class Verdict {
  const Verdict(this.category, this.confidence, this.reasons, {this.label});

  final JunkCategory category;

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
