import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Whether this laptop is running on its battery right now. Windows slows the
/// processor down on battery, and the photo check is processor work, so it
/// can take two or three times longer unplugged. False when unknown.
bool onBattery() {
  if (!Platform.isWindows) return false;
  final status = calloc<_PowerStatus>();
  try {
    if (_getSystemPowerStatus(status) == 0) return false;
    final s = status.ref;
    // ACLineStatus 0 = unplugged; BatteryFlag 128 = no battery at all.
    return s.acLineStatus == 0 && s.batteryFlag != 128;
  } finally {
    calloc.free(status);
  }
}

final class _PowerStatus extends Struct {
  @Uint8()
  external int acLineStatus;
  @Uint8()
  external int batteryFlag;
  @Uint8()
  external int batteryLifePercent;
  @Uint8()
  external int systemStatusFlag;
  @Uint32()
  external int batteryLifeTime;
  @Uint32()
  external int batteryFullLifeTime;
}

final _getSystemPowerStatus = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<Int32 Function(Pointer<_PowerStatus>), int Function(Pointer<_PowerStatus>)>('GetSystemPowerStatus');
