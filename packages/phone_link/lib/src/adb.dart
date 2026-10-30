import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'find_list.dart';
import 'local_paths.dart';
import 'media_list.dart';
import 'read_only_guard.dart';

/// Thrown when the phone disappears (cable pulled, phone locked USB, etc.).
class PhoneDisconnected implements Exception {
  PhoneDisconnected(this.message);
  final String message;
  @override
  String toString() => 'Phone disconnected: $message';
}

/// What a batch copy managed to bring over.
class CopyReport {
  final copied = <PhoneFile>[];
  final failed = <PhoneFile, String>{};
  int bytes = 0;

  void _ok(PhoneFile f) {
    copied.add(f);
    bytes += f.bytes;
  }
}

class PhoneDevice {
  const PhoneDevice(this.serial, this.state, {this.model});
  final String serial;

  /// "device" = ready, "unauthorized" = user must tap Allow on the phone.
  final String state;
  final String? model;
  bool get ready => state == 'device';
}

class PhoneInfo {
  const PhoneInfo({
    required this.brand,
    required this.model,
    required this.androidVersion,
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
  });
  final String brand;
  final String model;
  final String androidVersion;
  final int totalBytes;
  final int usedBytes;
  final int freeBytes;
}

/// Read-only connection to Android phones through `adb` (USB debugging).
///
/// Every phone command goes through [ensureReadOnly]; there is deliberately
/// no method here that deletes, moves or writes anything on the phone.
class Adb {
  Adb(this.adbPath);
  final String adbPath;

  Future<List<PhoneDevice>> devices() async {
    final out = await _run(['devices', '-l']);
    return [
      for (final line in LineSplitter.split(out).skip(1))
        if (line.trim().isNotEmpty) _parseDevice(line),
    ];
  }

  Future<PhoneInfo> info(String serial) async {
    final props = await shell(serial,
        'getprop ro.product.brand; getprop ro.product.model; getprop ro.build.version.release',
        trusted: true);
    final p = LineSplitter.split(props).map((l) => l.trim()).toList();
    final df = await shell(serial, 'df -k /data');
    final cols = LineSplitter.split(df).last.split(RegExp(r'\s+'));
    return PhoneInfo(
      brand: p.elementAtOrNull(0) ?? '?',
      model: p.elementAtOrNull(1) ?? '?',
      androidVersion: p.elementAtOrNull(2) ?? '?',
      totalBytes: int.parse(cols[1]) * 1024,
      usedBytes: int.parse(cols[2]) * 1024,
      freeBytes: int.parse(cols[3]) * 1024,
    );
  }

  /// Package names of the apps the user installed ("com.flipkart.android"),
  /// used to name the apps screenshots come from.
  Future<List<String>> installedApps(String serial) async {
    final out = await shell(serial, 'pm list packages -3');
    return [
      for (final l in LineSplitter.split(out))
        if (l.trim().startsWith('package:')) l.trim().substring('package:'.length),
    ];
  }

  /// Everything the phone's media index knows: photos, videos, audio,
  /// documents, downloads… Takes a few seconds even for 15k+ files.
  Future<List<PhoneFile>> listFiles(String serial) async => parseMediaRows(await _mediaQuery(serial));

  Future<String> _mediaQuery(String serial) =>
      shell(serial, 'content query --uri content://media/external/file --projection ${mediaColumns.join(':')}');

  /// Every file on shared storage, including those Android's media list
  /// hides (WhatsApp "Sent" copies, private folders…). About 15–20 s for
  /// 60k files.
  ///
  /// A file the media list prints but whose row can't be trusted is left
  /// out, never offered as hidden (see [mergeListings]).
  Future<List<PhoneFile>> listAllFiles(String serial) async {
    final out = await _mediaQuery(serial);
    final found = await shell(serial, "find ${shellQuote(storageRoot)} -type f -printf '$findFormat'");
    return mergeListings(parseMediaRows(out), parseFindRows(found), printed: MediaListedPaths(out));
  }

  /// Content fingerprints (MD5) computed on the phone, so exact duplicates
  /// are found without copying anything. Returns path → hash; files that
  /// couldn't be read are left out.
  ///
  /// Paths with a newline, carriage return or backslash are never
  /// fingerprinted: md5sum prints one line per file, so such a name could
  /// print a line that looks like another file's hash.
  Future<Map<String, String>> fingerprints(String serial, List<String> paths,
      {void Function(int done)? onProgress}) async {
    final result = <String, String>{};
    var batch = <String>[];
    var length = 0, done = 0, reported = 0;

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final command = 'md5sum ${batch.map(shellQuote).join(' ')}';
      ensureReadOnly(command);
      // md5sum exits non-zero if any one file was unreadable; keep the rest.
      final r = await Process.run(adbPath, ['-s', serial, 'shell', command], stdoutEncoding: utf8, stderrEncoding: utf8);
      final out = r.stdout as String;
      if (r.exitCode != 0 && out.isEmpty) throw _failure(r.stderr as String, r.exitCode);
      result.addAll(parseMd5Output(out, batch));
      done += batch.length;
      onProgress?.call(reported = done);
      batch = [];
      length = 0;
    }

    for (final p in paths) {
      if (!canFingerprint(p)) {
        done++; // left out, but counted as checked
        continue;
      }
      batch.add(p);
      length += p.length + 3;
      if (batch.length >= 40 || length > 6000) await flush();
    }
    await flush();
    if (done != reported) onProgress?.call(done); // paths left out at the end
    return result;
  }

  /// Whether [path] is safe to fingerprint: no newline, carriage return or
  /// backslash, any of which could make md5sum's output name another file.
  static bool canFingerprint(String path) =>
      !path.contains('\n') && !path.contains('\r') && !path.contains(r'\');

  /// Reads `md5sum` output for one batch. A line counts only if it names a
  /// path from [requested] (and safe to fingerprint), and only if that path
  /// appears exactly once; anything else could be forged, so it is dropped.
  static Map<String, String> parseMd5Output(String output, Iterable<String> requested) {
    final asked = {for (final p in requested) if (canFingerprint(p)) p};
    final hashes = <String, String>{};
    final seen = <String, int>{};
    for (final line in LineSplitter.split(output)) {
      final m = RegExp(r'^([0-9a-f]{32})  (.+)$').firstMatch(line);
      if (m == null) continue;
      final path = m.group(2)!;
      if (!asked.contains(path)) continue;
      seen.update(path, (n) => n + 1, ifAbsent: () => 1);
      hashes[path] = m.group(1)!;
    }
    return {for (final e in hashes.entries) if (seen[e.key] == 1) e.key: e.value};
  }

  /// Copies many phone files to the laptop in batches — much faster than one
  /// at a time, since each request to the phone costs ~65 ms on its own.
  ///
  /// `adb pull` only reads from the phone. Each batch lands in a temporary
  /// folder on the laptop; a file is moved to [localPathFor] only after its
  /// size is checked, so an interrupted copy never leaves half a file in
  /// place. Files a batch couldn't fetch (e.g. names Windows doesn't allow)
  /// are retried one by one, then reported in [CopyReport.failed].
  ///
  /// [parallel] pulls run side by side: one `adb pull` waits on the phone
  /// between files, so two or three at once keep the cable busier.
  ///
  /// When [stop] says so, no new batch or file is started; what was copied
  /// so far is in the report.
  Future<CopyReport> copyManyToLaptop(String serial, List<PhoneFile> files, String Function(PhoneFile) localPathFor,
      {void Function(int filesDone, int bytesDone)? onProgress,
      int maxBatch = 60,
      int parallel = 1,
      bool Function()? stop}) async {
    bool stopping() => stop?.call() ?? false;
    final report = CopyReport();
    final staging = await Directory.systemTemp.createTemp('declutter_copy_');
    var filesDone = 0;

    Future<void> pullBatch(int i, List<PhoneFile> batch) async {
      final dir = await Directory('${staging.path}${Platform.pathSeparator}$i').create();
      final r = await Process.run(adbPath, ['-s', serial, 'pull', ...batch.map((f) => f.path), dir.path],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      final missing = <PhoneFile>[];
      for (final f in batch) {
        final tmp = File(inside(dir.path, [f.name]));
        if (await tmp.exists() && await tmp.length() == f.bytes) {
          try {
            await _moveInto(tmp, localPathFor(f));
            await keepPhoneDate(File(localPathFor(f)), f);
            report._ok(f);
          } on FileSystemException catch (e) {
            report.failed[f] = '$e'; // e.g. a file already there: never replaced
          }
        } else {
          missing.add(f);
        }
      }
      if (missing.length == batch.length && r.exitCode != 0) {
        final e = _failure(r.stderr as String, r.exitCode);
        if (e is PhoneDisconnected) throw e;
      }
      for (final f in missing) {
        try {
          await copyToLaptop(serial, f, localPathFor(f));
          report._ok(f);
        } on PhoneDisconnected {
          rethrow;
        } catch (e) {
          report.failed[f] = '$e';
        }
      }
      await dir.delete(recursive: true);
      filesDone += batch.length;
      onProgress?.call(filesDone, report.bytes);
    }

    try {
      // `adb pull` names the laptop file after the phone file, so a name like
      // `a\..\..\x.cmd` would land outside the staging folder. Such names
      // are never pulled in a batch; they are copied one by one to a path
      // we build ourselves.
      final oneByOne = [for (final f in files) if (!isSafeName(f.name)) f];
      final batches = _batches([for (final f in files) if (isSafeName(f.name)) f], maxBatch);
      var next = 0;
      Future<void> puller() async {
        while (next < batches.length && !stopping()) {
          final i = next++;
          await pullBatch(i, batches[i]);
        }
      }

      await Future.wait([for (var k = 0; k < parallel.clamp(1, 8); k++) puller()]);
      for (final f in oneByOne) {
        if (stopping()) break;
        try {
          await copyToLaptop(serial, f, localPathFor(f));
          report._ok(f);
        } on PhoneDisconnected {
          rethrow;
        } catch (e) {
          report.failed[f] = '$e';
        }
        onProgress?.call(++filesDone, report.bytes);
      }
    } finally {
      await staging.delete(recursive: true).catchError((_) => staging);
    }
    return report;
  }

  /// Splits into batches with unique file names (they all land in one
  /// folder) and a command line well under Windows' 32k-character limit.
  static List<List<PhoneFile>> _batches(List<PhoneFile> files, int maxBatch) {
    final batches = <List<PhoneFile>>[];
    var current = <PhoneFile>[], names = <String>{}, length = 0;
    for (final f in files) {
      if (current.length >= maxBatch || length + f.path.length > 20000 || names.contains(f.name.toLowerCase())) {
        batches.add(current);
        current = [];
        names = {};
        length = 0;
      }
      current.add(f);
      names.add(f.name.toLowerCase());
      length += f.path.length + 3;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// Moves [from] to [to], never replacing a file already there.
  static Future<void> _moveInto(File from, String to) async {
    await File(to).parent.create(recursive: true);
    ensureFree(to);
    try {
      await from.rename(to);
    } on FileSystemException {
      ensureFree(to); // the rename may have failed because something is there
      await from.copy(to); // different drive: copy, then remove the temp file
      await from.delete();
    }
  }

  /// Throws unless nothing is at [path] on the laptop. Checked right before
  /// each rename, because a rename replaces what's there, and Windows also
  /// answers to short names ("IMG_20~1.JPG"): a name that looks new may be
  /// another backup's short name. [File.existsSync] sees both.
  static void ensureFree(String path) {
    if (File(path).existsSync() || Directory(path).existsSync()) {
      throw FileSystemException('Not copied: a file is already at this place on the laptop', path);
    }
  }

  /// Copies one phone file to [localPath] on the laptop.
  ///
  /// Writes to "<localPath>.part" first and renames only when every byte has
  /// arrived and the size matches, so an interrupted copy never leaves a
  /// half file — and the phone is only ever read from.
  ///
  /// Never replaces anything on the laptop: if a file is already at
  /// [localPath] (or one of its short names), it throws instead.
  Future<void> copyToLaptop(String serial, PhoneFile file, String localPath,
      {void Function(int bytesSoFar)? onProgress}) async {
    final command = 'cat ${shellQuote(file.path)}';
    ensureReadOnly(command);

    ensureFree(localPath);
    final part = await _newPartFile(localPath);
    final sink = part.openWrite();
    var received = 0;
    try {
      final process = await Process.start(adbPath, ['-s', serial, 'exec-out', command]);
      final errors = process.stderr.transform(utf8.decoder).join();
      await for (final chunk in process.stdout) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
      }
      final code = await process.exitCode;
      await sink.close();
      if (code != 0) throw _failure(await errors, code);
      if (file.bytes > 0 && received != file.bytes) {
        // A pulled cable, or only this file changed or went away meanwhile
        // (deleted on the phone mid-check). Asking the phone tells them
        // apart: if it doesn't answer, this throws PhoneDisconnected; if it
        // does, only this one file failed and the rest carry on.
        await shell(serial, 'stat -c %s ${shellQuote(file.path)}').catchError((Object e) {
          if (e is PhoneDisconnected) throw e;
          return '';
        });
        throw ProcessException(adbPath, const [], '${file.name} changed or was removed while it was being copied', 1);
      }
      ensureFree(localPath);
      await keepPhoneDate(await part.rename(localPath), file);
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  /// Gives a laptop copy the phone file's date, so a copy pushed back (Undo)
  /// lands with its old date and sits where it was in the gallery, instead
  /// of jumping to the top as "new".
  static Future<void> keepPhoneDate(File local, PhoneFile f) async {
    if (f.modifiedSec <= 0) return;
    try {
      await local.setLastModified(DateTime.fromMillisecondsSinceEpoch(f.modifiedSec * 1000));
    } on FileSystemException {
      // The copy itself is fine; only its date is today's.
    }
  }

  /// Creates an empty "<localPath>.part" for a copy in progress, only if no
  /// file has that name; otherwise "<localPath>.2.part", and so on. Created
  /// exclusively, so it never truncates a file that is already there.
  static Future<File> _newPartFile(String localPath) async {
    await File(localPath).parent.create(recursive: true);
    for (var n = 1;; n++) {
      final part = File(n == 1 ? '$localPath.part' : '$localPath.$n.part');
      try {
        return await part.create(exclusive: true);
      } on FileSystemException {
        if (n >= 20) rethrow;
      }
    }
  }

  /// Runs a read-only shell command on the phone and returns its output.
  /// [trusted] skips the operator check for fixed, internal command strings
  /// (still limited to the read-only verbs).
  Future<String> shell(String serial, String command, {bool trusted = false}) async {
    if (trusted) {
      for (final part in command.split(';')) {
        ensureReadOnly(part.trim());
      }
    } else {
      ensureReadOnly(command);
    }
    return _run(['-s', serial, 'shell', command]);
  }

  Future<String> _run(List<String> args) async {
    final r = await Process.run(adbPath, args, stdoutEncoding: utf8, stderrEncoding: utf8);
    if (r.exitCode != 0) throw _failure(r.stderr as String, r.exitCode);
    return r.stdout as String;
  }

  Exception _failure(String stderr, int code) {
    final msg = stderr.trim();
    // Only adb's own words for a missing phone. A plain "not found" can be
    // about one file, and must not stop everything as a lost phone.
    if (RegExp(r"no devices|device offline|device '[^']*' not found|device not found|error: closed")
        .hasMatch(msg.toLowerCase())) {
      return PhoneDisconnected(msg);
    }
    return ProcessException(adbPath, const [], msg, code);
  }

  static PhoneDevice _parseDevice(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    final model = RegExp(r'model:(\S+)').firstMatch(line)?.group(1);
    return PhoneDevice(parts[0], parts.elementAtOrNull(1) ?? 'unknown', model: model);
  }
}
