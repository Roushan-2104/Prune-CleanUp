import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

/// The cleaner's safety lock, with no phone needed: these never run adb.
void main() {
  const realSerial = 'TESTREAL0001'; // made up; not any real device

  test('a real phone is refused unless explicitly allowed', () {
    expect(() => PhoneCleaner('adb.exe', realSerial), throwsA(isA<RealPhoneLocked>()));
  });

  test('the app can allow a real phone explicitly', () {
    expect(PhoneCleaner('adb.exe', realSerial, allowRealPhone: true).serial, realSerial);
  });

  test('only emulator serials count as virtual phones', () {
    expect(PhoneCleaner.isVirtualPhone('emulator-5554'), isTrue);
    expect(PhoneCleaner.isVirtualPhone(realSerial), isFalse);
    expect(PhoneCleaner.isVirtualPhone('192.168.1.5:5555'), isFalse);
  });

  test('a hidden file is deleted only if its size and date still match the listing', () {
    const f = PhoneFile(path: '/sdcard/x/a.jpg', folder: 'x/', bytes: 1234, mime: 'image/jpeg', modifiedSec: 1700000000);
    expect(PhoneCleaner.sameSizeAndDate('1234 1700000000\n', f), isTrue);
    expect(PhoneCleaner.sameSizeAndDate('1235 1700000000', f), isFalse); // replaced by another file
    expect(PhoneCleaner.sameSizeAndDate('1234 1700000001', f), isFalse); // changed since
    expect(PhoneCleaner.sameSizeAndDate('', f), isFalse);
    expect(PhoneCleaner.sameSizeAndDate('stat: no such file', f), isFalse);
  });

  test('a clean error keeps the phone\'s own words out of its message', () {
    final e = CleanError('the phone refused the change', detail: 'Error while accessing provider');
    expect(e.message, isNot(contains('provider')));
    expect('$e', contains('provider'));
  });
}
