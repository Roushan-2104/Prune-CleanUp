import 'dart:io';

import 'package:declutter/media_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('programs, scripts, shortcuts and macro documents are never opened', () {
    for (final name in ['Invoice.exe', 'bill.PDF.scr', 'run.bat', 'x.js', 'Shortcut.lnk', 'Invoice.docm', 'setup.msi']) {
      expect(isRunnable('C:\\p\\$name'), isTrue, reason: name);
    }
    for (final name in ['photo.jpg', 'notes.pdf', 'song.mp3', 'report.docx', 'app.apk', 'noext']) {
      expect(isRunnable('C:\\p\\$name'), isFalse, reason: name);
    }
  });

  test('hidden direction marks are shown, not obeyed', () {
    expect(displayName('invoice\u202Efdp.exe'), 'invoice\uFFFDfdp.exe');
    expect(displayName('IMG-1.jpg'), 'IMG-1.jpg');
  });

  test('copies are marked as downloaded from the internet', () {
    final dir = Directory.systemTemp.createTempSync('declutter_zone_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}\\report.docx')..writeAsStringSync('x');
    markFromInternet(f.path);
    expect(File('${f.path}:Zone.Identifier').readAsStringSync(), contains('ZoneId=3'));
  });
}
