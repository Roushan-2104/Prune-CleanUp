import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

String row(int n, Map<String, String> v) =>
    'Row: $n ${mediaColumns.map((c) => '$c=${v[c] ?? 'NULL'}').join(', ')}';

Map<String, String> photo(String id, String folder, String name) => {
      '_id': id, 'relative_path': folder, '_size': '5', 'mime_type': 'image/jpeg', 'date_modified': '1',
      '_display_name': name, '_data': '/storage/emulated/0/$folder$name',
    };

/// A find record (see findFormat) for [path].
String found(String path) => '5\t1\t$path\x00';

/// Files Android lists but whose media row Prune turns down must never be
/// taken for hidden files (which are deleted outright, with no Trash).
void main() {
  const root = '/storage/emulated/0';

  test('a name ending in a space is not offered as hidden', () {
    final out = '${row(0, photo('1', 'DCIM/', 'trailing.jpg '))}\n';
    final media = parseMediaRows(out);
    expect(media, isEmpty, reason: 'the row is turned down');
    final merged = mergeListings(media, parseFindRows(found('$root/DCIM/trailing.jpg ')), printed: MediaListedPaths(out));
    expect(merged, isEmpty);
  });

  test('a path listed twice is not offered as hidden', () {
    final out = [row(0, photo('1', 'DCIM/', 'twice.jpg')), row(1, photo('2', 'DCIM/', 'twice.jpg'))].join('\n');
    final merged = mergeListings(parseMediaRows(out), parseFindRows(found('$root/DCIM/twice.jpg')),
        printed: MediaListedPaths(out));
    expect(merged, isEmpty);
  });

  test('a name with a newline is not offered as hidden', () {
    const name = 'two\nlines.jpg';
    final out = '${row(0, photo('1', 'DCIM/', name))}\n${row(1, photo('2', 'DCIM/', 'ok.jpg'))}\n';
    final media = parseMediaRows(out);
    expect(media.map((f) => f.name), ['ok.jpg']);
    final merged = mergeListings(media, parseFindRows(found('$root/DCIM/$name') + found('$root/DCIM/ok.jpg')),
        printed: MediaListedPaths(out));
    expect(merged.map((f) => f.name), ['ok.jpg']);
    expect(merged.single.id, '2');
  });

  test('Windows line endings are understood', () {
    final out = '${row(0, photo('1', 'DCIM/', 'a.jpg '))}\r\n';
    expect(MediaListedPaths(out).contains('$root/DCIM/a.jpg '), isTrue);
  });

  test('files the media list never printed are still hidden files', () {
    const sent = '$root/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Sent/IMG-1.jpg';
    final out = row(0, photo('1', 'DCIM/', 'a.jpg'));
    final merged = mergeListings(parseMediaRows(out), parseFindRows(found(sent) + found('$root/DCIM/a.jpg')),
        printed: MediaListedPaths(out));
    expect(merged.where((f) => f.hiddenFromMediaList).map((f) => f.path), [sent]);
    expect(merged.where((f) => f.path == '$root/DCIM/a.jpg').single.id, '1');
  });

  test('a printed path only counts whole, not as the start of a longer one', () {
    const name = 'x\ny.jpg';
    final out = row(0, photo('1', 'DCIM/', '${name}z'));
    expect(MediaListedPaths(out).contains('$root/DCIM/$name'), isFalse);
    expect(MediaListedPaths(out).contains('$root/DCIM/${name}z'), isTrue);
  });
}
