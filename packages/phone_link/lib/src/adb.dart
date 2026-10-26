import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'find_list.dart';
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
  Future<List<PhoneFile>> listFiles(String serial) async {
    final out = await shell(serial,
        'content query --uri content://media/external/file --projection ${mediaColumns.join(':')}');
    return parseMediaRows(out);
  }

  /// Every file on shared storage, including those Android's media list
  /// hides (WhatsApp "Sent" copies, private folders…). About 15–20 s for
  /// 60k files.
  Future<List<PhoneFile>> listAllFiles(String serial) async {
    final media = await listFiles(serial);
    final found = await shell(serial, "find ${shellQuote(storageRoot)} -type f -printf '$findFormat'");
    return mergeListings(media, parseFindRows(found));
  }

  /// Content fingerprints (MD5) computed on the phone, so exact duplicates
  /// are found without copying anything. Returns path → hash; files that
  /// couldn't be read are left out.
  Future<Map<String, String>> fingerprints(String serial, List<String> paths,
      {void Function(int done)? onProgress}) async {
    final result = <String, String>{};
    var batch = <String>[];
    var length = 0, done = 0;

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final command = 'md5sum ${batch.map(shellQuote).join(' ')}';
      ensureReadOnly(command);
      // md5sum exits non-zero if any one file was unreadable; keep the rest.
      final r = await Process.run(adbPath, ['-s', serial, 'shell', command], stdoutEncoding: utf8, stderrEncoding: utf8);
      final out = r.stdout as String;
      if (r.exitCode != 0 && out.isEmpty) throw _failure(r.stderr as String, r.exitCode);
      for (final line in LineSplitter.split(out)) {
        final m = RegExp(r'^([0-9a-f]{32})  (.+)$').firstMatch(line);
        if (m != null) result[m.group(2)!] = m.group(1)!;
      }
      done += batch.length;
      onProgress?.call(done);
      batch = [];
      length = 0;
    }

    for (final p in paths) {
      batch.add(p);
      length += p.length + 3;
      if (batch.length >= 40 || length > 6000) await flush();
    }
    await flush();
    return result;
  }

  /// Copies many phone files to the laptop in batches — much faster than one
  /// at a time, since each request to the phone costs ~65 ms on its own.
  ///
  /// `adb pull` only reads from the phone. Each batch lands in a temporary
  /// folder on the laptop; a file is moved to [localPathFor] only after its
  /// size is checked, so an interrupted copy never leaves half a file in
  /// place. Files a batch couldn't fetch (e.g. names Windows doesn't allow)
  /// are retried one by one, then reported in [CopyReport.failed].
  Future<CopyReport> copyManyToLaptop(String serial, List<PhoneFile> files, String Function(PhoneFile) localPathFor,
      {void Function(int filesDone, int bytesDone)? onProgress, int maxBatch = 60}) async {
    final report = CopyReport();
    final staging = await Directory.systemTemp.createTemp('declutter_copy_');
    var filesDone = 0;
    try {
      for (final (i, batch) in _batches(files, maxBatch).indexed) {
        final dir = await Directory('${staging.path}${Platform.pathSeparator}$i').create();
        final r = await Process.run(adbPath, ['-s', serial, 'pull', ...batch.map((f) => f.path), dir.path],
            stdoutEncoding: utf8, stderrEncoding: utf8);
        final missing = <PhoneFile>[];
        for (final f in batch) {
          final tmp = File('${dir.path}${Platform.pathSeparator}${f.name}');
          if (await tmp.exists() && await tmp.length() == f.bytes) {
            await _moveInto(tmp, localPathFor(f));
            report._ok(f);
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

  static Future<void> _moveInto(File from, String to) async {
    await File(to).parent.create(recursive: true);
    try {
      await from.rename(to);
    } on FileSystemException {
      await from.copy(to); // different drive: copy, then remove the temp file
      await from.delete();
    }
  }

  /// Copies one phone file to [localPath] on the laptop.
  ///
  /// Writes to "<localPath>.part" first and renames only when every byte has
  /// arrived and the size matches, so an interrupted copy never leaves a
  /// half file — and the phone is only ever read from.
  Future<void> copyToLaptop(String serial, PhoneFile file, String localPath,
      {void Function(int bytesSoFar)? onProgress}) async {
    final command = 'cat ${shellQuote(file.path)}';
    ensureReadOnly(command);

    final part = File('$localPath.part');
    await part.parent.create(recursive: true);
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
        throw PhoneDisconnected('copy of ${file.name} stopped at $received of ${file.bytes} bytes');
      }
      await part.rename(localPath);
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await part.exists()) await part.delete();
      rethrow;
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
    if (msg.contains('not found') || msg.contains('no devices') || msg.contains('offline')) {
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
