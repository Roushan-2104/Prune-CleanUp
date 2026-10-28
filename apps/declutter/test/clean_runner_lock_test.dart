import 'package:declutter/cleaning.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_link/phone_link.dart';

/// The clean-up's safety lock, with no phone needed: adb never runs.
void main() {
  test('a real phone is refused before anything is copied or changed', () {
    final store = Store.inMemory();
    final runner = CleanRunner(store: store, adb: Adb('no-such-adb.exe'), serial: 'TESTREAL0001', phoneLabel: 'real');
    expect(() => runner.cleaner, throwsA(isA<RealPhoneLocked>()));
  });
}
