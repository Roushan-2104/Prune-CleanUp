import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

void main() {
  const out = '1559907\t1748667363.225607690\t/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/Sent/VID-1.mp4\n'
      '42\t1700000000.5\t/storage/emulated/0/Download/Bill, March.pdf\r\n'
      '7\t1700000000\t/storage/emulated/0/noext\n'
      'garbage line\n'
      '9\t1\t/data/elsewhere.jpg\n';

  test('parses size, time, folder and type', () {
    final files = parseFindRows(out);
    expect(files, hasLength(3));
    final v = files[0];
    expect(v.bytes, 1559907);
    expect(v.modifiedSec, 1748667363);
    expect(v.folder, 'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/Sent/');
    expect(v.isVideo, isTrue);
    expect(v.hiddenFromMediaList, isTrue);
    expect(files[1].name, 'Bill, March.pdf');
    expect(files[1].mime, 'application/pdf');
    expect(files[2].mime, 'application/octet-stream');
  });

  test('merge keeps media-list entries and adds only unseen paths', () {
    const media = PhoneFile(id: '5', path: '/storage/emulated/0/Download/Bill, March.pdf', folder: 'Download/',
        bytes: 42, mime: 'application/pdf', modifiedSec: 1);
    final merged = mergeListings([media], parseFindRows(out));
    expect(merged, hasLength(3));
    expect(merged.where((f) => f.name == 'Bill, March.pdf').single.id, '5');
  });

  test('files in the phone\'s Trash or half-written are not phone content', () {
    const trashed = '1370452\t1700000000\t/storage/emulated/0/Download/.trashed-1795441376-IMG_holiday_copy.png\n'
        '10\t1700000000\t/storage/emulated/0/DCIM/Camera/.pending-1795441376-VID_1.mp4\n'
        '20\t1700000000\t/storage/emulated/0/DCIM/Camera/IMG_ok.png\n';
    expect(parseFindRows(trashed).map((f) => f.name), ['IMG_ok.png']);
  });

  test('types from extensions', () {
    expect(mimeFromName('a.JPG'), 'image/jpeg');
    expect(mimeFromName('voice.opus'), 'audio/ogg');
    expect(mimeFromName('app.apk'), 'application/vnd.android.package-archive');
    expect(mimeFromName('/folder.with.dots/file'), 'application/octet-stream');
  });
}
