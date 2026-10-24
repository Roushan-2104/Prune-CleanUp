import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'media_list.dart';
import 'read_only_guard.dart';

/// Thrown when the phone disappears (cable pulled, phone locked USB, etc.).
class PhoneDisconnected implements Exception {
  PhoneDisconnected(this.message);
  final String message;
  @override
  String toString() => 'Phone disconnected: $message';
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

  /// Everything the phone's media index knows: photos, videos, audio,
  /// documents, downloads… Takes a few seconds even for 15k+ files.
  Future<List<PhoneFile>> listFiles(String serial) async {
    final out = await shell(serial,
        'content query --uri content://media/external/file --projection ${mediaColumns.join(':')}');
    return parseMediaRows(out);
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
