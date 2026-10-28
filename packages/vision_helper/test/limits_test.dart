@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:vision_helper/vision_helper.dart';

/// The helper's safety limits: pictures too big to decode, paths too long
/// for Windows' usual limit, and serve mode cleaning up after itself. Runs
/// the real PruneVision.exe (build it first with build.ps1) on files the
/// test makes itself.
void main() {
  final sep = Platform.pathSeparator;
  final exe = '${Directory.current.path}${sep}bin${sep}PruneVision.exe';
  final vision = Vision(exe, parallel: 2, batchSize: 4);
  late Directory dir;

  setUpAll(() async {
    if (!File(exe).existsSync()) fail('Build the helper first: powershell -File build.ps1');
    dir = await Directory.systemTemp.createTemp('prune_vision_limits_test');
  });
  tearDownAll(() => dir.delete(recursive: true));

  Uint8List drawText(List<String> lines, {bool jpg = false}) {
    final image = img.Image(width: 900, height: 120 + 60 * lines.length);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (final (i, line) in lines.indexed) {
      img.drawString(image, line, font: img.arial48, x: 30, y: 40 + 60 * i, color: img.ColorRgb8(0, 0, 0));
    }
    return jpg ? img.encodeJpg(image, quality: 90) : img.encodePng(image);
  }

  group('pictures too big to check', () {
    test('a small file claiming 16000 x 16000 px is refused before decoding', () async {
      final path = '${dir.path}${sep}huge.png';
      File(path).writeAsBytesSync(_bigPng(16000, 16000, rows: 1));
      for (final job in [
        VisionJob(path, gray: true, text: true, textMaxSide: 2560),
        VisionJob(path, gray: true),
        VisionJob(path, text: true),
        VisionJob(path, faces: true),
      ]) {
        final r = (await vision.analyseEach([job])).single;
        expect(r.ok, isFalse, reason: job.jobs);
        expect(r.error, contains('too big'), reason: job.jobs);
      }
    });

    test('just under the limit, without decoding once: same pixels and text as separate jobs', () async {
      // 66 megapixels: over the size decoded once at full size, under the limit.
      final path = '${dir.path}${sep}large.png';
      File(path).writeAsBytesSync(_bigPng(8200, 8050));
      final r = await vision.analyseEach([
        VisionJob(path, gray: true, text: true, textMaxSide: 2560),
        VisionJob(path, gray: true),
        VisionJob(path, text: true, textMaxSide: 2560),
      ]);
      expect(r[0].ok, isTrue, reason: r[0].error);
      expect((r[0].gray!.width, r[0].gray!.height), (r[1].gray!.width, r[1].gray!.height));
      expect(r[0].gray!.pixels, r[1].gray!.pixels);
      expect(r[0].text, r[2].text);
    });
  });

  group('long paths', () {
    late String folder;

    setUpAll(() {
      var d = dir.path;
      for (var i = 0; i < 6; i++) {
        d = '$d${sep}a_rather_long_folder_name_for_testing_$i';
      }
      Directory(d).createSync(recursive: true);
      folder = d;
      expect(folder.length, greaterThan(260));
    });

    test('photos in a path over 260 characters are read', () async {
      final png = '$folder${sep}screenshot_with_a_long_name.png';
      final jpg = '$folder${sep}photo_with_a_long_name.jpg';
      File(png).writeAsBytesSync(drawText(['Payment successful', 'Order shipped']));
      File(jpg).writeAsBytesSync(drawText(['Hello long path'], jpg: true));
      final r = await vision.analyseEach([
        VisionJob(png, text: true),
        VisionJob(jpg, gray: true, text: true, textMaxSide: 2560),
        VisionJob(jpg, faces: true),
      ]);
      expect(r[0].ok, isTrue, reason: r[0].error);
      expect(r[0].text!.toLowerCase(), contains('payment successful'));
      expect(r[1].ok, isTrue, reason: r[1].error);
      expect(r[1].text!.toLowerCase(), contains('hello'));
      expect(r[1].gray, isNotNull);
      expect(r[2].faces, 0);
    });

    test('the same picture gives the same result in a short and a long path', () async {
      final bytes = drawText(['Same either way'], jpg: true);
      final short = '${dir.path}${sep}short.jpg', long = '$folder${sep}same_picture_in_a_long_path.jpg';
      File(short).writeAsBytesSync(bytes);
      File(long).writeAsBytesSync(bytes);
      final r = await vision.analyseEach([
        VisionJob(short, gray: true, text: true, textMaxSide: 2560),
        VisionJob(long, gray: true, text: true, textMaxSide: 2560),
      ]);
      expect(r[1].ok, isTrue, reason: r[1].error);
      expect(r[1].text, r[0].text);
      expect(r[1].gray!.pixels, r[0].gray!.pixels);
    });

    test('a document in a long path gets its picture', () async {
      final txt = '$folder${sep}notes_with_a_long_name.txt';
      File(txt).writeAsStringSync('Shopping list\nMilk\nBread\n');
      final r = (await vision.analyseEach([VisionJob(txt, thumb: true)])).single;
      expect(r.ok, isTrue, reason: r.error);
      expect(r.thumb, isNotNull);
    });

    test('a missing file in a long path fails alone', () async {
      final good = '$folder${sep}still_here.png';
      File(good).writeAsBytesSync(drawText(['Still alive']));
      final r = await vision.analyseEach([VisionJob('$folder${sep}nope.jpg', text: true), VisionJob(good, text: true)]);
      expect(r[0].ok, isFalse);
      expect(r[1].text!.toLowerCase(), contains('alive'));
    });
  });

  group('serve mode removes its folder', () {
    Future<(Process, Directory)> serve({int? parent}) async {
      final folder = await Directory.systemTemp.createTemp('prune_vision_');
      final p = await Process.start(exe, ['serve', folder.path, if (parent != null) '$parent']);
      p.stdout.drain<void>();
      p.stderr.drain<void>();
      return (p, folder);
    }

    Future<int> exitOf(Process p) =>
        p.exitCode.timeout(const Duration(seconds: 15), onTimeout: () {
          p.kill();
          fail('the helper did not stop');
        });

    test('when asked to stop', () async {
      final (p, folder) = await serve(parent: pid);
      File('${folder.path}${sep}1.tmp').writeAsStringSync('half a list');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      File('${folder.path}${sep}stop').writeAsStringSync('');
      expect(await exitOf(p), 0);
      expect(folder.existsSync(), isFalse);
    });

    test('when the program that started it ends', () async {
      final parent = await Process.start('ping', ['-n', '3', '127.0.0.1']);
      parent.stdout.drain<void>();
      final (p, folder) = await serve(parent: parent.pid);
      await parent.exitCode;
      expect(await exitOf(p), 0);
      expect(folder.existsSync(), isFalse);
    });

    test('but leaves files it did not make', () async {
      final (p, folder) = await serve(parent: pid);
      final other = File('${folder.path}${sep}keep me.jpg')..writeAsStringSync('not the helper\'s');
      File('${folder.path}${sep}stop').writeAsStringSync('');
      expect(await exitOf(p), 0);
      expect(other.existsSync(), isTrue);
      expect(File('${folder.path}${sep}stop').existsSync(), isFalse);
      folder.deleteSync(recursive: true);
    });

    test('closing kept-alive helpers leaves no folder behind', () async {
      bool mine(FileSystemEntity e) => e is Directory && e.path.split(sep).last.startsWith('prune_vision_');
      final before = Directory.systemTemp.listSync().where(mine).map((e) => e.path).toSet();
      final kept = Vision(exe, parallel: 2, batchSize: 1, keepAlive: true);
      final a = '${dir.path}${sep}kept_a.png', b = '${dir.path}${sep}kept_b.png';
      File(a).writeAsBytesSync(drawText(['First']));
      File(b).writeAsBytesSync(drawText(['Second']));
      final r = await kept.analyse([a, b]);
      expect(r.every((x) => x.ok), isTrue);
      await kept.close();
      final after = Directory.systemTemp.listSync().where(mine).map((e) => e.path).toSet();
      expect(after.difference(before), isEmpty);
    });
  });
}

/// A plain grey PNG of the given size, built row by row so the test never
/// holds the whole picture. With [rows], only that many rows of pixel data
/// are written: the header still claims the full size.
Uint8List _bigPng(int width, int height, {int? rows}) {
  final row = Uint8List(1 + width * 3);
  final out = BytesBuilder(copy: false);
  final sink = _Collect();
  final z = ZLibEncoder(level: 1).startChunkedConversion(sink);
  for (var y = 0; y < (rows ?? height); y++) {
    row.fillRange(1, row.length, 64 + (y ~/ 64) % 128); // grey bands
    z.add(row);
  }
  z.close();
  out.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bits per channel
    ..setUint8(9, 2); // RGB
  _chunk(out, 'IHDR', header.buffer.asUint8List());
  _chunk(out, 'IDAT', sink.bytes.takeBytes());
  _chunk(out, 'IEND', const []);
  return out.takeBytes();
}

void _chunk(BytesBuilder out, String type, List<int> data) {
  final typed = [...type.codeUnits, ...data];
  out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
  out.add(typed);
  out.add((ByteData(4)..setUint32(0, _crc(typed))).buffer.asUint8List());
}

class _Collect implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) => bytes.add(data);
  @override
  void close() {}
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
