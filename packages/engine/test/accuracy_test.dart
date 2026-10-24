import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:declutter_engine/src/accuracy.dart';
import 'package:declutter_engine/src/verdict.dart';

void main() {
  const surePayment = Verdict(JunkCategory.paymentScreenshot, 0.95, ['x']);
  const maybeChat = Verdict(JunkCategory.chatScreenshot, 0.7, ['x']);
  const sureBlurry = Verdict(JunkCategory.blurry, 0.93, ['x']);
  const nearDup = Verdict(JunkCategory.nearDuplicate, 0.9, ['x']);

  group('evaluate', () {
    test('counts right, wrong kind and good photos flagged', () {
      final report = evaluate(
        {
          'p1': TrueLabel.payment,
          'p2': TrueLabel.chat, // junk, wrong kind
          'p3': TrueLabel.keep, // good photo flagged while "sure"
          'c1': TrueLabel.chat,
        },
        {'p1': surePayment, 'p2': surePayment, 'p3': surePayment, 'c1': maybeChat},
        {'p1', 'p2', 'p3', 'c1'},
      );
      final pay = report.perCategory[JunkCategory.paymentScreenshot]!;
      expect(pay.flagged, 3);
      expect(pay.correct, 1);
      expect(pay.wrongKind, 1);
      expect(pay.goodPhotoFlagged, 1);
      expect(pay.sureGoodPhotoFlagged, 1);
      expect(report.sureFlagged, 3);
      expect(report.sureAccuracy, closeTo(1 / 3, 1e-9));
      expect(report.goodPhotosFlaggedSure, 1);
      expect(report.perCategory[JunkCategory.chatScreenshot]!.accuracy, 1.0);
    });

    test('both duplicate kinds match the "duplicate" answer', () {
      final report = evaluate({'d': TrueLabel.duplicate}, {'d': nearDup}, {'d'});
      expect(report.perCategory[JunkCategory.nearDuplicate]!.correct, 1);
    });

    test('unflagged junk counts as missed; unflagged keepers do not', () {
      final report = evaluate(
        {'u1': TrueLabel.blurry, 'u2': TrueLabel.keep, 'u3': TrueLabel.blurry},
        {},
        {'u1', 'u2', 'u3'},
      );
      expect(report.unflaggedChecked, 3);
      expect(report.missed, {TrueLabel.blurry: 2});
    });

    test('photos deleted since labelling are ignored', () {
      final report = evaluate({'gone': TrueLabel.keep}, {'gone': sureBlurry}, {});
      expect(report.labeled, 0);
    });
  });

  group('pickSample', () {
    final predictions = {
      for (var i = 0; i < 20; i++) 'pay$i': surePayment,
      for (var i = 0; i < 3; i++) 'blur$i': sureBlurry,
    };
    final gallery = [...predictions.keys, for (var i = 0; i < 100; i++) 'plain$i'];

    test('mixes each category with unflagged photos', () {
      final s = pickSample(
          predictions: predictions, galleryIds: gallery, alreadyLabeled: {}, random: Random(1));
      expect(s, hasLength(50));
      expect(s.where((id) => id.startsWith('pay')), hasLength(6));
      expect(s.where((id) => id.startsWith('blur')), hasLength(3));
      expect(s.where((id) => id.startsWith('plain')), hasLength(41));
      expect(s.toSet(), hasLength(50), reason: 'no repeats');
    });

    test('never repeats photos already judged', () {
      final s = pickSample(
          predictions: predictions, galleryIds: gallery, alreadyLabeled: {'blur0', 'plain0'}, random: Random(2));
      expect(s, isNot(contains('blur0')));
      expect(s, isNot(contains('plain0')));
    });
  });

  test('old answers on duplicates are dropped once for a fair re-look', () async {
    final dir = await Directory.systemTemp.createTemp('saaf_labels_v1');
    try {
      final file = File('${dir.path}/labels.json');
      await file.writeAsString('{"d": "keep", "p": "payment"}'); // version 1 format
      final store = await LabelStore.load(file);
      expect(store.version, 1);
      expect(store.upgrade({'d': nearDup, 'p': surePayment}), isTrue);
      expect(store.labels, {'p': TrueLabel.payment});
      expect(store.upgrade({}), isFalse, reason: 'only once');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('labels survive save and reload', () async {
    final dir = await Directory.systemTemp.createTemp('saaf_labels_test');
    try {
      final store = LabelStore(File('${dir.path}/labels.json'))
        ..labels['a'] = TrueLabel.keep
        ..labels['b'] = TrueLabel.payment;
      await store.save();
      final loaded = await LabelStore.load(store.file);
      expect(loaded.labels, {'a': TrueLabel.keep, 'b': TrueLabel.payment});
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
