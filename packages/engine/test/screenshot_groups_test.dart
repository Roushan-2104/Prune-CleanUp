import 'package:declutter_engine/declutter_engine.dart';
import 'package:test/test.dart';

const _wa = Verdict(JunkCategory.chatScreenshot, 0.93, ['chat'], label: 'WhatsApp chats');
const _unknown = Verdict(JunkCategory.chatScreenshot, 0.7, ['chat'], label: 'Other chats');
const _other = Verdict(JunkCategory.otherScreenshot, 0.7, ['screen'], label: 'Other app screens');

void main() {
  group('who a chat is with', () {
    test('first name-like line under the status bar', () {
      expect(chatTitle('17:02\nNeel7\nCall me after class\n21:10'), 'Neel7');
      expect(chatTitle('10:30 0\n0 949%\nNR 5G\nPapa\nOn my way 9:57 pm'), 'Papa');
    });
    test('OCR noise around the name is trimmed', () {
      expect(chatTitle('22:54 8 M\nA Neel7\nNo idea'), 'Neel7');
      expect(chatTitle('1:02 M •\no "80/0\nNeha Singh Oq\nsee you'), 'Neha Singh');
    });
    test('a contact saved as a number', () => expect(chatTitle('13:48\n+91 90000 12345\nToday'), '+91 90000 12345'));
    test('app words are never names', () => expect(chatTitle('3:52\nInstagram • Chats\nSearch or ask a question'), isNull));
  });

  test('chats with one person get their own group; one-offs do not', () {
    final shots = {
      for (var i = 0; i < 3; i++) '/ravi$i': (_wa, '10:1$i\nRavi Kumar\nyes ${i}0:12 pm'),
      '/once': (_wa, '10:12\nRandom Person\nhello'),
    };
    final g = groupScreenshots(shots);
    expect(g['/ravi0']!.label, 'Ravi Kumar · WhatsApp');
    expect(g['/ravi0']!.evidence['Chat with'], 'Ravi Kumar');
    expect(g['/once']!.label, 'Other WhatsApp chats');
  });

  test('a cut-off header and an unrecognised app join the same person', () {
    final shots = {
      '/a': (_wa, '10:12\nAditi Sharma\nhi'),
      '/b': (_wa, '10:13\nAditi Sharma\nhi'),
      '/c': (_wa, '10:14\nAditi Shar\nhi'),
      '/d': (_unknown, '10:15\nAditi Sharma\nhi'),
    };
    final g = groupScreenshots(shots);
    expect({for (final v in g.values) v.label}, {'Aditi Sharma · WhatsApp'});
  });

  group('what app or site a screen shows', () {
    test('a web address, not an email', () {
      expect(screenSource('leetcode.com/problems/two-sum'), 'LeetCode');
      expect(screenSource('in.pinterest.com/pin/123'), 'Pinterest');
      expect(screenSource('portal.sample-college.ac.in/results'), 'portal.sample-college.ac.in');
      expect(screenSource('Write to me at someone@example.org'), isNull);
    });
    test('an installed app found in the text', () {
      final apps = appNamesFromPackages(['com.savana.in', 'com.google.android.apps.nbu.paisa.user', 'com.android.camera']);
      expect(apps, {'savana'});
      expect(screenSource('Savana\nNew arrivals\nDresses', apps), 'Savana');
    });
    test('needs a few screenshots to become a group', () {
      final shots = {
        for (var i = 0; i < 3; i++) '/lc$i': (_other, 'leetcode.com/problems/$i'),
        '/gh': (_other, 'github.com/someone'),
      };
      final g = groupScreenshots(shots);
      expect(g['/lc0']!.label, 'LeetCode');
      expect(g['/gh']!.label, 'Other app screens');
    });
  });
}
