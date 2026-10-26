import 'package:declutter/cleaning.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_link/phone_link.dart';

PhoneFile file(String folder, String name) =>
    PhoneFile(path: '/storage/emulated/0/$folder$name', folder: folder, bytes: 1, mime: 'image/jpeg', modifiedSec: 0);

void main() {
  final at = DateTime(2026, 10, 26, 9, 5, 7);

  test('a crafted phone name can not put a backup outside the backup folder', () {
    final f = file('Download/', r'a\..\..\..\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\x.cmd');
    final p = backupPathsFor('Pixel', [f], at: at)[f.path]!;
    expect(isWithin(backupRoot, p), isTrue);
    expect(p, contains(r'\Pixel\2026-10-26 09.05.07\Download\'));
    expect(p.toLowerCase(), isNot(contains(r'\startup\')));
  });

  test('a phone name with ":" in it (a Wi-Fi serial) stays one folder', () {
    final f = file('DCIM/', 'a.jpg');
    final p = backupPathsFor('Pixel-192.168.1.5:5555', [f], at: at)[f.path]!;
    expect(p, contains(r'\Pixel-192.168.1.5_5555\'));
  });

  test('names Windows treats as the same never share one backup', () {
    final files = [file('DCIM/', 'IMG.jpg'), file('DCIM/', 'img.jpg'), file('DCIM/', 'x.jpg'), file('DCIM/', 'x.jpg.')];
    final paths = backupPathsFor('Pixel', files, at: at);
    expect(paths.values.map((p) => p.toLowerCase()).toSet(), hasLength(4));
    expect(paths[files[1].path], endsWith(r'\DCIM\img (2).jpg'));
    expect(paths[files[3].path], endsWith(r'\DCIM\x (2).jpg'));
  });
}
