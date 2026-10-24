import 'dart:convert';
import 'dart:io';

import 'media_list.dart';
import 'read_only_guard.dart' show shellQuote;

/// Thrown when the cleaner is pointed at a real phone without explicit
/// permission. During development only virtual phones may be changed.
class RealPhoneLocked implements Exception {
  RealPhoneLocked(this.serial);
  final String serial;
  @override
  String toString() => 'Refusing to change $serial: only virtual phones may be changed in this build.';
}

class CleanError implements Exception {
  CleanError(this.message);
  final String message;
  @override
  String toString() => 'CleanError: $message';
}

/// The ONLY code in Declutter that changes a phone. Everything else goes
/// through the read-only guard.
///
/// - Files in Android's media list go to the phone's own Trash (restorable
///   on the phone for 30 days) or are deleted through the media list.
/// - Files Android hides (no media id) can only be deleted outright, so the
///   app backs them up first or asks for explicit confirmation.
///
/// Safety: refuses any device that isn't a virtual phone (`emulator-…`)
/// unless [allowRealPhone] is passed explicitly.
class PhoneCleaner {
  PhoneCleaner(this.adbPath, this.serial, {bool allowRealPhone = false}) {
    if (!isVirtualPhone(serial) && !allowRealPhone) throw RealPhoneLocked(serial);
  }

  final String adbPath;
  final String serial;

  static bool isVirtualPhone(String serial) => serial.startsWith('emulator-');

  /// Moves a media-listed file to the phone's Trash.
  Future<void> moveToTrash(PhoneFile f) async => _setTrashed(_mediaId(f), true);

  /// Brings a file back out of the phone's Trash.
  Future<void> restoreFromTrash(PhoneFile f) async => _setTrashed(_mediaId(f), false);

  /// Deletes for good: through the media list when Android lists the file,
  /// otherwise by removing it directly.
  Future<void> deleteForever(PhoneFile f) async {
    if (f.id != null) {
      await _shell('content delete --uri content://media/external/file/${_mediaId(f)}');
    } else {
      await _shell('rm -- ${shellQuote(f.path)}');
    }
    if (await exists(f.path)) throw CleanError('${f.name} is still on the phone after deleting');
  }

  /// Copies a laptop backup back to [phonePath] and asks Android to list it.
  Future<void> putBack(String localPath, String phonePath, {bool index = true}) async {
    final r = await Process.run(adbPath, ['-s', serial, 'push', localPath, phonePath], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (r.exitCode != 0) throw CleanError('could not copy back ${File(localPath).uri.pathSegments.last}: ${r.stderr}');
    if (index) await _shell('content call --uri content://media/external/file --method scan_file --arg ${shellQuote(phonePath)}');
  }

  /// Whether a file is at [path] (a trashed file is renamed, so it isn't).
  Future<bool> exists(String path) async {
    final r = await Process.run(adbPath, ['-s', serial, 'shell', 'stat -c %s ${shellQuote(path)}'], stdoutEncoding: utf8);
    return r.exitCode == 0 && int.tryParse((r.stdout as String).trim()) != null;
  }

  Future<void> _setTrashed(String id, bool trashed) async {
    await _shell('content update --uri content://media/external/file/$id --bind is_trashed:i:${trashed ? 1 : 0}');
  }

  /// Media ids are numbers; anything else would be a bug (or an injection).
  String _mediaId(PhoneFile f) {
    final id = f.id;
    if (id == null) throw CleanError('${f.name} is not in Android\'s media list, so it has no Trash');
    if (!RegExp(r'^\d+$').hasMatch(id)) throw CleanError('unexpected media id "$id"');
    return id;
  }

  Future<String> _shell(String command) async {
    final r = await Process.run(adbPath, ['-s', serial, 'shell', command], stdoutEncoding: utf8, stderrEncoding: utf8);
    final out = '${r.stdout}${r.stderr}';
    if (r.exitCode != 0 || out.contains('Error while accessing provider') || out.contains('Exception')) {
      throw CleanError(out.trim().split('\n').first);
    }
    return out;
  }
}
