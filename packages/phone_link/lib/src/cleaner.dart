import 'dart:convert';
import 'dart:io';

import 'adb.dart' show PhoneDisconnected;
import 'media_list.dart';
import 'read_only_guard.dart' show ensureReadOnly, shellQuote;

/// Runs adb with these arguments. Tests pass a fake one so no phone is needed.
typedef AdbRunner = Future<ProcessResult> Function(List<String> args);

/// Thrown when the cleaner is pointed at a real phone without explicit
/// permission. Only the app's clean-up dialog, after the user presses
/// Clean, allows real phones; tests and tools never do.
class RealPhoneLocked implements Exception {
  RealPhoneLocked(this.serial);
  final String serial;
  @override
  String toString() => 'Refusing to change $serial: real phones may only be changed when the app allows it.';
}

/// A change the phone refused. [message] is plain English and safe to show;
/// [detail] holds the phone's own words, for the journal and logs only.
class CleanError implements Exception {
  CleanError(this.message, {this.detail});
  final String message;
  final String? detail;
  @override
  String toString() => 'CleanError: $message${detail == null ? '' : ' ($detail)'}';
}

/// Undo found a file already at the place a backup would go back to. It is
/// never overwritten: the newer file stays and the backup stays on the laptop.
class PlaceTaken extends CleanError {
  PlaceTaken(this.path) : super('a newer file is in its place; the backup is still on this laptop');
  final String path;
}

/// The ONLY code in Prune that changes a phone. Everything else goes
/// through the read-only guard.
///
/// - Files in Android's media list go to the phone's own Trash (restorable
///   on the phone for 30 days) or are deleted through the media list.
/// - Files Android hides (no media id) can only be deleted outright, so the
///   app backs them up first or asks for explicit confirmation.
///
/// Safety: refuses any device that isn't a virtual phone unless
/// [allowRealPhone] is passed explicitly. The app passes it only for a
/// clean-up the user confirmed; tests never pass it, so no test can change
/// a real phone. Without it, the name must be `emulator-…` AND the device
/// must say it is one ([confirmVirtualPhone]) before anything is changed.
class PhoneCleaner {
  PhoneCleaner(this.adbPath, this.serial, {bool allowRealPhone = false, AdbRunner? runAdb})
      : _allowRealPhone = allowRealPhone,
        _runAdb = runAdb {
    if (!isVirtualPhone(serial) && !allowRealPhone) throw RealPhoneLocked(serial);
  }

  final String adbPath;
  final String serial;
  final bool _allowRealPhone;
  final AdbRunner? _runAdb;

  /// Set once the device has said it is a virtual phone.
  bool _confirmedVirtual = false;

  static bool isVirtualPhone(String serial) => serial.startsWith('emulator-');

  /// Whether `getprop ro.kernel.qemu; getprop ro.boot.qemu` output says the
  /// device is a virtual phone (one of them is "1"; real phones print none).
  static bool saysVirtual(String getpropOutput) => getpropOutput.split(RegExp(r'\s+')).contains('1');

  /// A device that calls itself `emulator-…` must also be one: adb gives
  /// that name to anything listening on local ports 5555–5585, including a
  /// real phone forwarded there, so the name alone isn't proof. Asked once,
  /// before the first change, and remembered. Skipped when real phones are
  /// allowed, since then either kind may be changed.
  Future<void> confirmVirtualPhone() async {
    if (_allowRealPhone || _confirmedVirtual) return;
    final r = await _adb(['-s', serial, 'shell', 'getprop ro.kernel.qemu; getprop ro.boot.qemu']);
    if (r.exitCode != 0 || !saysVirtual('${r.stdout}')) throw RealPhoneLocked(serial);
    _confirmedVirtual = true;
  }

  /// Moves a media-listed file to the phone's Trash.
  Future<void> moveToTrash(PhoneFile f) async {
    await confirmVirtualPhone();
    await _checkSameFile(f);
    await _setTrashed(_mediaId(f), true);
  }

  /// Brings a file back out of the phone's Trash.
  Future<void> restoreFromTrash(PhoneFile f) async {
    await confirmVirtualPhone();
    await _setTrashed(_mediaId(f), false);
  }

  /// Deletes for good: through the media list when Android lists the file,
  /// otherwise by removing it directly.
  Future<void> deleteForever(PhoneFile f) async {
    await confirmVirtualPhone();
    if (f.id != null) {
      await _checkSameFile(f);
      await _shell('content delete --uri content://media/external/file/${_mediaId(f)}');
    } else {
      await _checkUnchanged(f);
      await _shell('rm -- ${shellQuote(f.path)}');
    }
    if (await exists(f.path)) throw CleanError('${f.name} is still on the phone after deleting');
  }

  /// Copies a laptop backup back to [phonePath] and asks Android to list it.
  ///
  /// Never overwrites: if something is at [phonePath] now (a newer file, or
  /// the phone can't say), throws [PlaceTaken] and changes nothing.
  Future<void> putBack(String localPath, String phonePath, {bool index = true}) async {
    await confirmVirtualPhone();
    if (!await _isFree(phonePath)) throw PlaceTaken(phonePath);
    final r = await _adb(['-s', serial, 'push', localPath, phonePath]);
    if (r.exitCode != 0) throw CleanError('could not copy back ${File(localPath).uri.pathSegments.last}', detail: '${r.stderr}'.trim());
    if (index) await _shell('content call --uri content://media/external/file --method scan_file --arg ${shellQuote(phonePath)}');
  }

  /// Whether a file is at [path] (a trashed file is renamed, so it isn't).
  Future<bool> exists(String path) async {
    final r = await _adb(['-s', serial, 'shell', 'stat -c %s ${shellQuote(path)}']);
    return r.exitCode == 0 && int.tryParse((r.stdout as String).trim()) != null;
  }

  /// Whether nothing at all is at [path]: only a clear "no such file"
  /// counts. `stat` doesn't follow links, so a link there counts as taken.
  /// Read-only, through the guard.
  Future<bool> _isFree(String path) async {
    final command = 'stat -c %s -- ${shellQuote(path)}';
    ensureReadOnly(command);
    final r = await _adb(['-s', serial, 'shell', command]);
    final out = '${r.stdout}${r.stderr}';
    _throwIfDisconnected(r.exitCode, out);
    return r.exitCode != 0 && out.toLowerCase().contains('no such file');
  }

  /// Asks the phone, right before changing anything, which file this media
  /// id belongs to. If it isn't [f] (the listing was stale or forged),
  /// nothing is changed.
  Future<void> _checkSameFile(PhoneFile f) async {
    final out = await _shell('content query --uri content://media/external/file/${_mediaId(f)} --projection _data');
    final listed = RegExp(r'_data=(.*)$', multiLine: true).firstMatch(out)?.group(1)?.trimRight();
    if (listed != f.path) {
      throw CleanError('${f.name}: the phone lists a different file under this id, so it was left alone');
    }
  }

  /// For a file Android hides (no media id to ask about): checks, right
  /// before deleting, that its size and date still match what Prune read.
  /// If the file was replaced since, nothing is deleted.
  Future<void> _checkUnchanged(PhoneFile f) async {
    final out = await _shell('stat -c ${shellQuote('%s %Y')} -- ${shellQuote(f.path)}');
    if (!sameSizeAndDate(out, f)) {
      throw CleanError('${f.name} changed since Prune read it, so it was left alone', detail: out.trim());
    }
  }

  /// Whether `stat -c '%s %Y'` output matches [f]'s size and date.
  static bool sameSizeAndDate(String statOutput, PhoneFile f) {
    final parts = statOutput.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) return false;
    return int.tryParse(parts[0]) == f.bytes && int.tryParse(parts[1]) == f.modifiedSec;
  }

  Future<void> _setTrashed(String id, bool trashed) async {
    await _shell('content update --uri content://media/external/file/$id --bind is_trashed:i:${trashed ? 1 : 0}');
  }

  /// Media ids are numbers; anything else would be a bug (or an injection).
  String _mediaId(PhoneFile f) {
    final id = f.id;
    if (id == null) throw CleanError('${f.name} is not in Android\'s media list, so it has no Trash');
    if (!RegExp(r'^\d+$').hasMatch(id)) throw CleanError('${f.name} has an unexpected media id, so it was left alone', detail: id);
    return id;
  }

  Future<ProcessResult> _adb(List<String> args) =>
      _runAdb?.call(args) ?? Process.run(adbPath, args, stdoutEncoding: utf8, stderrEncoding: utf8);

  /// A pulled cable isn't a failed file: the outcome is unknown and is
  /// checked on the next connection, so it must not be recorded as "failed".
  static void _throwIfDisconnected(int exitCode, String out) {
    if (exitCode != 0 &&
        RegExp(r"no devices|device offline|device '.*' not found|device not found|closed|unauthorized")
            .hasMatch(out.toLowerCase())) {
      throw PhoneDisconnected(out.trim().split('\n').first);
    }
  }

  Future<String> _shell(String command) async {
    final r = await _adb(['-s', serial, 'shell', command]);
    final out = '${r.stdout}${r.stderr}';
    _throwIfDisconnected(r.exitCode, out);
    if (r.exitCode != 0 || out.contains('Error while accessing provider') || out.contains('Exception')) {
      throw CleanError('the phone refused the change, so the file was left in place',
          detail: out.trim().split('\n').first);
    }
    return out;
  }
}
