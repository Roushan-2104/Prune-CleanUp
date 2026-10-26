import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

void main() {
  group('allowed: commands that only read', () {
    for (final cmd in [
      'getprop ro.product.model',
      'df -k /data',
      'du -sk /sdcard/DCIM',
      'ls /sdcard/Download',
      'stat /sdcard/a.jpg',
      'content query --uri content://media/external/file --projection _id:_data',
      'dumpsys diskstats',
      'pm list packages -3',
      "cat '/storage/emulated/0/DCIM/IMG 1.jpg'",
      // Operators inside a quoted file name are just text.
      "cat '/sdcard/WhatsApp/weird; rm -rf & name.jpg'",
      "cat '/sdcard/it'\\''s a photo.jpg'",
      r"find '/storage/emulated/0' -type f -printf '%s\t%T@\t%p\n'",
      "find '/sdcard/WhatsApp' -maxdepth 3 -type f -name '*.mp4'",
      // A quoted folder name that *looks* like an option is just a name.
      "find '/sdcard/-delete' -type f",
      "md5sum '/sdcard/a.jpg' '/sdcard/b c.pdf'",
      "dd if='/sdcard/DCIM/Camera/VID 1.mp4' bs=262144 skip=12 count=4 status=none",
      "dd if='/sdcard/DCIM/Camera/VID 1.mp4' bs=262144 skip=12 count=4 status=none | base64 -w 0",
      // A hostile file name stays a harmless name inside the quotes.
      "dd if='/sdcard/x'\\''; rm -rf /sdcard; echo '\\''y.mp4' bs=1 skip=0 count=1 status=none | base64 -w 0",
    ]) {
      test(cmd, () => expect(() => ensureReadOnly(cmd), returnsNormally));
    }
  });

  group('blocked: anything that could change the phone', () {
    for (final cmd in [
      'rm /sdcard/DCIM/a.jpg',
      'rm -rf /sdcard',
      'mv /sdcard/a.jpg /sdcard/b.jpg',
      'pm uninstall com.whatsapp',
      'pm clear com.whatsapp',
      'pm list packages -3; pm uninstall com.whatsapp',
      'cp /sdcard/a /sdcard/b',
      'content delete --uri content://media/external/file --where _id=1',
      'content update --uri content://media/external/file --bind is_trashed:i:1',
      'content insert --uri content://media/external/file',
      'pm uninstall com.whatsapp',
      'pm trim-caches 1G',
      'am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE',
      'settings put global x 1',
      'touch /sdcard/x',
      'mkdir /sdcard/x',
      'dumpsys diskstats; rm /sdcard/x', // chaining
      'ls /sdcard && rm /sdcard/x',
      'ls /sdcard | xargs rm',
      'cat /sdcard/a > /sdcard/b', // redirect overwrites a file
      r'cat $(rm /sdcard/x)',
      'cat `rm /sdcard/x`',
      'ls /sdcard\nrm /sdcard/x',
      'getprops', // not exactly an allowed verb
      '',
      "find '/sdcard' -type f -delete",
      "find '/sdcard' -name '*.jpg' -exec rm {} +",
      "find '/sdcard' -execdir rm {} +",
      "find '/sdcard' -ok rm {} +",
      "find '/sdcard' -okdir rm {} +",
      "find '/sdcard' -fprint /sdcard/out.txt",
      "find /sdcard -type f -newerXY x", // not on the allow-list
      "md5sum '/sdcard/a.jpg' > /sdcard/hashes.txt", // writing the output to the phone
      "dd if='/sdcard/a.mp4' of='/sdcard/b.mp4' bs=1 skip=0 count=1 status=none", // dd writing a file
      "dd if=/dev/zero of='/sdcard/a.jpg' bs=1 count=1", // overwrite a photo
      "dd if='/sdcard/a.mp4' bs=65536 skip=0 count=1 status=none conv=notrunc",
      "dd of='/sdcard/a.mp4'",
      "dd if='/sdcard/a.mp4' bs=1 skip=0 count=1 status=none | base64 -d", // other pipes
      "dd if='/sdcard/a.mp4' bs=1 skip=0 count=1 status=none | base64 -w 0; rm /sdcard/a.mp4",
      "dd if='/sdcard/a.mp4' bs=1 skip=0 count=1 status=none | sh",
      "cat /sdcard/a.mp4 | base64 -w 0 > /sdcard/b",
    ]) {
      test(cmd.replaceAll('\n', r'\n'), () {
        expect(() => ensureReadOnly(cmd), throwsA(isA<NotReadOnlyError>()));
      });
    }
  });

  test('shellQuote survives quotes inside file names', () {
    expect(shellQuote("it's.jpg"), r"'it'\''s.jpg'");
  });
}
