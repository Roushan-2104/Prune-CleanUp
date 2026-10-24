import 'image_metrics.dart';
import 'verdict.dart';

/// Blur cut-offs for [bestTileSharpness] on a ~256px thumbnail.
/// Starting guesses — to be calibrated with the in-app accuracy test mode.
class BlurConfig {
  const BlurConfig({this.veryBlurry = 15, this.blurry = 40, this.minEntropy = 3});
  final double veryBlurry;
  final double blurry;

  /// Below this the image is basically flat (black frame, plain wall).
  /// That's an "accidental" shot, not a blurry one — handled separately.
  final double minEntropy;
}

/// Decides whether a camera photo (not a screenshot) is blurry.
///
/// [faceCount] comes from on-device face detection. A blurry photo of people
/// may still be a precious memory, so it is never marked "sure".
Verdict? classifyBlur(GrayImage thumb, {int faceCount = 0, BlurConfig config = const BlurConfig()}) =>
    classifyBlurMetrics(
      sharpness: bestTileSharpness(thumb),
      entropy: entropy(thumb),
      faceCount: faceCount,
      config: config,
    );

/// Same as [classifyBlur], from measurements saved by an earlier scan.
Verdict? classifyBlurMetrics({
  required double sharpness,
  required double entropy,
  int faceCount = 0,
  BlurConfig config = const BlurConfig(),
}) {
  if (entropy < config.minEntropy) return null;

  double confidence;
  final reasons = <String>[];
  if (sharpness < config.veryBlurry) {
    confidence = 0.93;
    reasons.add('Very blurry everywhere');
  } else if (sharpness < config.blurry) {
    confidence = 0.7;
    reasons.add('Looks blurry');
  } else {
    return null;
  }

  if (faceCount > 0) {
    confidence = confidence.clamp(0, 0.65);
    reasons.add('Has people in it — please check');
  }
  return Verdict(JunkCategory.blurry, confidence, reasons, evidence: {
    'Sharpest spot': '${sharpness.round()} (photos below ${config.blurry.round()} look blurry; '
        'below ${config.veryBlurry.round()} very blurry)',
    if (faceCount > 0) 'People': '$faceCount face${faceCount == 1 ? '' : 's'} found, so not pre-ticked',
  });
}

/// Everything the duplicate finder needs to know about one photo.
class PhotoFingerprint {
  const PhotoFingerprint({
    required this.id,
    required this.takenAt,
    required this.dHash,
    required this.sharpness,
    required this.bytes,
    this.contentHash,
    this.entropy = 8,
    this.landscape = false,
  });

  final String id;
  final DateTime takenAt;
  final int dHash;
  final double sharpness;
  final int bytes;

  /// Hash of the file's bytes; equal means byte-for-byte identical.
  final String? contentHash;

  /// Detail level (see [entropy] in image_metrics). Plain photos — sky,
  /// walls, dark shots — get look-alike fingerprints even when different.
  final double entropy;

  final bool landscape;
}

/// A set of duplicate/similar photos. [keep] is the best one; [others] are
/// the suggested deletions with their verdicts.
class DuplicateGroup {
  DuplicateGroup(this.keep, this.others);
  final PhotoFingerprint keep;
  final Map<PhotoFingerprint, Verdict> others;
}

/// Groups exact and near-duplicate photos and picks the best of each group.
///
/// The best photos claim their copies first, and every copy must match the
/// kept photo *directly* — no chains where A≈B and B≈C drag a different-looking
/// C into A's group.
///
/// - Exact copies (same size, dimensions and look): always grouped.
/// - "Sure" near-copies: at most [nearIdentical] bits apart AND taken within
///   [burstWindow] of each other.
/// - "Maybe": nearly identical but taken at different times (e.g. a forwarded
///   copy), or a bit less alike but taken moments apart.
/// Portraits never match landscapes, and plain low-detail photos are skipped.
List<DuplicateGroup> findDuplicates(
  List<PhotoFingerprint> photos, {
  int nearIdentical = 2,
  int maxDistance = 6,
  Duration burstWindow = const Duration(seconds: 60),
  double minEntropy = 4,
}) {
  final ordered = [...photos]..sort((a, b) =>
      b.sharpness != a.sharpness ? b.sharpness.compareTo(a.sharpness) : b.bytes.compareTo(a.bytes));
  final taken = List<bool>.filled(ordered.length, false);
  final groups = <DuplicateGroup>[];

  for (var k = 0; k < ordered.length; k++) {
    if (taken[k]) continue;
    final keep = ordered[k];
    final others = <PhotoFingerprint, Verdict>{};
    for (var j = k + 1; j < ordered.length; j++) {
      if (taken[j]) continue;
      final v = _compare(keep, ordered[j], nearIdentical, maxDistance, burstWindow, minEntropy);
      if (v == null) continue;
      others[ordered[j]] = v;
      taken[j] = true;
    }
    if (others.isNotEmpty) {
      taken[k] = true;
      groups.add(DuplicateGroup(keep, others));
    }
  }
  return groups;
}

Verdict? _compare(PhotoFingerprint keep, PhotoFingerprint p, int nearIdentical, int maxDistance,
    Duration burstWindow, double minEntropy) {
  if (p.contentHash != null && p.contentHash == keep.contentHash) {
    return Verdict(JunkCategory.exactDuplicate, 0.99, ['Exact copy of another photo'], evidence: {
      'Match': 'Same size, same dimensions and same look',
      'Kept photo': _whyKeptPhoto(keep, p),
    });
  }
  if (p.landscape != keep.landscape) return null;
  if (p.entropy < minEntropy || keep.entropy < minEntropy) return null;

  final d = hammingDistance(p.dHash, keep.dHash);
  final apart = p.takenAt.difference(keep.takenAt).abs();
  final inBurst = apart <= burstWindow;
  final evidence = {
    'Looks alike': d == 0 ? 'Visual fingerprints identical' : 'Visual fingerprints differ in $d of 64 points',
    'Taken': inBurst ? '${apart.inSeconds} s apart' : '${_day(keep.takenAt)} and ${_day(p.takenAt)}',
    'Kept photo': _whyKeptPhoto(keep, p),
  };
  if (d <= nearIdentical && inBurst) {
    return Verdict(JunkCategory.nearDuplicate, 0.9, ['Almost identical, taken seconds apart'], evidence: evidence);
  }
  if (d <= nearIdentical) {
    return Verdict(JunkCategory.nearDuplicate, 0.7, ['Looks almost identical to another photo'], evidence: evidence);
  }
  if (inBurst && d <= maxDistance) {
    return Verdict(JunkCategory.nearDuplicate, 0.65, ['Similar to a sharper photo taken moments apart'], evidence: evidence);
  }
  return null;
}

String _whyKeptPhoto(PhotoFingerprint keep, PhotoFingerprint p) => keep.sharpness > p.sharpness
    ? 'Sharper (detail ${keep.sharpness.round()} vs ${p.sharpness.round()})'
    : 'Bigger, higher-quality file';

String _day(DateTime t) => '${t.day}/${t.month}/${t.year}';
