import 'dart:io';

import 'package:declutter_engine/declutter_engine.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:phone_link/phone_link.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const _shot = '/storage/emulated/0/Pictures/Screenshots/s.png';
const _secret = 'Paid to Vikram ₹500 UPI Ref 1234';

PhoneFile _file() => const PhoneFile(id: '1', path: _shot, folder: 'Pictures/Screenshots/', bytes: 10,
    mime: 'image/png', modifiedSec: 5);
Analysis _analysis() => const Analysis(modified: 5, bytes: 10, takenAtMs: 0, screenshot: true, text: _secret);

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('declutter_privacy_');
    path = '${dir.path}\\test.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  bool fileContains(String s) {
    final bytes = File(path).readAsBytesSync();
    final wal = File('$path-wal');
    final all = [...bytes, if (wal.existsSync()) ...wal.readAsBytesSync()];
    return String.fromCharCodes(all).contains(s);
  }

  test('screenshot text is encrypted in the file but reads back normally', () {
    final store = Store.open(path);
    store.syncInventory('P1', [_file()]);
    store.saveMeasurements('P1', {_shot: _analysis()});
    expect(store.measurements('P1')[_shot]!.text, _secret);
    store.close();
    expect(fileContains('Vikram'), isFalse);
  });

  test('text saved before encryption is encrypted when the app updates', () {
    // An old (version 3) database with plain text in it.
    final old = sqlite3.open(path);
    old.execute('''
      CREATE TABLE files (phone TEXT NOT NULL, path TEXT NOT NULL, media_id TEXT, folder TEXT NOT NULL,
        bytes INTEGER NOT NULL, mime TEXT NOT NULL, modified_sec INTEGER NOT NULL, taken_ms INTEGER, width INTEGER,
        height INTEGER, duration_ms INTEGER, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
        PRIMARY KEY (phone, path)) WITHOUT ROWID;
      CREATE TABLE measurements (phone TEXT NOT NULL, path TEXT NOT NULL, modified_sec INTEGER NOT NULL,
        bytes INTEGER NOT NULL, taken_ms INTEGER NOT NULL, screenshot INTEGER NOT NULL, text TEXT, dhash INTEGER,
        sharpness REAL, entropy REAL, faces INTEGER, measured_at INTEGER NOT NULL, landscape INTEGER,
        PRIMARY KEY (phone, path)) WITHOUT ROWID;
      PRAGMA user_version = 3;
    ''');
    old.execute("INSERT INTO files VALUES ('P1', '$_shot', '1', 'Pictures/Screenshots/', 10, 'image/png', 5, NULL, NULL, NULL, NULL, 1, 1)");
    old.execute("INSERT INTO measurements VALUES ('P1', '$_shot', 5, 10, 0, 1, '$_secret', NULL, NULL, NULL, NULL, 1, NULL)");
    old.close();
    expect(fileContains('Vikram'), isTrue);

    final store = Store.open(path);
    expect(store.measurements('P1')[_shot]!.text, _secret);
    store.close();
    expect(fileContains('Vikram'), isFalse, reason: 'no plain copy left in the file or its log');
  });

  test('forgetting a phone removes everything about it', () {
    final store = Store.open(path);
    store.rememberPhone('P1', const PhoneInfo(brand: 'b', model: 'm', androidVersion: '14', totalBytes: 1, usedBytes: 1, freeBytes: 0));
    store.syncInventory('P1', [_file()]);
    store.saveMeasurements('P1', {_shot: _analysis()});
    store.forgetPhone('P1');
    expect(store.fileCount('P1'), 0);
    expect(store.measurements('P1'), isEmpty);
    store.close();
    expect(fileContains('Screenshots/s.png'), isFalse);
  });
}
