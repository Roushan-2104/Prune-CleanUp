import 'dart:io';

import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

void main() {
  final root = '${Directory.systemTemp.path}\\declutter-root';

  group('a phone name is one safe Windows name', () {
    test('folder separators and parent references can not escape', () {
      expect(safeSegment(r'a\..\..\Startup\x.cmd'), r'a_.._.._Startup_x.cmd');
      expect(safeSegment('..'), '_');
      expect(safeSegment('.'), '_');
    });
    test('alternate data streams, reserved names, trailing dots', () {
      expect(safeSegment('photo.jpg:evil'), 'photo.jpg_evil');
      expect(safeSegment('CON'), '_CON');
      expect(safeSegment('nul.txt'), '_nul.txt');
      expect(safeSegment('x.jpg.'), 'x.jpg');
      expect(safeSegment('x.jpg . '), 'x.jpg');
    });
    test('invisible direction marks that disguise extensions', () {
      expect(safeSegment('invoice\u202Efdp.exe'), 'invoice_fdp.exe');
    });
    test('ordinary names are left alone', () {
      expect(isSafeName('IMG-20260717-WA0027.jpg'), isTrue);
      expect(isSafeName('Résumé 2026 (final).pdf'), isTrue);
      expect(isSafeName(r'a\b.jpg'), isFalse);
    });
  });

  test('inside() never leaves its folder', () {
    final p = inside(root, ['phone', r'..\..\..\Windows', 'x.cmd']);
    expect(isWithin(root, p), isTrue);
    expect(p, '$root\\phone\\.._.._.._Windows\\x.cmd');
  });

  test('isWithin catches traversal and look-alike siblings', () {
    expect(isWithin(root, '$root\\a\\b.jpg'), isTrue);
    expect(isWithin(root, '$root\\..\\escaped.jpg'), isFalse);
    expect(isWithin(root, '$root-other\\b.jpg'), isFalse);
  });
}
