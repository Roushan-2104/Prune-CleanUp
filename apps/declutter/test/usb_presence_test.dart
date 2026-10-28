import 'package:declutter/usb_presence.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pnputil parsing behind the setup guide's "is the phone on USB?" line.
/// Sample output is made up (no real device serials).
void main() {
  String device(String vidPid, String name) => '''
Instance ID:                USB\\VID_$vidPid\\ABC123
Device Description:         $name
Status:                     Started
''';

  test('a Samsung phone on USB is found, with its brand', () {
    final r = phoneInDeviceList(device('04E8&PID_6860', 'SAMSUNG Mobile USB Composite Device') + device('046D&PID_C542', 'Mouse'));
    expect(r.look, UsbLook.phone);
    expect(r.brand, 'samsung');
  });

  test("Google's shared id finds a phone but names no brand", () {
    final r = phoneInDeviceList(device('18D1&PID_4E11', 'Android phone'));
    expect(r.look, UsbLook.phone);
    expect(r.brand, isNull);
  });

  test('only mice, cameras and hubs: no phone (charge-only cable)', () {
    final r = phoneInDeviceList(device('046D&PID_C542', 'Mouse') + device('0BDA&PID_B86A', 'Camera'));
    expect(r.look, UsbLook.nothing);
  });
}
