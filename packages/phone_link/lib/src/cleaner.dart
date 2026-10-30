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

  // ---- Many files at once ------------------------------------------------
  //
  // Each change through Android's media list starts a small Java program on
  // the phone, which takes about a second: one file at a time, 10,000 files
  // took hours. So the methods below check every file's media id against
  // its path in one query, run [parallel] changes side by side on the phone,
  // and then check in one call what really happened. The rules are the same
  // as for one file. They return the files left in place, with why; a pulled
  // cable throws [PhoneDisconnected], and what happened to those files is
  // then settled on the next connection.

  /// [moveToTrash] for many files.
  Future<Map<String, CleanError>> moveManyToTrash(List<PhoneFile> files, {int parallel = 8}) async {
    await confirmVirtualPhone();
    final failed = await _oneByOne(files.where((f) => !_bulkSafe(f.path)), moveToTrash);
    final same = await _sameFiles([for (final f in files) if (_bulkSafe(f.path)) f], failed);
    await _runEach(same, (f) => 'content update --uri content://media/external/file/${_mediaId(f)} --bind is_trashed:i:1',
        failed, parallel, 'the phone refused to move it to the Trash, so it was left in place');
    final there = await _present([for (final f in same) if (!failed.containsKey(f.path)) f.path]);
    for (final f in same.where((f) => there.contains(f.path))) {
      failed[f.path] = CleanError('${f.name} is still in its place after moving it to the Trash');
    }
    return failed;
  }

  /// [restoreFromTrash] for many files.
  Future<Map<String, CleanError>> restoreManyFromTrash(List<PhoneFile> files, {int parallel = 8}) async {
    await confirmVirtualPhone();
    final failed = await _oneByOne(files.where((f) => !_bulkSafe(f.path)), restoreFromTrash);
    final valid = <PhoneFile>[];
    for (final f in files.where((f) => _bulkSafe(f.path))) {
      try {
        _mediaId(f);
        valid.add(f);
      } on CleanError catch (e) {
        failed[f.path] = e;
      }
    }
    await _runEach(valid, (f) => 'content update --uri content://media/external/file/${_mediaId(f)} --bind is_trashed:i:0',
        failed, parallel, 'the phone didn\'t take it out of the Trash');
    final back = await _present([for (final f in valid) if (!failed.containsKey(f.path)) f.path]);
    for (final f in valid.where((f) => !failed.containsKey(f.path) && !back.contains(f.path))) {
      failed[f.path] = CleanError('${f.name} didn\'t come back out of the Trash');
    }
    return failed;
  }

  /// [deleteForever] for many files.
  Future<Map<String, CleanError>> deleteManyForever(List<PhoneFile> files, {int parallel = 8}) async {
    await confirmVirtualPhone();
    final failed = await _oneByOne(files.where((f) => !_bulkSafe(f.path)), deleteForever);
    final safe = files.where((f) => _bulkSafe(f.path));
    final listed = await _sameFiles([for (final f in safe) if (f.id != null) f], failed);
    final hidden = await _unchanged([for (final f in safe) if (f.id == null) f], failed);
    await _runEach(listed, (f) => 'content delete --uri content://media/external/file/${_mediaId(f)}', failed, parallel,
        'the phone refused to delete it, so it was left in place');
    await _runEach(hidden, (f) => 'rm -- ${shellQuote(f.path)}', failed, parallel,
        'the phone refused to delete it, so it was left in place');
    final done = [...listed, ...hidden].where((f) => !failed.containsKey(f.path)).toList();
    final there = await _present([for (final f in done) f.path]);
    for (final f in done.where((f) => there.contains(f.path))) {
      failed[f.path] = CleanError('${f.name} is still on the phone after deleting');
    }
    return failed;
  }

  /// Asks Android to list files copied back by [putBack] with `index: false`,
  /// [parallel] at a time. A file that isn't listed is still back on the
  /// phone; the gallery finds it on its own later.
  Future<void> indexMany(List<String> paths, {int parallel = 8}) async {
    await confirmVirtualPhone();
    await _runEach(paths.where(_bulkSafe).toList(),
        (p) => 'content call --uri content://media/external/file --method scan_file --arg ${shellQuote(p)}',
        <String, CleanError>{}, parallel, '', key: (p) => p);
  }

  /// Files whose media id still belongs to them, asked in one query per 50.
  /// The rest go into [failed] and are left alone.
  Future<List<PhoneFile>> _sameFiles(List<PhoneFile> files, Map<String, CleanError> failed) async {
    final byId = <String, PhoneFile>{};
    for (final f in files) {
      try {
        byId[_mediaId(f)] = f;
      } on CleanError catch (e) {
        failed[f.path] = e;
      }
    }
    final listed = <String, String>{};
    final ids = byId.keys.toList();
    for (var i = 0; i < ids.length; i += 50) {
      final part = ids.sublist(i, (i + 50).clamp(0, ids.length));
      final command = 'content query --uri content://media/external/file --projection _id:_data '
          '--where ${shellQuote('_id IN (${part.join(',')})')}';
      ensureReadOnly(command);
      final r = await _adb(['-s', serial, 'shell', command]);
      final out = '${r.stdout}${r.stderr}';
      _throwIfDisconnected(r.exitCode, out);
      for (final m in RegExp(r'^Row: \d+ _id=(\d+), _data=(.*)$', multiLine: true).allMatches(out)) {
        listed[m.group(1)!] = m.group(2)!.trimRight();
      }
    }
    final same = <PhoneFile>[];
    for (final MapEntry(key: id, value: f) in byId.entries) {
      if (listed[id] == f.path) {
        same.add(f);
      } else {
        failed[f.path] = CleanError('${f.name}: the phone lists a different file under this id, so it was left alone');
      }
    }
    return same;
  }

  /// Hidden files whose size and date still match what Prune read, asked in
  /// one call per batch. A file replaced since goes into [failed].
  Future<List<PhoneFile>> _unchanged(List<PhoneFile> files, Map<String, CleanError> failed) async {
    final seen = await _stat([for (final f in files) f.path]);
    final same = <PhoneFile>[];
    for (final f in files) {
      if (sameSizeAndDate(seen[f.path] ?? '', f)) {
        same.add(f);
      } else {
        failed[f.path] = CleanError('${f.name} changed since Prune read it, so it was left alone');
      }
    }
    return same;
  }

  /// Files [_bulkSafe] keeps out of the batched methods, changed one by one.
  Future<Map<String, CleanError>> _oneByOne(Iterable<PhoneFile> files, Future<void> Function(PhoneFile) change) async {
    final failed = <String, CleanError>{};
    for (final f in files) {
      try {
        await change(f);
      } on CleanError catch (e) {
        failed[f.path] = e;
      }
    }
    return failed;
  }

  /// Which of [paths] are there now (read-only).
  Future<Set<String>> _present(List<String> paths) async => (await _stat(paths)).keys.toSet();

  /// "size date" of each of [paths] that is there, in one read-only `stat`
  /// per batch; missing files are simply absent. Paths are never allowed to
  /// hold a line break (see [_bulkSafe]), so each output line is one file.
  Future<Map<String, String>> _stat(List<String> paths) async {
    final wanted = paths.toSet();
    final seen = <String, String>{};
    for (final part in _byLength(paths, (p) => p)) {
      final command = 'stat -c ${shellQuote('%s %Y %n')} -- ${part.map(shellQuote).join(' ')}';
      ensureReadOnly(command);
      final r = await _adb(['-s', serial, 'shell', command]);
      final out = '${r.stdout}';
      _throwIfDisconnected(r.exitCode, '$out${r.stderr}');
      for (final line in const LineSplitter().convert(out)) {
        final m = RegExp(r'^(\d+) (\d+) (.*)$').firstMatch(line.trimRight());
        if (m != null && wanted.contains(m.group(3))) seen[m.group(3)!] = '${m.group(1)} ${m.group(2)}';
      }
    }
    return seen;
  }

  /// Whether [path] can go through the batched methods: a line break in a
  /// name would split one `stat` line into two. Such files go one by one.
  static bool _bulkSafe(String path) => !path.contains('\n') && !path.contains('\r');

  /// Runs one change per item on the phone, [parallel] at a time, in one
  /// adb call per batch. An item counts as done only if its own command
  /// printed no error; the others go into [failed] with [refused].
  Future<void> _runEach<T>(List<T> items, String Function(T) command, Map<String, CleanError> failed, int parallel,
      String refused, {String Function(T)? key}) async {
    String keyOf(T item) => key?.call(item) ?? (item as PhoneFile).path;
    final p = parallel.clamp(1, 16);
    for (final part in _byLength(items.indexed.toList(), (e) => command(e.$2))) {
      final script = StringBuffer();
      for (final (n, (k, item)) in part.indexed) {
        script.write('(o=\$(${command(item)} 2>&1); case "\$o" in *rror*|*xception*) echo "no $k";; '
            '*) echo "ok $k";; esac) & ');
        if ((n + 1) % p == 0) script.write('wait; ');
      }
      script.write('wait');
      final r = await _adb(['-s', serial, 'shell', script.toString()]);
      final out = '${r.stdout}${r.stderr}';
      _throwIfDisconnected(r.exitCode, out);
      final ok = {for (final m in RegExp(r'^ok (\d+)\s*$', multiLine: true).allMatches(out)) int.parse(m.group(1)!)};
      for (final (k, item) in part) {
        if (!ok.contains(k)) failed[keyOf(item)] = CleanError(refused, detail: out.length > 300 ? null : out.trim());
      }
    }
  }

  /// Splits into batches whose commands stay well under Windows' 32k
  /// command-line limit.
  static List<List<E>> _byLength<E>(List<E> items, String Function(E) text) {
    final batches = <List<E>>[];
    var batch = <E>[], length = 0;
    for (final e in items) {
      final n = text(e).length + 80;
      if (batch.isNotEmpty && (length + n > 16000 || batch.length >= 64)) {
        batches.add(batch);
        batch = [];
        length = 0;
      }
      batch.add(e);
      length += n;
    }
    if (batch.isNotEmpty) batches.add(batch);
    return batches;
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
