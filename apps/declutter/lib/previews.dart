import 'dart:async';
import 'dart:io';

import 'package:phone_link/phone_link.dart';

/// Copies of phone files made only so you can SEE them while reviewing.
///
/// - Copied on demand (only what's on screen or what you open), read-only
///   on the phone.
/// - Kept in a private folder, %LOCALAPPDATA%\Prune\previews, which is
///   emptied when Prune starts and when it closes.
class PreviewCache {
  PreviewCache(this.adb, this.serial);

  final Adb adb;
  final String serial;
  final _inFlight = <String, Future<File?>>{};
  int _running = 0;
  final _queue = <Completer<void>>[];

  static Directory get root {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return Directory('$base\\Prune\\previews');
  }

  /// Deletes every preview. Called on start and on close.
  static void clearAll() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {
      // A file still open in a viewer: it goes next time.
    }
  }

  File _localFor(PhoneFile f) {
    final key = f.path.hashCode.toUnsigned(32).toRadixString(16);
    return File(inside(root.path, [serial, '${key}_${f.name}']));
  }

  /// The local copy of [f], copying it from the phone if needed. Returns
  /// null if the phone couldn't provide it (e.g. it was just removed).
  Future<File?> get(PhoneFile f) {
    final local = _localFor(f);
    if (local.existsSync()) return Future.value(local);
    return _inFlight.putIfAbsent(f.path, () async {
      await _slot();
      try {
        await adb.copyToLaptop(serial, f, local.path);
        return local;
      } catch (_) {
        return null;
      } finally {
        _release();
        unawaited(Future(() => _inFlight.remove(f.path)));
      }
    });
  }

  /// At most 3 copies at a time, so scrolling stays smooth.
  Future<void> _slot() async {
    if (_running < 3) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _running--;
    }
  }
}
