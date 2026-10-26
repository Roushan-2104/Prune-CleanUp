import 'verdict.dart';

/// Classifies a screenshot from the text OCR found on it.
///
/// Rules are deliberately strict: a category only reaches "sure" when several
/// independent signals agree (e.g. an amount AND a UPI reference AND a
/// success message).
Verdict classifyScreenshotText(String rawText) {
  final text = _normalize(rawText);

  // Payment receipts are full of times like "10:42 pm", so they can look
  // like chats too. A real receipt wins over chat evidence.
  final payment = _payment(text);
  if (payment != null) return payment;

  final chat = _chat(text);
  if (chat != null) return chat;

  if (_isPaymentQr(text)) {
    return const Verdict(JunkCategory.otherScreenshot, 0.7, ['A "Scan & Pay" QR code, not a receipt'],
        label: 'Payment QR codes');
  }
  return classifyOtherScreenshot(text);
}

/// What kind of screen a non-payment, non-chat screenshot shows.
class ScreenshotKind {
  const ScreenshotKind(this.label, this.brands, this.words, {this.mightBeImportant = false});
  final String label;

  /// App or site names — one is enough to recognise the screen.
  final List<String> brands;

  /// Generic UI words — need two of them.
  final List<String> words;

  /// Tickets, IDs, bills: shown but never pre-selected.
  final bool mightBeImportant;
}

const screenshotKinds = [
  ScreenshotKind('Instagram', ['instagram', 'reels', 'reel'],
      ['liked by', 'follow', 'followers', 'following', 'view all comments', 'add comment', 'story', 'original audio', 'sponsored']),
  ScreenshotKind('YouTube', ['youtube', 'shorts'],
      ['subscribe', 'subscribers', 'views', 'watch later', 'comments', 'premiere']),
  ScreenshotKind('Social media posts', ['facebook', 'twitter', 'snapchat', 'threads', 'linkedin', 'sharechat', 'moj', 'josh'],
      ['retweet', 'repost', 'like', 'share', 'comment', 'follow', 'post', 'trending']),
  ScreenshotKind('Shopping', ['flipkart', 'amazon', 'myntra', 'meesho', 'ajio', 'nykaa', 'tata cliq'],
      ['add to cart', 'buy now', 'free delivery', 'mrp', 'off', 'size', 'rating', 'wishlist', 'in stock']),
  ScreenshotKind('Food & grocery', ['swiggy', 'zomato', 'blinkit', 'zepto', 'bigbasket', 'instamart', 'dunzo'],
      ['order', 'delivery', 'restaurant', 'menu', 'veg', 'cart', 'arriving']),
  ScreenshotKind('Maps & directions', ['google maps', 'ola', 'uber', 'rapido'],
      ['directions', 'route', 'km', 'via', 'start', 'pickup', 'drop', 'location']),
  ScreenshotKind('Tickets & bookings', ['irctc', 'bookmyshow', 'makemytrip', 'redbus', 'ixigo', 'indigo', 'goibibo'],
      ['pnr', 'boarding', 'seat', 'coach', 'booking id', 'departure', 'arrival', 'passenger', 'ticket'],
      mightBeImportant: true),
  ScreenshotKind('Documents & IDs', ['aadhaar', 'digilocker', 'pan card', 'uidai'],
      ['invoice', 'certificate', 'receipt', 'bill', 'date of birth', 'address', 'gst', 'policy'],
      mightBeImportant: true),
  ScreenshotKind('News & articles', ['inshorts', 'times of india', 'ndtv', 'dailyhunt', 'google news'],
      ['read more', 'minutes ago', 'hours ago', 'news', 'article', 'published', 'updated']),
  ScreenshotKind('Phone settings & home screen', ['settings'],
      ['battery', 'wi-fi', 'wifi', 'bluetooth', 'storage', 'notifications', 'about phone', 'display', 'apps', 'camera', 'gallery', 'clock']),
  ScreenshotKind('Games', ['bgmi', 'free fire', 'ludo', 'candy crush', 'clash'],
      ['level', 'score', 'victory', 'play again', 'rank', 'coins', 'reward']),
];

/// Labels a screenshot that isn't a payment, chat or OTP.
Verdict classifyOtherScreenshot(String normalizedText) {
  final text = normalizedText;
  if (text.replaceAll(RegExp(r'\s'), '').length < 15) {
    return const Verdict(JunkCategory.otherScreenshot, 0.7, ['Picture with little or no text'],
        label: 'Pictures & memes');
  }

  ScreenshotKind? best;
  var bestScore = 0;
  for (final kind in screenshotKinds) {
    final score = 2 * _countWords(text, kind.brands) + _countWords(text, kind.words);
    if (score > bestScore) {
      best = kind;
      bestScore = score;
    }
  }

  if (best == null || bestScore < 2) {
    return const Verdict(JunkCategory.otherScreenshot, 0.7, ['Screenshot'], label: 'Other app screens');
  }
  if (best.mightBeImportant) {
    return Verdict(JunkCategory.otherScreenshot, 0.6, ['Looks like ${best.label.toLowerCase()} — might be important'],
        label: best.label);
  }
  return Verdict(JunkCategory.otherScreenshot, 0.75, ['Looks like ${best.label.toLowerCase()}'], label: best.label);
}

/// Amount and payee pulled from a payment screenshot, for the Payment Proofs list.
class PaymentInfo {
  const PaymentInfo({this.amount, this.payee});
  final double? amount;
  final String? payee;

  @override
  String toString() => 'PaymentInfo($amount, $payee)';
}

PaymentInfo extractPaymentInfo(String rawText) {
  final text = rawText.replaceAll('\r', '');
  final amountMatch = _amount.firstMatch(_normalize(text));
  final amount = amountMatch == null
      ? null
      : double.tryParse(amountMatch.group(1)!.replaceAll(',', ''));

  String? payee;
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  for (var i = 0; i < lines.length; i++) {
    final m = RegExp(r'^(?:paid to|sent to|to)\s*:?\s*(.*)$', caseSensitive: false)
        .firstMatch(lines[i]);
    if (m == null) continue;
    final rest = m.group(1)!.trim();
    payee = rest.isNotEmpty ? rest : (i + 1 < lines.length ? lines[i + 1] : null);
    break;
  }
  return PaymentInfo(amount: amount, payee: payee);
}

// ---------------------------------------------------------------------------

String _normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[ \t]+'), ' ');

bool _any(String text, List<String> phrases) => phrases.any(text.contains);

/// Like [_any] but whole words only, so "cred" doesn't match "credited".
bool _anyWord(String text, List<String> words) =>
    words.any((w) => RegExp('\\b${RegExp.escape(w)}\\b').hasMatch(text));

int _countWords(String text, List<String> words) =>
    words.where((w) => RegExp('\\b${RegExp.escape(w)}\\b').hasMatch(text)).length;

// Amounts in any common currency, symbol or code first ("$25.00", "₹250",
// "usd 40") or after ("45,20 €", "120 eur"). OCR often reads "₹" as "rs",
// "inr", "%" or "z" — e.g. "₹250" → "%250".
final _amount = RegExp(
    r'(?:₹|%|\brs\.?|\binr|\bz|\$|€|£|¥|₱|₦|₩|₺|₽|\br\$|\b(?:usd|eur|gbp|aud|cad|sgd|aed|php|ngn|brl|jpy|chf)\b)'
    r'\s?([0-9][0-9,]*(?:\.[0-9]{1,2})?)');
final _amountAfter = RegExp(r'\b([0-9][0-9.,]*[0-9])\s?(?:€|£|\b(?:eur|usd|gbp|chf|kr|zł)\b)');

const _paymentSuccess = [
  // India
  'paid to', 'payment successful', 'paid successfully', 'transaction successful',
  'money sent', 'sent successfully', 'received from', 'payment received',
  'debited from', 'credited to', 'transfer successful',
  // Worldwide
  'you sent', 'you paid', 'you received ₹', r'you received $', 'you received rs', 'payment sent', 'payment complete', 'payment confirmed',
  'transfer complete', 'transaction complete', 'thanks for your payment', 'paid with', 'payment to',
  'money received', 'request paid',
];
const _paymentIds = [
  'upi ref', 'upi transaction id', 'transaction id', 'utr', 'upi id',
  'txn id', 'reference no', 'ref no', 'order id',
  'transaction number', 'reference number', 'reference:', 'confirmation number', 'receipt number',
  'payment id', 'authorization code',
];
const _paymentApps = [
  // India
  'phonepe', 'google pay', 'gpay', 'paytm', 'bhim', 'amazon pay', 'cred',
  'upi', 'navi', 'mobikwik', 'supermoney',
  // Worldwide
  'paypal', 'venmo', 'cash app', 'cashapp', 'zelle', 'revolut', 'wise', 'monzo', 'n26', 'chime',
  'apple pay', 'google wallet', 'samsung pay', 'alipay', 'wechat pay', 'gcash', 'maya', 'm-pesa', 'mpesa',
  'pix', 'bkash', 'skrill', 'payoneer', 'klarna', 'grabpay', 'touch n go',
];

// An amount alone on its line, as receipts print it big. OCR misreads the
// "₹" as "?", "Q", "«" or "z" and zeros as "O": "?369.69", "QIOO.OO".
final _amountLine = RegExp(r'^(?:₹|rs\.?|inr|[?q«z%t])\s?([0-9oil][0-9oil,]*(?:\.[0-9o]{2})?)(?:/-)?$', multiLine: true);

String? _amountOnItsOwnLine(String text) {
  for (final m in _amountLine.allMatches(text)) {
    final digits = m.group(1)!.replaceAll('o', '0').replaceAll(RegExp('[il]'), '1');
    if (RegExp(r'^[0-9][0-9,]*(?:\.[0-9]{2})?$').hasMatch(digits) && digits.replaceAll(RegExp(r'\D'), '').length >= 2) {
      return m.group(0)!.trim();
    }
  }
  return null;
}

// "name@okaxis", "98765@ybl": a UPI ID (not an email: no ".com" after it).
final _upiId = RegExp(r'\b[a-z0-9._\-]{3,}@[a-z]{2,20}\b(?![.\-])');

// "Paid · 10:12 pm", "Received • 9:30 am" under each payment in a UPI chat.
final _paymentStatusLine = RegExp(r'\b(?:paid|received|sent|declined|failed)\s?[·•.\-]\s?(?:[01]?\d|2[0-3])[:.][0-5]\d');

// A payment QR code (a shop's standee, "Scan & Pay"), not a receipt.
const _qrWords = ['scan & pay', 'scan and pay', 'scan to pay', 'accepted here', 'scanvpay', 'scan any qr'];

// Bank SMS / alerts: "A/c XX9920 debited INR 55.00".
final _bankAlert = RegExp(r'\b(?:a/?c|acct|account)\b[^\n]{0,40}\b(?:debited|credited)\b|\b(?:debited|credited)\b[^\n]{0,40}\b(?:a/?c|acct|account)\b');

const _paymentAppNames = {
  'phonepe': 'PhonePe', 'google pay': 'Google Pay', 'gpay': 'Google Pay', 'paytm': 'Paytm', 'bhim': 'BHIM',
  'amazon pay': 'Amazon Pay', 'cred': 'CRED', 'mobikwik': 'MobiKwik', 'supermoney': 'super.money',
  'paypal': 'PayPal', 'venmo': 'Venmo', 'cash app': 'Cash App', 'cashapp': 'Cash App', 'zelle': 'Zelle',
  'revolut': 'Revolut', 'wise': 'Wise', 'gcash': 'GCash', 'm-pesa': 'M-Pesa', 'mpesa': 'M-Pesa', 'razorpay': 'Razorpay',
};

Verdict? _payment(String text) {
  final amountText = (_amount.firstMatch(text) ?? _amountAfter.firstMatch(text))?.group(0)?.trim() ??
      _amountOnItsOwnLine(text);
  final hasAmount = amountText != null;
  final success = _paymentSuccess.where(text.contains).toList();
  final ids = _paymentIds.where(text.contains).toList();
  final upi = _upiId.firstMatch(text)?.group(0);
  final hasApp = _anyWord(text, _paymentApps);
  final appName = _paymentAppNames.entries
      .where((e) => RegExp('\\b${RegExp.escape(e.key)}\\b').hasMatch(text))
      .map((e) => e.value)
      .firstOrNull;

  final evidence = {
    if (amountText != null) 'Amount found': amountText,
    if (success.isNotEmpty || ids.isNotEmpty) 'Words found': _quoted([...success, ...ids].take(3)),
    if (upi != null) 'UPI ID': upi,
    if (appName != null) 'App': appName,
  };
  Verdict v(double c, List<String> reasons, String label) =>
      Verdict(JunkCategory.paymentScreenshot, c, reasons, label: label, evidence: evidence);
  final label = appName != null ? '$appName payments' : (upi != null ? 'UPI payments' : 'Payments');

  // A receipt says the money moved AND shows proof of it.
  if (success.isNotEmpty) {
    final proofs = [
      if (hasAmount) 'Shows an amount',
      if (upi != null) 'Shows a UPI ID',
      if (ids.isNotEmpty) 'Has a transaction reference',
    ];
    final reasons = ['Says "${success.first}"', ...proofs];
    if (proofs.length >= 2) return v(0.97, reasons, label);
    if (proofs.length == 1) return v(0.92, reasons, label);
    if (hasApp) return v(0.7, [...reasons, 'Mentions a payment app'], label);
    return null;
  }
  // A UPI app's chat with one person: "₹500 / Paid · 10:12 pm" again and again.
  final statusLines = _paymentStatusLine.allMatches(text).length;
  if (hasAmount && statusLines >= 2) {
    return v(0.8, ['$statusLines payments listed, like "Paid · 10:12 pm"', 'Shows an amount'], label);
  }
  if (hasAmount && _bankAlert.hasMatch(text)) {
    return v(0.8, ['Bank message: money debited or credited', 'Shows an amount'], 'Bank alerts');
  }
  // Checkout pages, bookings and QR standees mention payments but aren't receipts.
  return null;
}

/// A shop's or friend's "Scan & Pay" QR code.
bool _isPaymentQr(String text) => _any(text, _qrWords) && _upiId.hasMatch(text) || _any(text, _qrWords) && _anyWord(text, _paymentApps);

/// ["paid to", "utr"] → '"paid to", "utr"' (or "—" when empty).
String _quoted(Iterable<String> words) => words.isEmpty ? '—' : words.map((w) => '"$w"').join(', ');

// Times like "10:42 pm" or "19:38". The first one on a screenshot is
// usually the phone's clock in the status bar, not a message.
final _clock = RegExp(r'\b(?:[01]?\d|2[0-3])[:.][0-5]\d\s?(?:am|pm)?\b');

/// The phone's status bar (clock, battery, signal) at the top: the surest
/// sign an image is a screenshot and not a photo of a poster or a page.
bool hasStatusBar(String rawText) {
  final head = _normalize(rawText).trimLeft();
  final top = head.length > 30 ? head.substring(0, 30) : head;
  return RegExp(r'^\W{0,4}(?:[01]?\d|2[0-3])[:.][0-5]\d\b').hasMatch(top) ||
      RegExp(r'(?:^|\n)[^\n]{0,12}\b(?:[01]?\d|2[0-3])[:.][0-5]\d\b').hasMatch(top) &&
          RegExp(r'\b(?:lte|4g|5g|volte|\d{2,3}%)').hasMatch(top);
}

/// A chat app recognised by its own screen words.
class ChatApp {
  const ChatApp(this.label, this.brands, this.phrases, [this.pattern]);
  final String label;

  /// The app's name appearing on screen (whole word).
  final List<String> brands;

  /// Things only (or mostly) this app prints, e.g. WhatsApp's
  /// "This message was deleted".
  final List<String> phrases;

  /// Repeated marks, e.g. WhatsApp's ✓✓ after each time (OCR reads "W", "V/").
  final RegExp? pattern;
}

final chatApps = [
  ChatApp('WhatsApp chats', ['whatsapp'], [
    'this message was deleted', 'you deleted this message', 'last seen', 'tap here for contact info',
    'end-to-end encrypted', 'missed voice call', 'missed video call', 'view once', 'waiting for this message',
    'forwarded many times', 'typing...', 'you reacted', 'business chat', 'type a message', '\nonline\n',
    ' online\n', // a group's header: "3 online"
  ], RegExp(r"\b(?:[01]?\d|2[0-3])[:.][0-5]\d\s?(?:am|pm)?\s?(?:w|vv|v'?/|u)(?=\s|$)", multiLine: true)),
  // Instagram's message box says "Message..." on its own line; LinkedIn's
  // says "Write a message...", so the line start matters.
  const ChatApp('Instagram DMs', ['instagram'], [
    '\nmessage...', 'active now', 'sent a reel', 'sent a post', 'replied to your story', 'reacted to your story',
    'mentioned you in their story', 'liked a message', 'you replied to', 'sent an attachment',
  ]),
  const ChatApp('LinkedIn messages', ['linkedin'],
      ['write a message...', "you haven't connected with", '(he/him)', '(she/her)', 'mobile •', 'inmail']),
  const ChatApp('Telegram chats', ['telegram'],
      ['last seen recently', 'last seen within a week', 'last seen a long time ago', 'pinned message']),
  const ChatApp('Snapchat chats', ['snapchat'], ['send a chat', 'new chat', 'tap to chat', 'tap to view', 'took a screenshot']),
  const ChatApp('Messenger chats', ['messenger'], ["you're now connected", 'you can now message and call']),
  const ChatApp('Discord chats', ['discord'], ['@everyone', '@here', 'message #']),
  const ChatApp('Text messages', ['imessage', 'rcs', 'sms'], ['text message', 'chat with', 'send sms', '\ndelivered\n']),
  const ChatApp('AI chats', ['chatgpt', 'gemini', 'claude', 'copilot', 'perplexity', 'meta ai', 'deepseek'],
      ['ask gemini', 'message chatgpt', 'ask anything', 'can make mistakes']),
];

// Screens with many times that are NOT chats.
const _notChat = [
  'inbox', 'reply all', 'unsubscribe', 'cc:', // emails
  'pnr', 'passenger', 'boarding', 'seats', 'train', // bookings
  'wi-fi', 'bluetooth', 'notifications', // notification shade
];

Verdict? _chat(String text) {
  // Message times, without the status-bar clock at the very top.
  final body = text.length > 30 ? text.substring(30) : '';
  final times = _clock.allMatches(body).length;

  // The app's own signs count; its name alone doesn't (a page can mention
  // Instagram or ChatGPT without being a chat).
  ChatApp? app;
  var signs = 0, appRank = 0;
  final appFound = <String>[];
  for (final a in chatApps) {
    final hasBrand = a.brands.any((w) => RegExp('\\b${RegExp.escape(w)}\\b').hasMatch(text));
    final phrases = a.phrases.where(text.contains).toList();
    final marks = a.pattern?.allMatches(text).length ?? 0;
    final s = phrases.length + (marks >= 2 ? 1 : 0);
    final rank = 2 * s + (hasBrand ? 1 : 0);
    if (s > 0 && rank > appRank) {
      app = a;
      signs = s;
      appRank = rank;
      appFound
        ..clear()
        ..addAll(phrases.take(3).map((w) => '"${w.trim()}"'))
        ..addAll([if (marks >= 2) '$marks read ticks ✓✓']);
    }
  }
  final notChat = _any(text, _notChat);

  final evidence = {
    if (app != null) 'App': app.label,
    if (appFound.isNotEmpty) 'Chat signs found': appFound.join(', '),
    'Message times found': '$times',
  };
  Verdict v(double c, List<String> reasons) =>
      Verdict(JunkCategory.chatScreenshot, c, reasons, label: app?.label ?? 'Other chats', evidence: evidence);
  final screen = app == null ? '' : 'Looks like a ${app.label.replaceAll(RegExp(r's$'), '')} screen';

  // Two of an app's own signs, or one plus message times: sure.
  if (app != null && signs >= 2 && (times >= 1 || !notChat)) {
    return v(0.93, [screen, if (times >= 2) '$times message times']);
  }
  if (app != null && signs >= 1 && times >= 2 && !notChat) return v(0.9, [screen, '$times message times']);
  if (app != null && !notChat) return v(0.7, [screen]);
  // Many message times and chat words, but no app recognised: shown, never pre-ticked.
  if (!notChat && times >= 5 && _any(text, const ['type a message', 'online', 'typing', 'delivered', '\nyou\n', 'reply'])) {
    return v(0.7, ['$times message times']);
  }
  return null;
}
