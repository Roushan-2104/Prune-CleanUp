// Scratch: first lines of chat screenshots, to see where names sit.
import 'dart:convert';
import 'dart:io';

import 'package:declutter_engine/declutter_engine.dart';

void main(List<String> args) {
  final rows = (jsonDecode(File(args[0]).readAsStringSync().replaceFirst('﻿', '')) as List).cast<Map<String, dynamic>>()
    ..shuffle();
  var n = 0;
  for (final r in rows) {
    final text = (r['text'] as String?) ?? '';
    final v = classifyScreenshotText(text);
    if (v.category != JunkCategory.chatScreenshot || (args.length > 1 && v.label != args[1])) continue;
    print('${v.label}: ${text.split('\n').take(6).join(' | ')}');
    if (++n >= 40) break;
  }
}
