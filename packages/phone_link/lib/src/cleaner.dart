import 'dart:convert';
import 'dart:io';

import 'adb.dart' show PhoneDisconnected;
import 'media_list.dart';
import 'read_only_guard.dart' show shellQuote;

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

/// The ONLY code in Prune that changes a phone. Everything else goes
/// through the read-only guard.
///
/// - Files in Android's media list go to the phone's own Trash (restorable
///   on the phone for 30 days) or are deleted through the media list.
/// - Files Android hides (no media id) can only be deleted outright, so the
///   app backs them up first or asks for explicit confirmation.
///
/// Safety: refuses any device that isn't a virtual phone (`emulator-…`)
/// unless [allowRealPhone] is passed explicitly. The app passes it only
/// for a clean-up the user confirmed; tests never pass it, so no test can
/// change a real phone.
class PhoneCleaner {
  PhoneCleaner(this.adbPath, this.serial, {bool allowRealPhone = false}) : _allowRealPhone = allowRealPhone {
    if (!isVirtualPhone(serial) && !allowRealPhone) throw RealPhoneLocked(serial);
  }

  final String adbPath;
  final String serial;
  final bool _allowRealPhone;

  static bool isVirtualPhone(String serial) => serial.startsWith('emulator-');

  /// A device that calls itself `emulator-…` must also be one: adb gives
  /// that name to anything listening on local ports 5555–5585, so the name
  /// alone isn't proof. Called before any clean-up starts. Skipped when
  /// real phones are allowed, since then either kind may be changed.
  Future<void> confirmVirtualPhone() async {
    if (_allowRealPhone) return;
    final r = await Process.run(adbPath, ['-s', serial, 'shell', 'getprop ro.kernel.qemu; getprop ro.boot.qemu'],
        stdoutEncoding: utf8);
    if (!(r.stdout as String).split(RegExp(r'\s+')).contains('1')) throw RealPhoneLocked(serial);
  }

  /// Moves a media-listed file to the phone's Trash.
  Future<void> moveToTrash(PhoneFile f) async {
    await _checkSameFile(f);
    await _setTrashed(_mediaId(f), true);
  }

  /// Brings a file back out of the phone's Trash.
  Future<void> restoreFromTrash(PhoneFile f) async => _setTrashed(_mediaId(f), false);

  /// Deletes for good: through the media list when Android lists the file,
  /// otherwise by removing it directly.
  Future<void> deleteForever(PhoneFile f) async {
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
  Future<void> putBack(String localPath, String phonePath, {bool index = true}) async {
    final r = await Process.run(adbPath, ['-s', serial, 'push', localPath, phonePath], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (r.exitCode != 0) throw CleanError('could not copy back ${File(localPath).uri.pathSegments.last}', detail: '${r.stderr}'.trim());
    if (index) await _shell('content call --uri content://media/external/file --method scan_file --arg ${shellQuote(phonePath)}');
  }

  /// Whether a file is at [path] (a trashed file is renamed, so it isn't).
  Future<bool> exists(String path) async {
    final r = await Process.run(adbPath, ['-s', serial, 'shell', 'stat -c %s ${shellQuote(path)}'], stdoutEncoding: utf8);
    return r.exitCode == 0 && int.tryParse((r.stdout as String).trim()) != null;
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

  Future<String> _shell(String command) async {
    final r = await Process.run(adbPath, ['-s', serial, 'shell', command], stdoutEncoding: utf8, stderrEncoding: utf8);
    final out = '${r.stdout}${r.stderr}';
    // A pulled cable isn't a failed file: the outcome is unknown and is
    // checked on the next connection, so it must not be recorded as "failed".
    if (r.exitCode != 0 &&
        RegExp(r"no devices|device offline|device '.*' not found|device not found|closed|unauthorized")
            .hasMatch(out.toLowerCase())) {
      throw PhoneDisconnected(out.trim().split('\n').first);
    }
    if (r.exitCode != 0 || out.contains('Error while accessing provider') || out.contains('Exception')) {
      throw CleanError('the phone refused the change, so the file was left in place',
          detail: out.trim().split('\n').first);
    }
    return out;
  }
}
