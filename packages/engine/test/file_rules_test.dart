import 'package:declutter_engine/declutter_engine.dart';
import 'package:test/test.dart';

final now = DateTime(2026, 10, 24);
int daysAgo(int d) => now.subtract(Duration(days: d)).millisecondsSinceEpoch ~/ 1000;

FileFacts f(String folder, String name,
        {int bytes = 50000, String mime = 'video/mp4', int? durationMs, int age = 1}) =>
    FileFacts(path: '/storage/emulated/0/$folder$name', folder: folder, bytes: bytes, mime: mime,
        modifiedSec: daysAgo(age), durationMs: durationMs);

void main() {
  const sentVideo = 'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/Sent/';
  const sentDocs = 'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents/Sent/';

  test('WhatsApp sent copies are suggested, but not pre-selected on their own', () {
    final v = classifyFiles([f(sentVideo, 'VID-1.mp4')], now: now).values.single.verdict;
    expect(v.category, JunkCategory.whatsappSent);
    expect(v.tier, Tier.maybe);
  });

  test('a sent copy with the identical original elsewhere is a sure duplicate', () {
    final original = f('Download/', 'Report.pdf', mime: 'application/pdf', age: 30);
    final sent = f(sentDocs, 'Report.pdf', mime: 'application/pdf', age: 10);
    final r = classifyFiles([original, sent], now: now, contentHash: {original.path: 'abc', sent.path: 'abc'});
    expect(r.containsKey(original.path), isFalse, reason: 'the original is kept');
    expect(r[sent.path]!.verdict.category, JunkCategory.exactDuplicate);
    expect(r[sent.path]!.verdict.tier, Tier.sure);
    expect(r[sent.path]!.matchPath, original.path);
  });

  test('same size but different content is NOT a duplicate', () {
    final a = f('Download/', 'a.pdf', mime: 'application/pdf'), b = f('Documents/', 'b.pdf', mime: 'application/pdf');
    final r = classifyFiles([a, b], now: now, contentHash: {a.path: 'x', b.path: 'y'});
    expect(r, isEmpty);
  });

  test('camera beats WhatsApp: the copy in the camera roll is kept', () {
    final cam = f('DCIM/Camera/', 'VID_1.mp4', age: 5), wa = f('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/', 'VID-WA1.mp4', age: 50);
    final r = classifyFiles([wa, cam], now: now, contentHash: {cam.path: 'h', wa.path: 'h'});
    expect(r.keys, [wa.path]);
  });

  test('private folders, app data and backups are never suggested', () {
    final files = [
      f('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/Private/', 'secret.mp4', bytes: 900 << 20),
      f('Android/data/com.adobe.lrmobile/files/', 'edit.mp4', bytes: 900 << 20),
      f('Android/media/com.whatsapp/WhatsApp/Backups/', 'msgstore.crypt14', mime: 'application/octet-stream'),
    ];
    expect(classifyFiles(files, now: now), isEmpty);
    expect(sameSizeCandidates([...files, ...files]), isEmpty);
  });

  test('accidental short camera clip', () {
    final v = classifyFiles([f('DCIM/Camera/', 'VID_2.mp4', durationMs: 900)], now: now).values.single.verdict;
    expect(v.category, JunkCategory.shortClip);
    expect(v.reasons.single, contains('0.9 s'));
  });

  test('short WhatsApp clip is left alone (sent on purpose)', () {
    expect(classifyFiles([f('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/', 'VID-9.mp4', durationMs: 900)], now: now),
        isEmpty);
  });

  test('old screen recording is more likely junk than a new one', () {
    final old = classifyFiles([f('Movies/ScreenRecords/', 'Screen_Recording_1.mp4', age: 90)], now: now).values.single.verdict;
    final fresh = classifyFiles([f('Movies/ScreenRecords/', 'Screen_Recording_2.mp4', age: 3)], now: now).values.single.verdict;
    expect(old.category, JunkCategory.screenRecording);
    expect(old.confidence, greaterThan(fresh.confidence));
    expect(old.tier, isNot(Tier.sure), reason: 'never pre-selected');
  });

  test('very large videos are flagged for a look, never pre-selected', () {
    final v = classifyFiles([f('DCIM/Camera/', 'VID_4K.mp4', bytes: 1200 << 20)], now: now).values.single.verdict;
    expect(v.category, JunkCategory.largeVideo);
    expect(v.tier, Tier.maybe);
  });

  test('only files sharing a size need hashing', () {
    final a = f('Download/', 'a.pdf', bytes: 70000), b = f('Documents/', 'b.pdf', bytes: 70000), c = f('Download/', 'c.pdf', bytes: 80000);
    expect(sameSizeCandidates([a, b, c]).map((x) => x.name), unorderedEquals(['a.pdf', 'b.pdf']));
  });
}
