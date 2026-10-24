import 'dart:io';

import 'package:declutter_engine/declutter_engine.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

PhoneFile file(String name, {int bytes = 100, int modified = 1, String mime = 'image/jpeg'}) => PhoneFile(
      id: name, path: '/storage/emulated/0/DCIM/$name', folder: 'DCIM/', bytes: bytes, mime: mime, modifiedSec: modified);

Analysis measured(PhoneFile f) => Analysis(
    modified: f.modifiedSec, bytes: f.bytes, takenAtMs: 0, screenshot: false, dHash: -42, sharpness: 12.5, entropy: 6.0);

const info = PhoneInfo(brand: 'Nothing', model: 'A059', androidVersion: '16', totalBytes: 1, usedBytes: 1, freeBytes: 0);

void main() {
  late Store store;
  setUp(() => store = Store.inMemory()..rememberPhone('p1', info));
  tearDown(() => store.close());

  test('first connect: everything is new and needs analysis', () {
    final diff = store.syncInventory('p1', [file('a.jpg'), file('b.jpg')]);
    expect(diff.added, 2);
    expect(store.needingAnalysis('p1'), hasLength(2));
  });

  test('second connect: only new and edited files need analysis', () {
    final a = file('a.jpg'), b = file('b.jpg');
    store.syncInventory('p1', [a, b]);
    store.saveMeasurements('p1', {a.path: measured(a), b.path: measured(b)});
    expect(store.needingAnalysis('p1'), isEmpty);

    final bEdited = file('b.jpg', modified: 2);
    final diff = store.syncInventory('p1', [a, bEdited, file('c.jpg')]);
    expect(diff.added, 1);
    expect(diff.changed, 1);
    expect(diff.unchanged, 1);
    expect(store.needingAnalysis('p1'), [bEdited.path, file('c.jpg').path]);
    // The stale measurement for the edited file is not returned.
    expect(store.measurements('p1').keys, [a.path]);
  });

  test('files deleted on the phone are forgotten, with their measurements', () {
    final a = file('a.jpg'), b = file('b.jpg');
    store.syncInventory('p1', [a, b]);
    store.saveMeasurements('p1', {a.path: measured(a), b.path: measured(b)});
    final diff = store.syncInventory('p1', [a]);
    expect(diff.removed, 1);
    expect(store.fileCount('p1'), 1);
    expect(store.measurements('p1').keys, [a.path]);
  });

  test('measurements round-trip exactly, including large fingerprints', () {
    final a = file('a.jpg');
    store.syncInventory('p1', [a]);
    store.saveMeasurements('p1', {
      a.path: Analysis(modified: 1, bytes: 100, takenAtMs: 5, screenshot: true, text: 'Paid to\n₹250',
          dHash: -8070450532247928832, sharpness: 3.25, entropy: 7.5, faceCount: 2),
    });
    final m = store.measurements('p1')[a.path]!;
    expect(m.screenshot, isTrue);
    expect(m.text, 'Paid to\n₹250');
    expect(m.dHash, -8070450532247928832);
    expect(m.faceCount, 2);
  });

  test('two phones never mix', () {
    store.rememberPhone('p2', info);
    store.syncInventory('p1', [file('a.jpg')]);
    store.syncInventory('p2', [file('x.jpg'), file('y.jpg')]);
    expect(store.fileCount('p1'), 1);
    expect(store.fileCount('p2'), 2);
  });

  test('clean-up history adds up', () {
    store.finishSession(store.startSession('p1'), itemsRemoved: 10, bytesFreed: 1000);
    store.finishSession(store.startSession('p1'), itemsRemoved: 5, bytesFreed: 500);
    store.startSession('p1'); // unfinished: interrupted session doesn't count
    expect(store.bytesFreed('p1'), 1500);
  });

  test('data survives closing and reopening the file', () async {
    final dir = await Directory.systemTemp.createTemp('declutter_store');
    try {
      final path = '${dir.path}/declutter.db';
      final s1 = Store.open(path)..rememberPhone('p1', info);
      s1.syncInventory('p1', [file('a.jpg')]);
      s1.close();
      final s2 = Store.open(path);
      expect(s2.fileCount('p1'), 1);
      s2.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('100,000 files sync quickly', () {
    final files = [for (var i = 0; i < 100000; i++) file('IMG_$i.jpg', bytes: i)];
    final sw = Stopwatch()..start();
    store.syncInventory('p1', files);
    final first = sw.elapsedMilliseconds;
    sw.reset();
    final diff = store.syncInventory('p1', files);
    final second = sw.elapsedMilliseconds;
    printOnFailure('first sync $first ms, second $second ms');
    print('100k files: first sync $first ms, re-sync $second ms');
    expect(diff.unchanged, 100000);
    expect(first, lessThan(15000));
    expect(store.needingAnalysis('p1'), hasLength(100000));
  });
}
