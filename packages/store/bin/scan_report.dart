// Read-only report: lists everything on the connected phone, fingerprints
// same-size files on the phone, runs the file rules and prints what
// Declutter would suggest. Nothing on the phone is changed.
//
// Usage: dart run bin/scan_report.dart <adb.exe>
import 'dart:io';

import 'package:declutter_engine/declutter_engine.dart';
import 'package:phone_link/phone_link.dart';

Future<void> main(List<String> args) async {
  final adb = Adb(args.first);
  final phone = (await adb.devices()).where((d) => d.ready && !PhoneCleaner.isVirtualPhone(d.serial)).firstOrNull;
  if (phone == null) {
    stderr.writeln('No phone ready.');
    exitCode = 1;
    return;
  }

  var sw = Stopwatch()..start();
  final files = await adb.listAllFiles(phone.serial);
  print('Listed ${files.length} files in ${secs(sw)} '
      '(${files.where((f) => f.hiddenFromMediaList).length} hidden from Android\'s media list)');

  final facts = [
    for (final f in files)
      FileFacts(path: f.path, folder: f.folder, bytes: f.bytes, mime: f.mime, modifiedSec: f.modifiedSec, durationMs: f.durationMs),
  ];
  final candidates = sameSizeCandidates(facts);
  sw = Stopwatch()..start();
  final hashes = await adb.fingerprints(phone.serial, [for (final c in candidates) c.path]);
  print('Fingerprinted ${hashes.length} same-size files on the phone in ${secs(sw)} '
      '(${gb(candidates.fold(0, (s, f) => s + f.bytes))} read on the phone, nothing copied)');

  final verdicts = classifyFiles(facts, now: DateTime.now(), contentHash: hashes);
  final bytesOf = {for (final f in facts) f.path: f.bytes};

  print('\nWhat Declutter would suggest (photos/screenshots need copying first, so not included yet):');
  var sureTotal = 0, maybeTotal = 0;
  for (final c in JunkCategory.values) {
    final items = verdicts.entries.where((e) => e.value.verdict.category == c).toList();
    if (items.isEmpty) continue;
    final sure = items.where((e) => e.value.verdict.tier == Tier.sure);
    final maybe = items.where((e) => e.value.verdict.tier == Tier.maybe);
    final sureB = sure.fold(0, (s, e) => s + bytesOf[e.key]!), maybeB = maybe.fold(0, (s, e) => s + bytesOf[e.key]!);
    sureTotal += sureB;
    maybeTotal += maybeB;
    print('  ${c.label.padRight(24)} ${items.length.toString().padLeft(6)} files · '
        'sure ${gb(sureB).padLeft(8)} · to check ${gb(maybeB).padLeft(8)}');
  }
  print('\n  Pre-selected ("sure"): ${gb(sureTotal)}   ·   Suggested to check: ${gb(maybeTotal)}');

  // Sanity check for duplicates: which folder loses a copy, which one keeps it.
  final folderOf = {for (final f in facts) f.path: f.folder};
  final pairs = <String, (int, int)>{};
  for (final MapEntry(key: path, value: v) in verdicts.entries) {
    if (v.matchPath == null) continue;
    final key = '${short(folderOf[path]!)}  →  kept in ${short(folderOf[v.matchPath]!)}';
    final (n, b) = pairs[key] ?? (0, 0);
    pairs[key] = (n + 1, b + bytesOf[path]!);
  }
  print('\nDuplicate copies by folder (copy → original kept):');
  for (final e in (pairs.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2))).take(10)) {
    print('  ${e.value.$1.toString().padLeft(4)} · ${gb(e.value.$2).padLeft(8)}  ${e.key}');
  }
  print('Nothing on the phone was changed.');
}

String short(String folder) => folder.replaceFirst('Android/media/com.whatsapp/WhatsApp/Media/', 'WA/');
String secs(Stopwatch s) => '${(s.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
String gb(int b) => '${(b / (1 << 30)).toStringAsFixed(2)} GB';
