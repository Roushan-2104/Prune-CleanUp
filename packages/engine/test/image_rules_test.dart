import 'package:declutter_engine/declutter_engine.dart';
import 'package:test/test.dart';

ImageFacts img(String folder, String name, {int? w, int? h, int bytes = 500000, int taken = 0}) =>
    ImageFacts(path: '/storage/emulated/0/$folder$name', folder: folder, bytes: bytes, modifiedSec: 1, takenMs: taken, width: w, height: h);

Analysis photo({int hash = 0x0F0F0F0F, double sharp = 200, double entropy = 7, int? faces = 0, int taken = 0, bool landscape = false}) =>
    Analysis(modified: 1, bytes: 500000, takenAtMs: taken, screenshot: false, dHash: hash, sharpness: sharp,
        entropy: entropy, faceCount: faces, landscape: landscape);

Analysis shot(String text) => Analysis(modified: 1, bytes: 500000, takenAtMs: 0, screenshot: true, text: text);

void main() {
  group('which images get text-reading', () {
    test('screenshots folder: yes', () => expect(mightBeScreenshot(img('Pictures/Screenshots/', 'Screenshot_1.png')), isTrue));
    test('camera photo: no', () => expect(mightBeScreenshot(img('DCIM/Camera/', 'IMG_1.jpg', w: 4000, h: 3000)), isFalse));
    test('WhatsApp image: yes (could be a forwarded screenshot)',
        () => expect(mightBeScreenshot(img('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/', 'IMG-1.jpg')), isTrue));
    test('phone-shaped image anywhere: yes', () => expect(mightBeScreenshot(img('Pictures/Other/', 'x.png', w: 1080, h: 2400)), isTrue));
  });

  test('stickers, caches, Mac leftovers and private folders are skipped', () {
    expect(shouldAnalyseImage(img('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Stickers/', 'a.webp')), isFalse);
    expect(shouldAnalyseImage(img('Pictures/.thumbnails/', '1.jpg')), isFalse);
    expect(shouldAnalyseImage(img('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Private/', 'a.jpg')), isFalse);
    expect(shouldAnalyseImage(img('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Backup Excluded Stickers/', 'a.webp')),
        isFalse);
    expect(shouldAnalyseImage(img('Download/luts/', '._Fresh.png')), isFalse);
    expect(shouldAnalyseImage(img('DCIM/Camera/', 'IMG.jpg')), isTrue);
  });

  test('a received payment screenshot is judged by its text, with a note', () {
    final f = img('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/', 'IMG-9.jpg');
    final r = judgeImages({f.path: shot('Payment successful\nPaid to Swiggy\n₹250\nUPI Ref 4287')}, {f.path: f});
    final v = r[f.path]!.verdict;
    expect(v.category, JunkCategory.paymentScreenshot);
    expect(v.reasons.first, contains('received from another app'));
  });

  test('a photo of a poster or letter is not a screenshot, however much text it has', () {
    final f = img('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/', 'IMG-7.jpg', w: 2160, h: 3840);
    const letter = 'Dear friend,\nI am really sorry. I know I might have hurt you, and even if I didn\'t mean to, '
        'I know intention does not erase pain. You matter to me more than I can explain.';
    expect(looksLikeScreenshot(f, letter), isFalse);
    expect(looksLikeScreenshot(f, '21:03\nMeera\nlast seen today at 21:01\nHi 21:02\nHello 21:02'), isTrue);
  });

  test('blurry photo without a face check is never pre-ticked', () {
    final f = img('DCIM/Camera/', 'IMG_blur.jpg');
    final r = judgeImages({f.path: photo(sharp: 5, faces: null)}, {f.path: f});
    expect(r[f.path]!.verdict.category, JunkCategory.blurry);
    expect(r[f.path]!.verdict.tier, Tier.maybe);
  });

  test('burst shots: the sharpest is kept, the other is matched to it', () {
    final a = img('DCIM/Camera/', 'IMG_a.jpg', taken: 0), b = img('DCIM/Camera/', 'IMG_b.jpg', taken: 2000);
    final r = judgeImages({
      a.path: photo(hash: 0xF0F0, sharp: 300, taken: 0),
      b.path: photo(hash: 0xF0F1, sharp: 90, taken: 2000),
    }, {a.path: a, b.path: b});
    expect(r.containsKey(a.path), isFalse);
    expect(r[b.path]!.verdict.category, JunkCategory.nearDuplicate);
    expect(r[b.path]!.matchPath, a.path);
  });

  test('merge: what the image shows beats where it is, but exact copies win', () {
    const sentCopy = FileVerdict(Verdict(JunkCategory.whatsappSent, 0.75, ['sent']));
    const exact = FileVerdict(Verdict(JunkCategory.exactDuplicate, 0.99, ['copy']), matchPath: '/o');
    const payment = FileVerdict(Verdict(JunkCategory.paymentScreenshot, 0.97, ['paid']));
    final m = mergeSuggestions({'/a': sentCopy, '/b': exact}, {'/a': payment, '/b': payment, '/c': payment});
    expect(m['/a']!.verdict.category, JunkCategory.paymentScreenshot);
    expect(m['/b']!.verdict.category, JunkCategory.exactDuplicate);
    expect(m['/c']!.verdict.category, JunkCategory.paymentScreenshot);
  });
}
