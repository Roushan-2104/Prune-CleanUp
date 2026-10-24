import 'dart:io';

import 'package:test/test.dart';
import 'package:declutter_engine/src/learner.dart';
import 'package:declutter_engine/src/verdict.dart';

void main() {
  late Directory dir;
  late Learner learner;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('saaf_learner_test');
    learner = Learner(File('${dir.path}/learning.json'));
  });
  tearDown(() => dir.delete(recursive: true));

  const insta = Verdict(JunkCategory.otherScreenshot, 0.75, ['x'], label: 'Instagram / Reels');
  const payment = Verdict(JunkCategory.paymentScreenshot, 0.92, ['x']);
  const chatMaybe = Verdict(JunkCategory.chatScreenshot, 0.75, ['x']);

  test('nothing changes before enough decisions', () {
    for (var i = 0; i < 4; i++) {
      learner.recordKept('p$i', payment);
    }
    expect(learner.apply(payment).tier, Tier.sure);
  });

  test('often-kept kind is no longer pre-selected', () {
    for (var i = 0; i < 4; i++) {
      learner.recordDeleted('d$i', payment);
    }
    learner.recordKept('k1', payment);
    learner.recordKept('k2', payment);
    final v = learner.apply(payment);
    expect(v.tier, Tier.maybe);
    expect(v.reasons, contains('You often keep these'));
  });

  test('mostly-kept kind stops being suggested', () {
    for (var i = 0; i < 8; i++) {
      learner.recordKept('k$i', insta);
    }
    learner.recordDeleted('d', insta);
    expect(learner.apply(insta).tier, Tier.hidden);
  });

  test('always-deleted kind becomes pre-selected', () {
    for (var i = 0; i < 40; i++) {
      learner.recordDeleted('d$i', chatMaybe);
    }
    expect(learner.apply(chatMaybe).tier, Tier.sure);
  });

  test('learning is per kind: Instagram lessons do not affect payments', () {
    for (var i = 0; i < 10; i++) {
      learner.recordKept('k$i', insta);
    }
    expect(learner.apply(payment).tier, Tier.sure);
  });

  test('undo turns a delete into a keep and remembers the photo', () {
    learner.recordDeleted('a', payment);
    learner.recordRestored(['a']);
    expect(learner.buckets[bucketOf(payment)]!.deleted, 0);
    expect(learner.buckets[bucketOf(payment)]!.kept, 1);
    expect(learner.keptIds, contains('a'));
  });

  test('restoring a photo Saaf never trashed teaches nothing', () {
    learner.recordRestored(['stranger']);
    expect(learner.buckets, isEmpty);
    expect(learner.keptIds, isEmpty);
  });

  test('survives save and reload, including pending undo info', () async {
    learner.recordKept('k', insta);
    learner.recordDeleted('d', payment);
    await learner.save();

    final loaded = await Learner.load(learner.file);
    expect(loaded.keptIds, {'k'});
    expect(loaded.buckets[bucketOf(insta)]!.kept, 1);
    loaded.recordRestored(['d']);
    expect(loaded.buckets[bucketOf(payment)]!.kept, 1);
  });

  test('corrupt file starts fresh', () async {
    await learner.file.writeAsString('garbage');
    expect((await Learner.load(learner.file)).buckets, isEmpty);
  });
}
