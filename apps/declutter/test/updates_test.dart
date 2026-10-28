import 'dart:io';

import 'package:declutter/updates.dart';
import 'package:flutter_test/flutter_test.dart';

/// The optional update check, with a fake GitHub: it never goes online here.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('prune_updates_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  UpdateCheck make({String current = '1.0.1', ({String version, String url})? latest, void Function()? onAsk}) =>
      UpdateCheck(
        settings: File('${dir.path}\\settings.json'),
        current: current,
        fetch: () async {
          onAsk?.call();
          return latest;
        },
      );

  test('versions compare by number, not by text', () {
    expect(isNewer('1.0.2', '1.0.1'), isTrue);
    expect(isNewer('v1.10.0', '1.9.9'), isTrue);
    expect(isNewer('1.0.1', '1.0.1'), isFalse);
    expect(isNewer('1.0.0', '1.0.1'), isFalse);
    expect(isNewer('nightly', '1.0.1'), isFalse, reason: 'unreadable is never newer');
  });

  test('never goes online until the user says yes', () async {
    var asked = 0;
    final u = make(onAsk: () => asked++);
    await u.start();
    expect(u.allowed, isNull, reason: 'the question is shown');
    await u.check();
    expect(asked, 0);
    await u.allow(false);
    expect(asked, 0);
    final again = make(onAsk: () => asked++);
    await again.start();
    expect(asked, 0, reason: 'still no after a restart');
  });

  test('"No thanks" is remembered', () async {
    await make().allow(false);
    final again = make();
    await again.start();
    expect(again.allowed, isFalse);
  });

  test('a newer release is offered, with its page', () async {
    final u = make(latest: (version: '1.0.2', url: '${releasesPage}tag/v1.0.2'));
    await u.allow(true);
    expect(u.newer, '1.0.2');
    expect(u.newerUrl, '${releasesPage}tag/v1.0.2');
  });

  test('same or older release: nothing to offer', () async {
    final u = make(latest: (version: '1.0.1', url: '${releasesPage}tag/v1.0.1'));
    await u.allow(true);
    expect(u.newer, isNull);
  });

  test('a link anywhere but the project\'s releases is ignored', () async {
    final u = make(latest: (version: '9.9.9', url: 'https://example.com/prune.exe'));
    await u.allow(true);
    expect(u.newer, isNull);
  });

  test('checks at most once a day', () async {
    var asked = 0;
    await make(onAsk: () => asked++).allow(true);
    expect(asked, 1);
    await make(onAsk: () => asked++).start();
    expect(asked, 1, reason: 'checked less than a day ago');
  });

  test('the app version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!.group(1), appVersion);
  });
}
