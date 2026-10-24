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
      "cat '/storage/emulated/0/DCIM/IMG 1.jpg'",
      // Operators inside a quoted file name are just text.
      "cat '/sdcard/WhatsApp/weird; rm -rf & name.jpg'",
      "cat '/sdcard/it'\\''s a photo.jpg'",
    ]) {
      test(cmd, () => expect(() => ensureReadOnly(cmd), returnsNormally));
    }
  });

  group('blocked: anything that could change the phone', () {
    for (final cmd in [
      'rm /sdcard/DCIM/a.jpg',
      'rm -rf /sdcard',
      'mv /sdcard/a.jpg /sdcard/b.jpg',
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
