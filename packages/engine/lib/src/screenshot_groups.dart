import 'text_rules.dart' show wholeWord;
import 'verdict.dart';

/// Finer groups for screenshots, found from the screenshots themselves:
/// chats by who they're with ("Neel7 · WhatsApp"), other screens by the
/// app or website they show ("leetcode.com", "YouTube"). A name needs
/// [minGroup] screenshots to get its own group, so one-offs don't clutter
/// the list; the rest keep their broader label.
Map<String, Verdict> groupScreenshots(Map<String, (Verdict, String)> shots,
    {Iterable<String> installedPackages = const [], int minGroup = 3}) {
  final out = <String, Verdict>{};

  // Chats: by the name at the top of the screen. (AI and Discord screens
  // show a model or channel there, not a person.)
  final chatKeys = <String, String>{}; // path → app|name key
  final chatNames = <String, Map<String, int>>{}; // key → spellings seen
  final unknownApp = <String>{}; // paths whose app wasn't recognised
  for (final MapEntry(key: path, value: (v, text)) in shots.entries) {
    if (v.category != JunkCategory.chatScreenshot || v.label == 'AI chats' || v.label == 'Discord chats') continue;
    final name = chatTitle(text);
    if (name == null) continue;
    if (v.label == null || v.label == 'Other chats') unknownApp.add(path);
    final key = '${v.label}|${_key(name)}';
    chatKeys[path] = key;
    (chatNames[key] ??= {}).update(name, (n) => n + 1, ifAbsent: () => 1);
  }
  _mergeChatNames(chatKeys, chatNames, unknownApp);
  final chatCounts = <String, int>{};
  for (final k in chatKeys.values) {
    chatCounts.update(k, (n) => n + 1, ifAbsent: () => 1);
  }

  // Other screens: by website or app.
  final apps = appNamesFromPackages(installedPackages);
  final sources = <String, String>{}; // path → source
  for (final MapEntry(key: path, value: (v, text)) in shots.entries) {
    if (v.category != JunkCategory.otherScreenshot) continue;
    final s = screenSource(text, apps);
    if (s != null) sources[path] = s;
  }
  final sourceCounts = <String, int>{};
  for (final s in sources.values) {
    sourceCounts.update(s, (n) => n + 1, ifAbsent: () => 1);
  }

  for (final MapEntry(key: path, value: (v, _)) in shots.entries) {
    final chatKey = chatKeys[path];
    final source = sources[path];
    if (chatKey != null && chatCounts[chatKey]! >= minGroup) {
      final spellings = chatNames[chatKey]!.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      // The longest common spelling: "Dev Sharma" over "Dev Shar".
      final top = spellings.first.value;
      final name = spellings.where((e) => e.value * 3 >= top).map((e) => e.key).reduce((a, b) => b.length > a.length ? b : a);
      final app = chatKey.split('|').first;
      out[path] = _relabel(v, app == 'Other chats' || app == 'null' ? name : '$name · ${_appOnly(app)}', {'Chat with': name});
    } else if (v.category == JunkCategory.chatScreenshot && v.label != null && v.label != 'Other chats') {
      out[path] = _relabel(v, 'Other ${v.label}', const {});
    } else if (source != null && sourceCounts[source]! >= minGroup) {
      out[path] = _relabel(v, source, {'Shows': source});
    } else {
      out[path] = v;
    }
  }
  return out;
}

/// Joins spellings of one chat: a header cut short ("Dev Shar…" into
/// "Dev Sharma"), and chats whose app wasn't recognised into the same
/// name's chats from a known app.
void _mergeChatNames(Map<String, String> keys, Map<String, Map<String, int>> names, Set<String> unknownApp) {
  int count(String k) => names[k]!.values.fold(0, (a, b) => a + b);
  final byCount = names.keys.toList()..sort((a, b) => count(b).compareTo(count(a)));
  final into = <String, String>{};
  for (final (i, small) in byCount.indexed) {
    final [app, name] = small.split('|');
    for (final big in byCount.take(i)) {
      if (into.containsKey(big)) continue;
      final [bigApp, bigName] = big.split('|');
      final sameApp = app == bigApp || app == 'Other chats' || app == 'null';
      final sameName = name == bigName || name.length >= 6 && (bigName.startsWith(name) || name.startsWith(bigName) && bigName.length >= 6);
      if (sameApp && sameName) {
        into[small] = big;
        break;
      }
    }
  }
  for (final MapEntry(key: path, value: k) in keys.entries.toList()) {
    final target = into[k];
    if (target == null) continue;
    keys[path] = target;
    for (final MapEntry(key: spelling, value: n) in names[k]!.entries) {
      names[target]!.update(spelling, (m) => m + n, ifAbsent: () => n);
    }
    unknownApp.remove(path);
  }
}

Verdict _relabel(Verdict v, String label, Map<String, String> moreEvidence) =>
    Verdict(v.category, v.confidence, v.reasons, label: label, evidence: {...moreEvidence, ...v.evidence});

/// "WhatsApp chats" → "WhatsApp", "Instagram DMs" → "Instagram".
String _appOnly(String? label) => (label ?? 'Chat').replaceAll(RegExp(r' (chats|DMs|messages)$'), '');

String _key(String name) => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

// ---------------------------------------------------------------------------
// Who a chat is with.

final _time = RegExp(r'\b(?:[01]?\d|2[0-3])[:.][0-5]\d\b');
const _notNames = {
  'today', 'yesterday', 'you', 'call', 'video', 'message', 'messages', 'contact info', 'chats', 'online',
  'whatsapp', 'instagram', 'search', 'new chat', 'locked chats', 'archived', 'unread', 'no permission',
  'instagram chats', 'share a link to chat', 'search or ask a question', 'view more details', 'report an issue',
};
// A notification or call pop-up at the top of the screen, and the line that
// ends it (its buttons).
final _popUpStart = RegExp(
  r'^\W*whatsapp\b|\bmessages? from \d|•\s*now\b|\bincoming (?:voice |video )?call\b',
  caseSensitive: false,
);
final _popUpEnd = RegExp(r'^\W*(?:reply|mark as read|answer|decline|dismiss)\b', caseSensitive: false);
// An ongoing call's timer: a dash, then minutes and seconds ("- 4:08",
// "Meera - 50:45"). The status bar's clock has no dash in front.
final _callTimer = RegExp(r'(?:^|\s)[-–]\s*\d{1,2}:\d{2}(?::\d{2})?\s*$');
final _callBanner = RegExp(r'\b(?:incoming|ongoing|ringing|tap to return)\b', caseSensitive: false);
// WhatsApp's chat list, not a chat.
final _chatList = RegExp(r'ask meta a[il]|\ball\s*\n.*\bunread\b|\bunread\b[\s\S]{0,80}\b(?:favourites|archived)\b',
    caseSensitive: false);
// App screens' own words, never someone's name.
final _uiWords = RegExp(r'\b(?:instagram|whatsapp|search|share|messages?|chats?|calls?|settings|notifications?)\b', caseSensitive: false);

/// The contact or group name at the top of a chat screenshot, or null.
///
/// It's the first line under the status bar that looks like a name: short,
/// mostly letters (or a phone number), not a time, not battery or signal
/// readings. OCR noise around it is trimmed: a stray avatar letter in
/// front ("A Neel7"), smudges after it ("Aman Kapoor Oq").
///
/// Pop-ups over the chat never give the name: a notification ("WhatsApp •
/// now · 8 messages from 3 chats", a sender and a cut-off preview) or an
/// incoming call ("Incoming voice call", "Answer") is skipped down to its
/// action line; if the pop-up fills the top, there is no name. The chat
/// list ("Ask Meta AI or Search", "All · Unread · Favourites") isn't a
/// chat with anyone either.
String? chatTitle(String rawText) {
  if (_chatList.hasMatch(rawText)) return null;
  final all = rawText.replaceAll('\r', '').split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).take(12).toList();
  final popUp = all.take(4).any(_popUpStart.hasMatch);
  final lines = popUp ? all : all.take(6).toList();
  var inPopUp = popUp;
  // An ongoing call's bar ("Meera - 4:08") is the topmost thing under the
  // status bar, so with a call timer near the top the first name found is
  // the person on the call, not the chat. When OCR keeps the name on the
  // timer's line, skipping that line is enough; when it splits them, in
  // either order, the first name elsewhere is skipped.
  final timer = lines.take(6).where(_callTimer.hasMatch).firstOrNull;
  var skipCaller = timer != null && !RegExp(r'\p{L}{2}', unicode: true).hasMatch(timer);
  for (final (i, line) in lines.indexed) {
    if (inPopUp) {
      if (_popUpEnd.hasMatch(line)) inPopUp = false;
      continue;
    }
    if (_callTimer.hasMatch(line)) continue;
    // A name cut short ("Rahul…", "Meera Iyer: see you...") is a preview, not a header.
    if (line.endsWith('...') || line.endsWith('…')) continue;
    // The caller in an incoming-call banner, not the chat.
    if (i + 1 < lines.length && _callBanner.hasMatch(lines[i + 1])) continue;
    // Status bar and its pieces: times, battery "949%" / "0350/0", signal.
    if (_time.hasMatch(line) && !line.startsWith('+')) continue;
    if (RegExp(r'\d{2,3}\s?%|\d{3,4}/0|\b(?:lte|[45]g|volte)\b', caseSensitive: false).hasMatch(line)) continue;

    if (RegExp(r'^\+?\d[\d\s\-]{8,}$').hasMatch(line)) {
      if (!skipCaller) return line; // a saved-as-number contact
      skipCaller = false; // …or a caller saved as a number
      continue;
    }

    var tokens = line
        .replaceAll(RegExp(r"[^\p{L}\p{N}\s'._\-+()&]", unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.length > 1 && tokens.first.length == 1) tokens = tokens.sublist(1); // avatar letter
    while (tokens.length > 1 && tokens.last.length <= 2) {
      tokens = tokens.sublist(0, tokens.length - 1); // trailing smudge
    }
    final name = tokens.join(' ').replaceAll(RegExp(r"^[.'_\-]+|[.'_\-]+$"), '');
    final letters = RegExp(r'\p{L}', unicode: true).allMatches(name).length;
    if (name.length < 3 || name.length > 40 || letters < 3 || tokens.length > 6) continue;
    if (letters < name.replaceAll(' ', '').length * 0.6) continue;
    if (_notNames.contains(name.toLowerCase()) || _uiWords.hasMatch(name)) continue;
    if (skipCaller) {
      skipCaller = false;
      continue;
    }
    return name;
  }
  return null;
}

// ---------------------------------------------------------------------------
// What app or site a screen shows.

const _knownSites = {
  'docs.google.com': 'Google Docs', 'forms.google.com': 'Google Forms', 'mail.google.com': 'Gmail',
  'drive.google.com': 'Google Drive', 'meet.google.com': 'Google Meet', 'maps.google.com': 'Google Maps',
  'chatgpt.com': 'ChatGPT', 'claude.ai': 'Claude', 'gemini.google.com': 'Gemini',
};

const _brands = {
  'youtube': 'YouTube', 'instagram': 'Instagram', 'facebook': 'Facebook', 'linkedin': 'LinkedIn',
  'snapchat': 'Snapchat', 'pinterest': 'Pinterest', 'reddit': 'Reddit', 'twitter': 'X (Twitter)',
  'spotify': 'Spotify', 'netflix': 'Netflix', 'flipkart': 'Flipkart', 'amazon': 'Amazon', 'myntra': 'Myntra',
  'meesho': 'Meesho', 'swiggy': 'Swiggy', 'zomato': 'Zomato', 'blinkit': 'Blinkit', 'zepto': 'Zepto',
  'irctc': 'IRCTC', 'uber': 'Uber', 'rapido': 'Rapido', 'leetcode': 'LeetCode', 'github': 'GitHub',
  'chatgpt': 'ChatGPT', 'gemini': 'Gemini', 'gmail': 'Gmail', 'google maps': 'Google Maps',
  'google classroom': 'Google Classroom', 'telegram': 'Telegram', 'truecaller': 'Truecaller',
  'whatsapp': 'WhatsApp', 'phonepe': 'PhonePe', 'paytm': 'Paytm', 'discord': 'Discord', 'canva': 'Canva',
  'notion': 'Notion', 'udemy': 'Udemy', 'zoom': 'Zoom', 'nykaa': 'Nykaa', 'ajio': 'AJIO', 'redbus': 'redBus',
  'ixigo': 'ixigo', 'goibibo': 'Goibibo', 'lenskart': 'Lenskart', 'dominos': "Domino's", 'jiomart': 'JioMart',
  'instamart': 'Instamart', 'digilocker': 'DigiLocker', 'scaler': 'Scaler', 'claude': 'Claude', 'deepseek': 'DeepSeek',
  'substack': 'Substack', 'lichess': 'Lichess',
};

// Package-name parts that say nothing about the app.
const _packageNoise = {
  'com', 'org', 'net', 'in', 'io', 'co', 'app', 'apps', 'android', 'mobile', 'client', 'lite', 'pro', 'free',
  'google', 'samsung', 'nothing', 'miui', 'xiaomi', 'oneplus', 'oppo', 'vivo', 'realme', 'motorola', 'huawei',
  'qualcomm', 'mediatek', 'sec', 'system', 'providers', 'provider', 'service', 'services', 'framework', 'overlay',
  'theme', 'launcher', 'ui', 'main', 'release', 'prod', 'global', 'india', 'intl', 'international',
  'application', 'customerapp', 'passenger', 'supply', 'ordering', 'essential', 'editors', 'editor', 'user',
};

// App words too common to look for in a screen's text.
const _commonWords = {
  'camera', 'gallery', 'photos', 'music', 'notes', 'files', 'clock', 'settings', 'contacts', 'phone', 'dialer',
  'messages', 'messaging', 'calendar', 'weather', 'keyboard', 'browser', 'wallet', 'shopping', 'health', 'fitness',
  'news', 'video', 'videos', 'player', 'editor', 'scanner', 'calculator', 'recorder', 'translate', 'maps', 'drive',
  'docs', 'sheets', 'slides', 'keep', 'meet', 'chat', 'mail', 'email', 'store', 'market', 'vending', 'search',
  'assistant', 'photo', 'gpay', 'paisa', 'books', 'games', 'game', 'learning', 'radio', 'bank', 'banking', 'money',
  'speaker', 'cleaner', 'freedom', 'atomic', 'tunes', 'train', 'scholarships', 'water', 'subscriptions',
};

/// Readable app names from the phone's package names, e.g.
/// "com.flipkart.android" → "flipkart". Only distinctive names are kept,
/// so they can be looked for in a screenshot's text.
Set<String> appNamesFromPackages(Iterable<String> packages) => {
      for (final p in packages)
        if (p.toLowerCase().split('.').where((t) =>
                t.length >= 5 && RegExp(r'^[a-z]+$').hasMatch(t) && !_packageNoise.contains(t) && !_commonWords.contains(t))
            case final parts when parts.isNotEmpty)
          parts.first,
    };

// A web address, not the end of an email ("x@gmail.com").
final _domain =
    RegExp(r'(?<![@\w.\-])((?:[a-z0-9-]+\.)+(?:com|in|org|net|io|ai|co|dev|app|me|gov\.in|ac\.in|co\.in|edu))\b(?!\.[a-z])');

/// The website or app a screen shows: a web address on it ("leetcode.com"),
/// else a known app's name, else an app installed on the phone. A site
/// that is a known app gets the app's name, so "leetcode.com" and the
/// LeetCode app land in one group.
String? screenSource(String rawText, [Set<String> installedApps = const {}]) {
  final text = rawText.toLowerCase();
  for (final m in _domain.allMatches(text)) {
    var host = m.group(1)!;
    if (host.startsWith('www.')) host = host.substring(4);
    if (_knownSites[host] case final name?) return name;
    final parts = host.split('.');
    // "in.pinterest.com" → "pinterest.com"; keep "something.ac.in" whole.
    final countryPair = host.endsWith('.ac.in') || host.endsWith('.co.in') || host.endsWith('.gov.in');
    final site = parts.length > 2 && !countryPair ? parts.sublist(parts.length - 2).join('.') : host;
    if (_brands[site.split('.').first] case final brand?) return brand;
    if (site.length >= 6) return site;
  }
  for (final MapEntry(key: word, value: name) in _brands.entries) {
    if (wholeWord(word).hasMatch(text)) return name;
  }
  for (final app in installedApps) {
    if (wholeWord(app).hasMatch(text)) return _brands[app] ?? app[0].toUpperCase() + app.substring(1);
  }
  return null;
}
