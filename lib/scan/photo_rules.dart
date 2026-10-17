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
  return Verdict(JunkCategory.blurry, confidence, reasons);
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
  });

  final String id;
  final DateTime takenAt;
  final int dHash;
  final double sharpness;
  final int bytes;

  /// Hash of the file's bytes; equal means byte-for-byte identical.
  final String? contentHash;
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
/// Near-duplicates must be visually almost identical ([maxDistance] bits of
/// dHash) and, unless they're extremely close, taken within [burstWindow] of
/// each other — so two similar sunsets from different days are left alone.
List<DuplicateGroup> findDuplicates(
  List<PhotoFingerprint> photos, {
  int nearIdentical = 3,
  int maxDistance = 8,
  Duration burstWindow = const Duration(minutes: 2),
}) {
  final sorted = [...photos]..sort((a, b) => a.takenAt.compareTo(b.takenAt));
  final parent = List<int>.generate(sorted.length, (i) => i);
  int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
  void union(int a, int b) => parent[find(a)] = find(b);

  for (var i = 0; i < sorted.length; i++) {
    for (var j = i + 1; j < sorted.length; j++) {
      final a = sorted[i], b = sorted[j];
      final inBurst = b.takenAt.difference(a.takenAt) <= burstWindow;
      final sameBytes = a.contentHash != null && a.contentHash == b.contentHash;
      final d = hammingDistance(a.dHash, b.dHash);
      if (sameBytes || d <= nearIdentical || (inBurst && d <= maxDistance)) {
        union(i, j);
      }
    }
  }

  final groups = <int, List<PhotoFingerprint>>{};
  for (var i = 0; i < sorted.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(sorted[i]);
  }

  return [
    for (final members in groups.values.where((g) => g.length > 1))
      _toGroup(members, nearIdentical),
  ];
}

DuplicateGroup _toGroup(List<PhotoFingerprint> members, int nearIdentical) {
  final keep = members.reduce((best, p) =>
      p.sharpness > best.sharpness || (p.sharpness == best.sharpness && p.bytes > best.bytes)
          ? p
          : best);
  final others = <PhotoFingerprint, Verdict>{};
  for (final p in members) {
    if (identical(p, keep)) continue;
    if (p.contentHash != null && p.contentHash == keep.contentHash) {
      others[p] = const Verdict(JunkCategory.exactDuplicate, 0.99, ['Exact copy of another photo']);
    } else {
      final d = hammingDistance(p.dHash, keep.dHash);
      others[p] = d <= nearIdentical
          ? const Verdict(JunkCategory.nearDuplicate, 0.9, ['Almost identical to a sharper photo'])
          : const Verdict(JunkCategory.nearDuplicate, 0.7, ['Similar to a sharper photo taken moments apart']);
    }
  }
  return DuplicateGroup(keep, others);
}
