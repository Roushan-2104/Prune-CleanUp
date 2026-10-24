@TestOn('windows')
library;

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:vision_helper/vision_helper.dart';

/// Runs the real DeclutterVision.exe (build it first with build.ps1) on
/// images the test draws itself — no personal photos needed.
void main() {
  final exe = '${Directory.current.path}${Platform.pathSeparator}bin${Platform.pathSeparator}DeclutterVision.exe';
  final vision = Vision(exe, parallel: 3, batchSize: 4);
  late Directory dir;

  setUpAll(() async {
    if (!File(exe).existsSync()) fail('Build the helper first: powershell -File build.ps1');
    dir = await Directory.systemTemp.createTemp('declutter_vision_test');
  });
  tearDownAll(() => dir.delete(recursive: true));

  Future<String> drawText(String name, List<String> lines) async {
    final image = img.Image(width: 900, height: 120 + 60 * lines.length);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (final (i, line) in lines.indexed) {
      img.drawString(image, line, font: img.arial48, x: 30, y: 40 + 60 * i, color: img.ColorRgb8(0, 0, 0));
    }
    final path = '${dir.path}${Platform.pathSeparator}$name.png';
    await File(path).writeAsBytes(img.encodePng(image));
    return path;
  }

  test('reports what this PC supports', () async {
    final caps = await vision.capabilities();
    expect(caps.canReadText, isTrue);
    expect(caps.canFindFaces, isTrue);
    expect(caps.textLanguage, isNotEmpty);
  });

  test('reads text and keeps line breaks', () async {
    final path = await drawText('receipt', ['Payment successful', 'Paid to Swiggy', 'UPI Ref 4287']);
    final r = await vision.readText(path);
    expect(r.ok, isTrue, reason: r.error);
    final text = r.text!.toLowerCase();
    expect(text.split('\n'), hasLength(3));
    expect(text, contains('payment successful'));
    expect(text, contains('swiggy'));
  });

  test('blank image has no text and no faces', () async {
    final path = await drawText('blank', []);
    final r = (await vision.analyse([path], text: true, faces: true)).single;
    expect(r.text, isEmpty);
    expect(r.faces, 0);
  });

  test('many images across parallel batches come back in order', () async {
    final paths = [for (var i = 0; i < 14; i++) await drawText('n$i', ['Number $i'])];
    var progress = 0;
    final results = await vision.analyse(paths, onProgress: (d) => progress = d);
    expect(progress, 14);
    for (var i = 0; i < 14; i++) {
      expect(results[i].path, paths[i]);
      expect(results[i].text!.toLowerCase(), contains('number $i'));
    }
  });

  test('a missing file fails alone; the rest of the batch still works', () async {
    final good = await drawText('good', ['Still alive']);
    final results = await vision.analyse(['${dir.path}${Platform.pathSeparator}nope.jpg', good]);
    expect(results[0].ok, isFalse);
    expect(results[1].text!.toLowerCase(), contains('alive'));
  });

  test('file names with spaces and unicode work', () async {
    final path = await drawText('my photo ₹ नमस्ते', ['Hello world']);
    expect((await vision.readText(path)).text!.toLowerCase(), contains('hello'));
  });
}
