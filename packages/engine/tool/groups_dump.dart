// Scratch: how screenshots would be grouped. groups_dump.dart <texts.json> [packages.txt]
import 'dart:convert';
import 'dart:io';

import 'package:declutter_engine/declutter_engine.dart';

void main(List<String> args) {
  final rows = (jsonDecode(File(args[0]).readAsStringSync().replaceFirst('﻿', '')) as List).cast<Map<String, dynamic>>();
  final packages = args.length > 1
      ? File(args[1]).readAsLinesSync().map((l) => l.replaceFirst('package:', '').trim()).where((l) => l.isNotEmpty)
      : const <String>[];
  final shots = <String, (Verdict, String)>{};
  for (final r in rows) {
    final f = ImageFacts(path: r['path'] as String, folder: r['folder'] as String, bytes: r['bytes'] as int,
        modifiedSec: 0, width: r['width'] as int?, height: r['height'] as int?);
    final text = (r['text'] as String?) ?? '';
    if (!looksLikeScreenshot(f, text)) continue;
    shots[f.path] = (classifyScreenshotText(text), text);
  }
  final grouped = groupScreenshots(shots, installedPackages: packages);
  final counts = <String, int>{};
  for (final v in grouped.values) {
    counts.update('${v.category.name} / ${v.label}', (n) => n + 1, ifAbsent: () => 1);
  }
  print('apps from packages: ${appNamesFromPackages(packages).take(60).join(', ')}\n');
  for (final e in counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
    print('${e.value.toString().padLeft(5)}  ${e.key}');
  }
}
