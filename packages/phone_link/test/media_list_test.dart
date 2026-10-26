import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

String row(int n, Map<String, String> v) =>
    'Row: $n ${mediaColumns.map((c) => '$c=${v[c] ?? 'NULL'}').join(', ')}';

void main() {
  test('parses a normal photo', () {
    final files = parseMediaRows(row(0, {
      '_id': '42',
      '_data': '/storage/emulated/0/DCIM/Camera/IMG_1.jpg',
      '_display_name': 'IMG_1.jpg',
      'relative_path': 'DCIM/Camera/',
      '_size': '2048',
      'mime_type': 'image/jpeg',
      'date_modified': '1700000000',
      'datetaken': '1700000000123',
      'width': '4000',
      'height': '3000',
    }));
    final f = files.single;
    expect(f.id, '42');
    expect(f.name, 'IMG_1.jpg');
    expect(f.folder, 'DCIM/Camera/');
    expect(f.bytes, 2048);
    expect(f.isImage, isTrue);
    expect(f.takenMs, 1700000000123);
    expect(f.width, 4000);
    expect(f.durationMs, isNull);
  });

  test('file names with ", " and "=" do not break parsing', () {
    final f = parseMediaRows(row(3, {
      '_id': '7',
      '_data': '/storage/emulated/0/Download/Bill, March=paid, final.pdf',
      '_display_name': 'Bill, March=paid, final.pdf',
      'relative_path': 'Download/',
      '_size': '99',
      'mime_type': 'application/pdf',
      'date_modified': '1',
    })).single;
    expect(f.name, 'Bill, March=paid, final.pdf');
    expect(f.folder, 'Download/');
    expect(f.bytes, 99);
  });

  test('videos keep their duration', () {
    final f = parseMediaRows(row(1, {
      '_id': '9',
      '_data': '/storage/emulated/0/Movies/a.mp4',
      '_display_name': 'a.mp4',
      'relative_path': 'Movies/',
      '_size': '10',
      'mime_type': 'video/mp4',
      'date_modified': '1',
      'duration': '2500',
    })).single;
    expect(f.isVideo, isTrue);
    expect(f.durationMs, 2500);
  });

  test('folders (no mime type) and noise lines are skipped', () {
    final out = [
      row(0, {'_id': '1', '_data': '/storage/emulated/0/DCIM', 'relative_path': '', '_size': '0', 'date_modified': '1'}),
      'Some warning line',
      '',
      row(1, {'_id': '2', '_data': '/storage/emulated/0/a.png', '_display_name': 'a.png', 'relative_path': '', '_size': '5', 'mime_type': 'image/png', 'date_modified': '1'}),
    ].join('\n');
    expect(parseMediaRows(out).map((f) => f.id), ['2']);
  });

  test('handles Windows line endings', () {
    final out = '${row(0, {'_id': '1', '_data': '/storage/emulated/0/a.jpg', '_display_name': 'a.jpg', 'relative_path': '', '_size': '1', 'mime_type': 'image/jpeg', 'date_modified': '1'})}\r\n';
    expect(parseMediaRows(out), hasLength(1));
  });

  test('a display name crafted to point at another file is refused', () {
    // ", _data=…" inside the name would make a naive parser read another path.
    final out = row(0, {
      '_id': '77',
      'relative_path': 'Download/',
      '_size': '5',
      'mime_type': 'image/jpeg',
      'date_modified': '1',
      '_display_name': 'x.jpg, _data=/storage/emulated/0/DCIM/real.jpg',
      '_data': '/storage/emulated/0/Download/x.jpg, _data=/storage/emulated/0/DCIM/real.jpg',
    });
    expect(parseMediaRows(out).where((f) => f.path.endsWith('/DCIM/real.jpg')), isEmpty);
  });

  test('a row forged on its own line for a real file is dropped with the real one', () {
    Map<String, String> real(String id) => {
          '_id': id, 'relative_path': 'DCIM/', '_size': '5', 'mime_type': 'image/jpeg', 'date_modified': '1',
          '_display_name': 'real.jpg', '_data': '/storage/emulated/0/DCIM/real.jpg',
        };
    final out = [row(0, real('77')), row(1, real('12'))].join('\n');
    expect(parseMediaRows(out), isEmpty);
  });
}