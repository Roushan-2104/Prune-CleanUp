import 'verdict.dart';

/// Classifies a screenshot from the text OCR found on it.
///
/// Rules are deliberately strict: a category only reaches "sure" when several
/// independent signals agree (e.g. an amount AND a UPI reference AND a
/// success message).
Verdict classifyScreenshotText(String rawText) {
  final text = _normalize(rawText);

  final otp = _otp(text);
  if (otp != null && otp.tier == Tier.sure) return otp;

  // Payment receipts and UPI chat threads (GPay/PhonePe) are full of times
  // like "10:42 pm", so they look like chats too. Any real payment evidence
  // wins over chat evidence.
  final payment = _payment(text);
  if (payment != null) return payment;

  final candidates = [otp, _chat(text)].nonNulls.toList()
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
  if (candidates.isNotEmpty) return candidates.first;

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
  ScreenshotKind('Instagram / Reels', ['instagram', 'reels', 'reel'],
      ['liked by', 'follow', 'followers', 'following', 'view all comments', 'add comment', 'story', 'original audio', 'sponsored']),
  ScreenshotKind('YouTube / videos', ['youtube', 'shorts'],
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

bool _hasAmount(String text) => _amount.hasMatch(text) || _amountAfter.hasMatch(text);

// Short status words UPI apps print under each payment ("Paid · 10:42 pm").
final _paymentStatusWord = RegExp(r'\b(?:paid|received|sent|debited|credited|refunded)\b');

const _paymentSuccess = [
  // India
  'paid to', 'payment successful', 'paid successfully', 'transaction successful',
  'money sent', 'sent successfully', 'received from', 'payment received',
  'debited from', 'credited to', 'transfer successful',
  // Worldwide
  'you sent', 'you paid', 'you received', 'payment sent', 'payment complete', 'payment confirmed',
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

Verdict? _payment(String text) {
  final hasAmount = _hasAmount(text);
  final hasSuccess = _any(text, _paymentSuccess);
  final hasStatus = _paymentStatusWord.hasMatch(text);
  final hasId = _any(text, _paymentIds);
  final hasApp = _anyWord(text, _paymentApps);

  final reasons = <String>[
    if (hasAmount) 'Shows an amount',
    if (hasSuccess) 'Says payment was made'
    else if (hasStatus) 'Has payment status like "Paid"',
    if (hasId) 'Has a transaction reference',
    if (hasApp) 'Mentions a payment app',
  ];

  final amountText = (_amount.firstMatch(text) ?? _amountAfter.firstMatch(text))?.group(0)?.trim();
  final evidence = {
    if (amountText != null) 'Amount found': amountText,
    'Words found': _quoted([..._paymentSuccess, ..._paymentIds].where(text.contains).take(3)),
    if (hasApp) 'App': _paymentApps.firstWhere((w) => RegExp('\\b${RegExp.escape(w)}\\b').hasMatch(text)),
  };

  double confidence;
  if (hasAmount && hasSuccess && hasId) {
    confidence = 0.97;
  } else if (hasAmount && (hasSuccess || hasId) && hasApp) {
    confidence = 0.92;
  } else if (hasAmount && (hasSuccess || hasId)) {
    confidence = 0.8;
  } else if (hasAmount && hasStatus) {
    confidence = 0.75;
  } else if (reasons.length >= 2) {
    confidence = 0.6;
  } else {
    return null;
  }
  return Verdict(JunkCategory.paymentScreenshot, confidence, reasons, evidence: evidence);
}

/// ["paid to", "utr"] → '"paid to", "utr"' (or "—" when empty).
String _quoted(Iterable<String> words) => words.isEmpty ? '—' : words.map((w) => '"$w"').join(', ');

const _otpWords = [
  'otp', 'one time password', 'one-time password', 'one-time code', 'verification code', 'security code',
  'login code', 'sign-in code', 'authentication code', 'passcode', 'your code is', '2fa',
];
const _otpWarnings = [
  'do not share', "don't share", 'never share', 'valid for', 'expires in', 'expires', 'will never ask',
  "won't ask", 'did not request', "didn't request",
];

Verdict? _otp(String text) {
  if (!_any(text, _otpWords)) return null;
  final hasCode = RegExp(r'\b\d{4,8}\b|\b\d{3}[- ]\d{3}\b').hasMatch(text);
  final hasWarning = _any(text, _otpWarnings);
  final evidence = {'Words found': _quoted([..._otpWords, ..._otpWarnings].where(text.contains).take(3))};
  if (hasCode && hasWarning) {
    return Verdict(JunkCategory.otpScreenshot, 0.95,
        ['Contains a one-time password', 'OTP codes expire quickly'], evidence: evidence);
  }
  if (hasCode) {
    return Verdict(JunkCategory.otpScreenshot, 0.75, ['Contains a one-time password'], evidence: evidence);
  }
  return null;
}

// Chat apps print a time next to almost every message bubble.
final _clock = RegExp(r'\b(?:[01]?\d|2[0-3])[:.][0-5]\d\s?(?:am|pm)?\b');
const _chatUi = [
  'type a message', 'message', 'online', 'last seen', 'typing...', 'delivered',
  'seen', 'end-to-end encrypted', 'yesterday', 'today', 'reply',
  // Telegram, Discord, iMessage, Messenger, Signal…
  'write a message', 'send a message', 'active now', 'imessage', 'edited', 'forwarded', 'replied to',
];

Verdict? _chat(String text) {
  final times = _clock.allMatches(text).length;
  final hasUi = _any(text, _chatUi);
  final evidence = {
    'Message times found': '$times (e.g. ${_quoted(_clock.allMatches(text).take(2).map((m) => m.group(0)!))})',
    if (hasUi) 'Chat screen words': _quoted(_chatUi.where(text.contains).take(3)),
  };
  if (times >= 4 && hasUi) {
    return Verdict(JunkCategory.chatScreenshot, 0.92,
        ['$times message timestamps', 'Looks like a chat screen'], evidence: evidence);
  }
  if (times >= 3) {
    return Verdict(JunkCategory.chatScreenshot, 0.75, ['$times message timestamps'], evidence: evidence);
  }
  if (times >= 2 && hasUi) {
    return Verdict(JunkCategory.chatScreenshot, 0.65, ['Looks like a chat screen'], evidence: evidence);
  }
  return null;
}
