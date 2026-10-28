import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

/// Reading md5sum output, with no phone needed.
void main() {
  const a = '/storage/emulated/0/DCIM/a.jpg', b = '/storage/emulated/0/DCIM/b.jpg';
  final hashA = 'a' * 32, hashB = 'b' * 32, forged = 'f' * 32;

  test('reads one hash per requested path', () {
    expect(Adb.parseMd5Output('$hashA  $a\n$hashB  $b\n', [a, b]), {a: hashA, b: hashB});
  });

  test('a path that was not asked for is ignored', () {
    const other = '/storage/emulated/0/DCIM/real.jpg';
    expect(Adb.parseMd5Output('$hashA  $a\n$forged  $other\n', [a]), {a: hashA});
  });

  test('a path printed twice is dropped rather than trusted', () {
    expect(Adb.parseMd5Output('$hashA  $a\n$forged  $a\n$hashB  $b\n', [a, b]), {b: hashB});
  });

  test('a name with a newline can not forge a hash for another file', () {
    // md5sum prints the crafted name as two lines; the second looks like a
    // hash for b.jpg.
    final crafted = '/storage/emulated/0/Download/x\n$forged  $b';
    final out = '$hashA  $crafted\n$hashB  $b\n';
    expect(Adb.parseMd5Output(out, [crafted, b]), isEmpty, reason: 'b.jpg appears twice, so neither is trusted');
    expect(Adb.parseMd5Output(out, [crafted]), isEmpty);
  });

  test('names with a line break or backslash are never fingerprinted', () {
    expect(Adb.canFingerprint(a), isTrue);
    expect(Adb.canFingerprint('/storage/emulated/0/x\ny.jpg'), isFalse);
    expect(Adb.canFingerprint('/storage/emulated/0/x\ry.jpg'), isFalse);
    expect(Adb.canFingerprint(r'/storage/emulated/0/x\y.jpg'), isFalse);
    expect(Adb.parseMd5Output('$hashA  /storage/emulated/0/x\\y.jpg\n', [r'/storage/emulated/0/x\y.jpg']), isEmpty);
  });

  test('noise lines are skipped', () {
    expect(Adb.parseMd5Output('md5sum: /x: Permission denied\n$hashA  $a\n', [a, '/x']), {a: hashA});
  });
}
