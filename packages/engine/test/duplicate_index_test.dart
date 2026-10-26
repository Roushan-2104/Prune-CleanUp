import 'dart:math' as math;

import 'package:declutter_engine/declutter_engine.dart';
import 'package:test/test.dart';

/// The fast, indexed similar-photo search must find exactly what comparing
/// every pair finds.
void main() {
  test('indexed search gives the same groups as comparing every pair', () {
    final r = math.Random(7);
    int randomHash() => (r.nextInt(1 << 32) << 32) | r.nextInt(1 << 32);
    int nearby(int h, int bits) {
      for (var i = 0; i < bits; i++) {
        h ^= 1 << r.nextInt(64);
      }
      return h;
    }

    final photos = <PhotoFingerprint>[];
    final start = DateTime(2026, 1, 1);
    for (var c = 0; c < 600; c++) {
      final base = randomHash();
      final t = start.add(Duration(minutes: r.nextInt(500000)));
      for (var i = 0; i < 1 + r.nextInt(5); i++) {
        photos.add(PhotoFingerprint(
          id: 'p${photos.length}',
          takenAt: t.add(Duration(seconds: r.nextInt(r.nextBool() ? 90 : 900000))),
          dHash: nearby(base, r.nextInt(9)),
          sharpness: r.nextDouble() * 400,
          bytes: 100000 + r.nextInt(5000000),
          entropy: 3 + r.nextDouble() * 5,
          landscape: r.nextInt(10) == 0,
          contentHash: r.nextInt(20) == 0 ? 'same-$c' : null,
        ));
      }
    }
    String describe(List<DuplicateGroup> gs) => (gs
            .map((g) => '${g.keep.id}:${(g.others.entries.map((e) => '${e.key.id}/${e.value.category.name}/${e.value.confidence}').toList()..sort()).join(',')}')
            .toList()
          ..sort())
        .join('\n');

    final fast = findDuplicates(photos);
    final slow = findDuplicates(photos, indexed: false);
    expect(fast, isNotEmpty);
    expect(describe(fast), describe(slow));
  });
}
