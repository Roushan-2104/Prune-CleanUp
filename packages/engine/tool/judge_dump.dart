// Scratch: re-judge exported texts and sample each category.
// dart run tool/judge_dump.dart <texts.json> [category prefix] [n]
import 'dart:convert';
import 'dart:io';

import 'package:declutter_engine/declutter_engine.dart';

void main(List<String> args) {
  final raw = File(args[0]).readAsStringSync().replaceFirst('﻿', '');
  final rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  final byCat = <String, List<(Map<String, dynamic>, Verdict?)>>{};
  for (final r in rows) {
    final f = ImageFacts(path: r['path'] as String, folder: r['folder'] as String, bytes: r['bytes'] as int,
        modifiedSec: 0, width: r['width'] as int?, height: r['height'] as int?);
    final text = (r['text'] as String?) ?? '';
    if (!looksLikeScreenshot(f, text)) {
      (byCat['(not a screenshot)'] ??= []).add((r, null));
      continue;
    }
    final v = classifyScreenshotText(text);
    final key = '${v.category.name}${v.label == null ? '' : ' / ${v.label}'} ${v.tier.name}';
    (byCat[key] ??= []).add((r, v));
  }
  for (final e in (byCat.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length)))) {
    print('${e.value.length.toString().padLeft(5)}  ${e.key}');
  }
  if (args.length < 2) return;
  final n = args.length > 2 ? int.parse(args[2]) : 15;
  final pick = byCat.entries.where((e) => e.key.startsWith(args[1])).expand((e) => e.value).toList()..shuffle();
  for (final (r, v) in pick.take(n)) {
    final t = ((r['text'] as String?) ?? '').replaceAll('\n', ' | ');
    print('\n--- ${(r['path'] as String).split('/').last} ${r['width']}x${r['height']} '
        '${v?.confidence} ${v?.label} ${v?.reasons} ${v?.evidence}\n${t.length > 200 ? t.substring(0, 200) : t}');
  }
}
