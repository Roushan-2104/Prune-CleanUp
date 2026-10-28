import 'dart:async';
import 'dart:io';

import 'package:declutter/cleaning.dart';
import 'package:declutter/friendly_error.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_link/phone_link.dart';

/// Who may change which phone, and what the user reads when something goes
/// wrong. No phone needed: nothing here runs adb.
void main() {
  const realSerial = 'TESTREAL0001'; // made up; not any real device
  final adb = Adb('adb.exe');

  test('a clean-up runner refuses a real phone by default', () {
    final runner = CleanRunner(store: Store.inMemory(), adb: adb, serial: realSerial, phoneLabel: 'real');
    expect(() => runner.cleaner, throwsA(isA<RealPhoneLocked>()));
  });

  test('only an explicit allowRealPhone lets a runner change a real phone', () {
    final runner =
        CleanRunner(store: Store.inMemory(), adb: adb, serial: realSerial, phoneLabel: 'real', allowRealPhone: true);
    expect(runner.cleaner.serial, realSerial);
  });

  group('error messages are calm and plain', () {
    test('a pulled cable says what to do', () {
      expect(friendlyError(PhoneDisconnected('device offline')), contains('Plug it back in'));
    });

    test('a refused change shows the plain message, not the phone\'s words', () {
      final text = friendlyError(CleanError('the phone refused the change', detail: 'java.lang.SecurityException'));
      expect(text, 'The phone refused the change.');
    });

    test('technical errors never reach the screen', () {
      for (final e in [
        ProcessException('adb.exe', const [], 'boom', 1),
        const FileSystemException('disk full', r'C:\x'),
        TimeoutException('slow'),
        StateError('internal'),
      ]) {
        final text = friendlyError(e);
        expect(text, isNot(anyOf(contains('boom'), contains('Exception'), contains('internal'), contains(r'C:\x'))));
        expect(text, endsWith('.'));
      }
    });
  });
}
