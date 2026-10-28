import 'dart:async';
import 'dart:io';

import 'package:phone_link/phone_link.dart';
import 'package:vision_helper/vision_helper.dart';

import 'dev_log.dart';

/// Turns an error into one calm sentence a person can act on. The technical
/// detail goes to the development log only, never to the screen.
String friendlyError(Object e) {
  devLog('error: $e');
  return switch (e) {
    PhoneDisconnected() => 'The phone was disconnected. Plug it back in and unlock it to carry on.',
    RealPhoneLocked() => 'Prune didn\'t change this phone. Nothing was removed.',
    CleanError(:final message) => _sentence(message),
    VisionError() => 'Windows couldn\'t check some photos. Close Prune and open it again to retry.',
    TimeoutException() => 'The phone took too long to answer. Unlock it, check the cable, and try again.',
    ProcessException() => 'Prune couldn\'t talk to the phone. Unplug it, plug it back in, and try again.',
    FileSystemException() => 'Prune couldn\'t save to this laptop. Check there is free space, then try again.',
    _ => 'Something unexpected happened. Unplug the phone, plug it back in, and try again.',
  };
}

/// "could not copy back x" → "Could not copy back x."
String _sentence(String s) {
  final t = s.trim();
  if (t.isEmpty) return 'The phone refused this change.';
  final first = t[0].toUpperCase() + t.substring(1);
  return RegExp(r'[.!?]$').hasMatch(first) ? first : '$first.';
}
