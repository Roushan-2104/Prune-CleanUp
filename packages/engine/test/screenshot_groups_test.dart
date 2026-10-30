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

    // Made-up names; the shapes follow what WhatsApp shows.
    test('a notification pop-up over the chat is skipped', () {
      expect(chatTitle('9:41\nWhatsApp • now\nKiran Rao\nare you coming?\nReply  Mark as read\nAnil Joshi\nonline\nok'),
          'Anil Joshi');
      expect(chatTitle('@ WhatsApp\nW... • 8 messages from 3 chats • now\nStudy Group You de...\nTrip plan with s...'),
          isNull, reason: 'the pop-up fills the top: no chat name to take');
    });
    test('the caller in an incoming-call banner is not the chat', () {
      expect(chatTitle('9:41\nKiran Rao\nIncoming voice call\nDecline  Answer\nAnil Joshi\nlast seen today'), 'Anil Joshi');
    });
    test('a cut-off preview is not a name', () => expect(chatTitle('9:41\nKiran Rao: are you...\nAnil Joshi\nhi'), 'Anil Joshi'));
    test('the person in an ongoing call\'s bar is not the chat', () {
      // The bar read as one line…
      expect(chatTitle('1:42\n9400/0\nKiran Rao - 50:45\nAnil Joshi\nonline'), 'Anil Joshi');
      // …or split: the timer, a stray icon letter, then the caller's name.
      expect(chatTitle('19:30 @\n155\n- 4:08\np\n• Kiran Rao\n+91 90000 12345\nToday'), '+91 90000 12345');
      expect(chatTitle('19:30\n- 4:08\n+91 90000 11111\nAnil Joshi\nToday'), 'Anil Joshi', reason: 'caller saved as a number');
      expect(chatTitle('19:30\nKiran Rao\n- 4:08\nAnil Joshi'), 'Anil Joshi', reason: 'name above its timer');
      expect(chatTitle('12:35\nKiran Rao\nStudy Group\nAnil, Meera, Neel\n- 17:02'), 'Study Group',
          reason: 'timer read several lines after its name');
    });
    // Layout: made-up names at the positions real chat screens put them.
    test('by layout: the name beside the profile picture, under the status bar', () {
      expect(
          chatTitle('9:41\no 949%\nAnil Joshi Oq\nsee you at 5', boxes: const [
            LineBox(0.04, 0.019, 0.1, 0.015), LineBox(0.61, 0.016, 0.3, 0.018),
            LineBox(0.26, 0.068, 0.4, 0.019), LineBox(0.07, 0.123, 0.5, 0.02),
          ]),
          'Anil Joshi');
    });
    test('by layout: the call bar\'s whole row is skipped, the header below it is the chat', () {
      // Split call bar: timer and caller on one row; avatar letter at the left edge.
      expect(
          chatTitle('19:30\n- 4:08\np\n• Kiran Rao\n+91 90000 12345\nToday', boxes: const [
            LineBox(0.07, 0.020, 0.17, 0.013), LineBox(0.59, 0.077, 0.08, 0.011), LineBox(0.144, 0.134, 0.02, 0.012),
            LineBox(0.33, 0.075, 0.25, 0.015), LineBox(0.219, 0.133, 0.28, 0.013), LineBox(0.46, 0.178, 0.07, 0.011),
          ]),
          '+91 90000 12345');
      // Timer not read at all, only "Name -" left on the call bar's row.
      expect(
          chatTitle('6:06\nStudy Group -\nMeera Iyer\nhello', boxes: const [
            LineBox(0.04, 0.017, 0.3, 0.019), LineBox(0.231, 0.069, 0.42, 0.021),
            LineBox(0.261, 0.138, 0.25, 0.017), LineBox(0.17, 0.212, 0.5, 0.02),
          ]),
          'Meera Iyer');
    });
    test('by layout: a header the app cut short is still the name', () {
      expect(
          chatTitle('11:19\nKiran...\nkiran_r...\nhi', boxes: const [
            LineBox(0.04, 0.019, 0.07, 0.014), LineBox(0.30, 0.061, 0.14, 0.012),
            LineBox(0.30, 0.081, 0.16, 0.012), LineBox(0.45, 0.46, 0.4, 0.02),
          ]),
          'Kiran');
    });
    test('by layout: a pop-up over the top gives no name unless a header sits below it', () {
      const popUp = [
        LineBox(0.05, 0.03, 0.2, 0.015), LineBox(0.05, 0.055, 0.4, 0.015),
        LineBox(0.05, 0.08, 0.6, 0.018), LineBox(0.05, 0.11, 0.15, 0.015),
      ];
      expect(chatTitle('@ Instagram\nneel7 • now\nsaw this?\nReply\nlater then', boxes: const [
        ...popUp, LineBox(0.3, 0.6, 0.3, 0.02),
      ]), isNull);
      expect(chatTitle('@ Instagram\nneel7 • now\nsaw this?\nReply\nAnil Joshi\nlater then', boxes: const [
        ...popUp, LineBox(0.26, 0.14, 0.3, 0.019), LineBox(0.3, 0.6, 0.3, 0.02),
      ]), 'Anil Joshi');
    });
    test('by layout: positions that don\'t match the text fall back to the text rules', () {
      expect(chatTitle('17:02\nNeel7\nCall me after class', boxes: const [LineBox(0, 0, 0, 0)]), 'Neel7');
    });
    test('the chat list is not a chat with anyone', () {
      expect(chatTitle('11:52\nWhatsApp\nAsk Meta AI or Search\nAll\nUnread\nFavourites\nAnil Joshi'), isNull);
      expect(chatTitle('09:22\nChats\nAll\nUnread 11\nArchived\nFavourites\nGroups 2'), isNull);
      expect(chatTitle('10:05\nSearch contacts\nAll\nFavourites\nMissed\nAnil Joshi'), isNull, reason: 'contacts list');
    });
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
