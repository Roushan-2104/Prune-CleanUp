import 'dart:io';

/// What Windows sees on its USB ports while Prune waits for a phone. It tells
/// apart the two common dead ends: a cable that only charges (Windows sees
/// nothing) and a phone that is plugged in but has USB debugging off or
/// blocked (Windows sees the phone, adb doesn't).
enum UsbLook { unknown, nothing, phone }

class UsbPresence {
  const UsbPresence(this.look, [this.brand]);
  final UsbLook look;

  /// The phone's maker when its USB vendor id says so (null for Google's
  /// id, which Pixels and several other makers share).
  final String? brand;

  static const unknown = UsbPresence(UsbLook.unknown);
}

/// USB vendor ids of Android phone makers, with the brand the setup guide
/// should open on (null: shared or generic id).
const _androidVendors = <String, String?>{
  '18D1': null, // Google: Pixel, Nothing and many others in some USB modes
  '04E8': 'samsung',
  '2717': 'xiaomi',
  '22D9': 'oneplus', // OPPO, realme and newer OnePlus
  '2A70': 'oneplus',
  '2D95': 'vivo',
  '22B8': 'motorola',
  '12D1': null, // Huawei, Honor
  '0FCE': null, // Sony
  '1004': null, // LG
  '0BB4': null, // HTC
  '0B05': null, // Asus
  '17EF': null, // Lenovo
  '19D2': null, // ZTE
  '0E8D': null, // MediaTek-based phones (Tecno, Infinix, itel…)
  '2E04': null, // HMD / Nokia
  '2AE5': null, // Fairphone
  '1BBB': null, // TCL / Alcatel
};

/// Lists connected devices with Windows' own pnputil (read-only; about a
/// second) and looks for an Android phone's vendor id. [UsbPresence.unknown]
/// when pnputil is missing (Windows before 10 2004) or fails.
Future<UsbPresence> lookForPhoneOnUsb() async {
  try {
    final pnputil = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\pnputil.exe';
    final r = await Process.run(pnputil, ['/enum-devices', '/connected']);
    if (r.exitCode != 0) return UsbPresence.unknown;
    return phoneInDeviceList('${r.stdout}');
  } catch (_) {
    return UsbPresence.unknown;
  }
}

/// The parsing half of [lookForPhoneOnUsb], separate so it can be tested.
UsbPresence phoneInDeviceList(String pnputilOutput) {
  String? brand;
  var found = false;
  for (final m in RegExp(r'USB\\VID_([0-9A-Fa-f]{4})&PID_', caseSensitive: false).allMatches(pnputilOutput)) {
    final vid = m.group(1)!.toUpperCase();
    if (!_androidVendors.containsKey(vid)) continue;
    found = true;
    brand ??= _androidVendors[vid];
  }
  return found ? UsbPresence(UsbLook.phone, brand) : const UsbPresence(UsbLook.nothing);
}
