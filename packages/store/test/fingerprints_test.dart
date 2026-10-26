import 'package:declutter_store/declutter_store.dart';
import 'package:phone_link/phone_link.dart';
import 'package:test/test.dart';

PhoneFile file(String name, {int bytes = 10, int modified = 5}) => PhoneFile(
    path: '/storage/emulated/0/Download/$name', folder: 'Download/', bytes: bytes, mime: 'image/jpeg', modifiedSec: modified);

void main() {
  test('fingerprints are remembered until the file changes', () {
    final store = Store.inMemory();
    store.syncInventory('P', [file('a.jpg'), file('b.jpg')]);
    store.saveFingerprints('P', {file('a.jpg').path: 'aaa', file('b.jpg').path: 'bbb'});
    expect(store.fingerprints('P'), {file('a.jpg').path: 'aaa', file('b.jpg').path: 'bbb'});

    // b.jpg is edited on the phone: its old fingerprint no longer counts.
    store.syncInventory('P', [file('a.jpg'), file('b.jpg', bytes: 11, modified: 6)]);
    expect(store.fingerprints('P'), {file('a.jpg').path: 'aaa'});

    // a.jpg is deleted from the phone: its fingerprint goes with it.
    store.syncInventory('P', [file('b.jpg', bytes: 11, modified: 6)]);
    expect(store.fingerprints('P'), isEmpty);
  });
}
