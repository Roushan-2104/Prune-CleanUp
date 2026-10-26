import 'package:flutter/foundation.dart';

/// Diagnostics for development only. They name phone files and show player
/// messages, so release builds (whose output a terminal could capture)
/// print nothing.
void devLog(String message) {
  if (kDebugMode) debugPrint(message);
}
