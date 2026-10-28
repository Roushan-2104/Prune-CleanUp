import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:declutter/main.dart' show clearStaleTempCopies;
import 'package:declutter/media_view.dart';
import 'package:declutter/previews.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_link/phone_link.dart';

/// A made-up grey PNG of [width] x [height] pixels, one bit per pixel, all
/// black. Compresses to almost nothing, however big it claims to be.
Uint8List grayPng(int width, int height) {
  final rowBytes = 1 + (width + 7) ~/ 8;
  final raw = Uint8List(rowBytes * height); // filter 0, all zero
  final out = BytesBuilder();
  void chunk(String type, List<int> data) {
    final typed = [...type.codeUnits, ...data];
    out.add(_u32(data.length));
    out.add(typed);
    out.add(_u32(_crc32(typed)));
  }

  out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  chunk('IHDR', [..._u32(width), ..._u32(height), 1, 0, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder(level: 9).convert(raw));
  chunk('IEND', []);
  return out.toBytes();
}

List<int> _u32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// Resolves [provider] and returns its image's size, or throws its error.
Future<Size> load(ImageProvider provider) {
  final done = Completer<Size>();
  provider.resolve(ImageConfiguration.empty).addListener(
    ImageStreamListener(
      (info, _) {
        if (!done.isCompleted) done.complete(Size(info.image.width.toDouble(), info.image.height.toDouble()));
      },
      onError: (e, _) {
        if (!done.isCompleted) done.completeError(e);
      },
    ),
  );
  return done.future;
}

/// Writes a tiny file instead of copying from a phone.
class _FakeAdb extends Adb {
  _FakeAdb() : super('adb-not-used');

  @override
  Future<void> copyToLaptop(String serial, PhoneFile file, String localPath,
      {void Function(int bytesSoFar)? onProgress}) async {
    await File(localPath).parent.create(recursive: true);
    await File(localPath).writeAsString('test');
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('prune_test_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Open in its usual app', () {
    test('opens only documents on the allow list', () {
      for (final name in ['a.pdf', 'b.DOCX', 'c.xls', 'd.pptx', 'e.odt', 'f.txt', 'g.csv', 'h.rtf', 'i.vcf', 'j.zip']) {
        expect(opensInUsualApp('C:\\p\\$name'), isTrue, reason: name);
      }
      for (final name in [
        'x.py', 'x.pyw', 'x.jnlp', 'x.msc', 'x.diagcab', 'x.theme', 'x.library-ms', 'x.searchConnector-ms',
        'x.appref-ms', 'x.rdp', 'x.xll', 'x.mht', 'x.wsc', 'x.settingcontent-ms', 'x.scf', 'x.html', 'x.htm',
        'x.svg', 'x.eml', 'x.xml', 'x.exe', 'x.lnk', 'x.docm', 'x.apk', 'noext', 'x.pdf.exe',
      ]) {
        expect(opensInUsualApp('C:\\p\\$name'), isFalse, reason: name);
      }
    });

    test('trailing dots and spaces do not hide the real type', () {
      expect(opensInUsualApp('C:\\p\\x.pdf.exe. . '), isFalse);
      expect(isShortcutLike('C:\\p\\x.lnk.'), isTrue);
      expect(isRunnable('C:\\p\\x.pyw '), isTrue);
    });

    test('shortcut-like files are not even shown in a folder', () {
      for (final name in ['a.lnk', 'b.URL', 'c.library-ms', 'd.searchConnector-ms', 'e.scf']) {
        expect(isShortcutLike('C:\\p\\$name'), isTrue, reason: name);
      }
      for (final name in ['a.pdf', 'b.exe', 'c.py']) {
        expect(isShortcutLike('C:\\p\\$name'), isFalse, reason: name);
      }
    });

    test('scripts that run without warning count as runnable', () {
      for (final name in ['a.py', 'a.pyw', 'a.jnlp', 'a.msc', 'a.appref-ms', 'a.html', 'a.svg', 'a.eml']) {
        expect(isRunnable('C:\\p\\$name'), isTrue, reason: name);
      }
    });

    test('a file shown in its folder is copied there alone, marked', () {
      final copy = File('${dir.path}\\1a2b_tool.exe')..writeAsStringSync('x');
      File('${dir.path}\\other.lnk').writeAsStringSync('y');
      final alone = PreviewCache.aloneInFolder(copy);
      expect(alone.parent.path, isNot(dir.path));
      expect(alone.parent.parent.path, dir.path);
      expect(alone.path.endsWith('1a2b_tool.exe'), isTrue);
      expect(alone.parent.listSync().map((e) => e.path), [alone.path]);
      expect(File('${alone.path}:Zone.Identifier').readAsStringSync(), contains('ZoneId=3'));
      // A second request gets another fresh folder.
      expect(PreviewCache.aloneInFolder(copy).parent.path, isNot(alone.parent.path));
    });
  });

  group('preview copies', () {
    const serial = 'unit-test-previews';
    tearDown(() {
      final d = Directory('${PreviewCache.root.path}\\$serial');
      if (d.existsSync()) d.deleteSync(recursive: true);
    });

    test('are marked as downloaded from the internet as soon as they exist', () async {
      final cache = PreviewCache(_FakeAdb(), serial);
      const f = PhoneFile(path: '/sdcard/Download/notes.txt', folder: 'Download/', bytes: 4, mime: 'text/plain', modifiedSec: 0);
      final local = await cache.get(f);
      expect(local, isNotNull);
      expect(File('${local!.path}:Zone.Identifier').readAsStringSync(), contains('ZoneId=3'));
    });
  });

  group('image size limits', () {
    test('normal photos pass, oversized claims do not', () {
      expect(tooBigToShow(4000, 3000), isFalse);
      expect(tooBigToShow(8160, 6120), isFalse); // 50 MP sensor
      expect(tooBigToShow(16000, 16000), isTrue);
      expect(tooBigToShow(1080, 15000), isFalse); // long scrolling screenshot
      expect(tooBigToShow(1080, 40000), isFalse); // 43 MP, still under the cap
      expect(tooBigToShow(70000, 10), isTrue);
      expect(tooBigToShow(10, 70000), isTrue);
      expect(tooBigToShow(9000, 9000), isTrue); // 81 MP
      // JPEGs decode straight to a smaller size: real 200 MP photos stay viewable.
      expect(tooBigToShow(16320, 12240, jpeg: true), isFalse);
      expect(tooBigToShow(30000, 30000, jpeg: true), isTrue);
      expect(tooBigToShow(65000, 1000, jpeg: true), isTrue);
    });

    test('decode sizes never exceed the photo', () {
      expect(SafeFileImage.targetSize(4000, 3000, width: 112).width, 112);
      expect(SafeFileImage.targetSize(80, 60, width: 112).width, isNull);
      final big = SafeFileImage.targetSize(8000, 4000, maxSide: 4096);
      expect((big.width, big.height), (4096, 2048));
      final small = SafeFileImage.targetSize(1000, 800, maxSide: 4096);
      expect((small.width, small.height), (null, null));
    });

    testWidgets('an image bomb is refused before decoding; a normal one shows', (tester) async {
      await tester.runAsync(() async {
        final bomb = File('${dir.path}\\bomb.png')..writeAsBytesSync(grayPng(16000, 16000));
        expect(bomb.lengthSync(), lessThan(200 * 1024));
        await expectLater(load(SafeFileImage(bomb, width: 112)), throwsA(isA<ImageTooLarge>()));
        await expectLater(load(SafeFileImage(bomb, maxSide: 4096)), throwsA(isA<ImageTooLarge>()));

        final ok = File('${dir.path}\\ok.png')..writeAsBytesSync(grayPng(400, 200));
        expect(await load(SafeFileImage(ok, width: 100)), const Size(100, 50));
        expect(await load(SafeFileImage(ok, maxSide: 4096)), const Size(400, 200));
      });
    });
  });

  test('start-up removes only leftover private copy folders from temp', () {
    for (final name in ['declutter_copy_ab', 'declutter_vision_cd', 'prune_vision_ef', 'keep_me', 'prune_other']) {
      Directory('${dir.path}\\$name\\inner').createSync(recursive: true);
    }
    File('${dir.path}\\declutter_copy_file.txt').writeAsStringSync('a file, not a folder');
    clearStaleTempCopies(dir);
    final left = dir.listSync().map((e) => e.path.split('\\').last).toSet();
    expect(left, {'keep_me', 'prune_other', 'declutter_copy_file.txt'});
  });
}
