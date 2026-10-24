import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saaf/scan/image_metrics.dart';
import 'package:saaf/scan/photo_rules.dart';
import 'package:saaf/scan/verdict.dart';

/// Detailed random texture — stands in for a sharp photo.
GrayImage sharpImage({int seed = 1, int size = 256}) {
  final rnd = math.Random(seed);
  return GrayImage(size, size,
      Uint8List.fromList(List.generate(size * size, (_) => rnd.nextInt(256))));
}

/// Box-blurs [img] [passes] times — stands in for a shaky/out-of-focus shot.
GrayImage blurred(GrayImage img, {int passes = 6}) {
  var px = Uint8List.fromList(img.pixels);
  for (var p = 0; p < passes; p++) {
    final out = Uint8List(px.length);
    for (var y = 0; y < img.height; y++) {
      for (var x = 0; x < img.width; x++) {
        var sum = 0, n = 0;
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            final xx = x + dx, yy = y + dy;
            if (xx < 0 || yy < 0 || xx >= img.width || yy >= img.height) continue;
            sum += px[yy * img.width + xx];
            n++;
          }
        }
        out[y * img.width + x] = sum ~/ n;
      }
    }
    px = out;
  }
  return GrayImage(img.width, img.height, px);
}

/// Sharp texture in the centre tile only, blurred elsewhere (portrait mode).
GrayImage portrait() {
  final sharp = sharpImage(seed: 7);
  final soft = blurred(sharp);
  final px = Uint8List.fromList(soft.pixels);
  for (var y = 90; y < 166; y++) {
    for (var x = 90; x < 166; x++) {
      px[y * 256 + x] = sharp.at(x, y);
    }
  }
  return GrayImage(256, 256, px);
}

void main() {
  group('blur', () {
    test('sharp photo is not flagged', () {
      expect(classifyBlur(sharpImage()), isNull);
    });

    test('blurry photo is flagged sure', () {
      final v = classifyBlur(blurred(sharpImage()));
      expect(v, isNotNull);
      expect(v!.category, JunkCategory.blurry);
      expect(v.tier, Tier.sure);
    });

    test('portrait with blurred background is not flagged', () {
      expect(classifyBlur(portrait()), isNull);
    });

    test('blurry photo with faces is only a maybe', () {
      final v = classifyBlur(blurred(sharpImage()), faceCount: 2);
      expect(v!.tier, Tier.maybe);
    });

    test('flat black frame is left for the accidental-shot rule', () {
      final black = GrayImage(64, 64, Uint8List(64 * 64));
      expect(classifyBlur(black), isNull);
    });
  });

  group('dHash', () {
    test('same picture blurred slightly is near-identical', () {
      final a = sharpImage(seed: 3);
      expect(hammingDistance(dHash(a), dHash(blurred(a, passes: 1))), lessThanOrEqualTo(8));
    });

    test('different pictures are far apart', () {
      expect(hammingDistance(dHash(sharpImage(seed: 1)), dHash(sharpImage(seed: 2))),
          greaterThan(15));
    });
  });

  group('duplicates', () {
    final t0 = DateTime(2026, 10, 1, 10);
    PhotoFingerprint fp(String id, int hash, Duration after,
            {double sharp = 100, String? content, double entropy = 7, bool landscape = false}) =>
        PhotoFingerprint(
            id: id, takenAt: t0.add(after), dHash: hash, sharpness: sharp,
            bytes: 1000, contentHash: content, entropy: entropy, landscape: landscape);

    test('keeps the sharpest of a burst', () {
      final groups = findDuplicates([
        fp('a', 0xF0F0, Duration.zero, sharp: 50),
        fp('b', 0xF0F1, const Duration(seconds: 2), sharp: 200),
        fp('c', 0xF0F3, const Duration(seconds: 4), sharp: 80),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.keep.id, 'b');
      expect(groups.single.others.keys.map((p) => p.id), unorderedEquals(['a', 'c']));
    });

    test('exact copies are 0.99 even days apart', () {
      final groups = findDuplicates([
        fp('a', 0x1, Duration.zero, content: 'abc'),
        fp('b', 0x1, const Duration(days: 30), content: 'abc'),
      ]);
      expect(groups.single.others.values.single.category, JunkCategory.exactDuplicate);
    });

    test('similar-ish photos on different days are left alone', () {
      final groups = findDuplicates([
        fp('a', 0x00FF, Duration.zero),
        fp('b', 0x00FF ^ 0x3F, const Duration(days: 3)), // 6 bits apart
      ]);
      expect(groups, isEmpty);
    });

    test('burst shots are "sure"; look-alikes from another day only "maybe"', () {
      final burst = findDuplicates([
        fp('a', 0xF0F0, Duration.zero, sharp: 200),
        fp('b', 0xF0F1, const Duration(seconds: 3)),
      ]);
      expect(burst.single.others.values.single.tier, Tier.sure);

      final later = findDuplicates([
        fp('a', 0xF0F0, Duration.zero, sharp: 200),
        fp('b', 0xF0F1, const Duration(days: 2)),
      ]);
      expect(later.single.others.values.single.tier, Tier.maybe);
    });

    test('no chains: A≈B and B≈C does not drag a different C into A\'s group', () {
      // Each step is 4 bits; A and C are 8 bits apart — too different.
      final groups = findDuplicates([
        fp('a', 0x0000, Duration.zero, sharp: 300),
        fp('b', 0x000F, const Duration(seconds: 20), sharp: 200),
        fp('c', 0x00FF, const Duration(seconds: 40), sharp: 100),
      ]);
      final aGroup = groups.firstWhere((g) => g.keep.id == 'a');
      expect(aGroup.others.keys.map((p) => p.id), ['b']);
      expect(groups.expand((g) => g.others.keys).map((p) => p.id), isNot(contains('c')));
    });

    test('portrait never matches landscape', () {
      final groups = findDuplicates([
        fp('a', 0xF0F0, Duration.zero),
        fp('b', 0xF0F0, const Duration(seconds: 1), landscape: true),
      ]);
      expect(groups, isEmpty);
    });

    test('plain low-detail photos are not matched', () {
      final groups = findDuplicates([
        fp('sky1', 0x0, Duration.zero, entropy: 2.5),
        fp('sky2', 0x0, const Duration(seconds: 5), entropy: 2.5),
      ]);
      expect(groups, isEmpty);
    });
  });
}
