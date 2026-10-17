import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saaf/scan/scan_cache.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('saaf_cache_test');
    file = File('${dir.path}/scan_cache.json');
  });
  tearDown(() => dir.delete(recursive: true));

  const photo = Analysis(
    modified: 1000, bytes: 2048, takenAtMs: 5, screenshot: false,
    dHash: -8070450532247928832, sharpness: 12.5, entropy: 6.1, faceCount: 0,
  );
  const shot = Analysis(
    modified: 2000, bytes: 512, takenAtMs: 6, screenshot: true, text: 'Paid to\n₹250',
  );

  test('saves and reloads everything, including large fingerprints', () async {
    await ScanCache(file, {'a': photo, 'b': shot}).save();
    final loaded = await ScanCache.load(file);

    final a = loaded.lookup('a', 1000)!;
    expect(a.dHash, photo.dHash);
    expect(a.sharpness, 12.5);
    expect(a.faceCount, 0);
    expect(loaded.lookup('b', 2000)!.text, 'Paid to\n₹250');
  });

  test('an edited photo (new modified time) is analysed again', () async {
    final cache = ScanCache(file, {'a': photo});
    expect(cache.lookup('a', 1000), isNotNull);
    expect(cache.lookup('a', 1001), isNull);
  });

  test('deleted photos are forgotten', () {
    final cache = ScanCache(file, {'a': photo, 'b': shot})..retainOnly({'b'});
    expect(cache.entries.keys, ['b']);
  });

  test('missing or corrupt file means a fresh start, not a crash', () async {
    expect((await ScanCache.load(file)).entries, isEmpty);
    await file.writeAsString('{not json');
    expect((await ScanCache.load(file)).entries, isEmpty);
  });

  test('old file format is discarded', () async {
    await file.writeAsString('{"v": 0, "items": {"a": {}}}');
    expect((await ScanCache.load(file)).entries, isEmpty);
  });
}
