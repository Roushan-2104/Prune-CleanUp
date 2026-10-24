import 'package:test/test.dart';
import 'package:declutter_engine/src/text_rules.dart';
import 'package:declutter_engine/src/verdict.dart';

void main() {
  group('payment screenshots', () {
    test('PhonePe receipt is sure', () {
      const text = '''
Transaction Successful
12:41 pm on 14 Oct 2026
Paid to
Swiggy Limited
₹250
Transaction ID
T2610141241123456
UTR: 428712345678
Debited from XXXX1234''';
      final v = classifyScreenshotText(text);
      expect(v.category, JunkCategory.paymentScreenshot);
      expect(v.tier, Tier.sure);
    });

    test('OCR reading ₹ as "Rs" still works', () {
      final v = classifyScreenshotText('Payment successful\nRs 1,200.50\nUPI Ref No 123456789012\nGoogle Pay');
      expect(v.category, JunkCategory.paymentScreenshot);
      expect(v.tier, Tier.sure);
    });

    test('a price in a shopping screenshot is not called a payment', () {
      final v = classifyScreenshotText('Nike Air Max\n₹7,999\nAdd to cart\nFree delivery');
      expect(v.category, isNot(JunkCategory.paymentScreenshot));
    });

    test('shows the words it found as evidence', () {
      final v = classifyScreenshotText('Payment successful\nPaid to Swiggy\n₹250\nUPI Ref 4287');
      expect(v.evidence['Amount found'], '₹250');
      expect(v.evidence['Words found'], contains('"paid to"'));
    });

    test('extracts amount and payee', () {
      final info = extractPaymentInfo('Paid to\nSample Kirana Store\n₹1,250.00\nUPI Ref 12345');
      expect(info.amount, 1250.0);
      expect(info.payee, 'Sample Kirana Store');
    });
  });

  group('payment vs chat', () {
    test('GPay chat thread with many times is a payment, not a chat', () {
      const text = '''
Nikhil Sharma
+91 98765 43210
₹500
Paid · 10:12 pm
₹200
Received · 9:30 am
₹1,000
Paid · 8:05 pm
Today
Pay   Request   Message''';
      expect(classifyScreenshotText(text).category, JunkCategory.paymentScreenshot);
    });

    test('receipt where OCR read ₹ as % is still a payment', () {
      final v = classifyScreenshotText(
          'Paid to\nBlinkit\n%349\n10:41 pm\nUPI transaction ID 51234\nToday');
      expect(v.category, JunkCategory.paymentScreenshot);
      expect(v.tier, Tier.sure);
    });

    test('"credited" does not count as the CRED app', () {
      final v = classifyScreenshotText('Salary credited\nhello how are you');
      expect(v.category, isNot(JunkCategory.paymentScreenshot));
    });
  });

  group('other screenshot labels', () {
    test('Instagram reel', () {
      expect(classifyScreenshotText('nikhil.k_ Follow\nOriginal audio\nLiked by meera and 2,304 others').label,
          'Instagram / Reels');
    });
    test('shopping page', () {
      expect(classifyScreenshotText('Nike Air Max\n₹7,999\nAdd to cart\nFree delivery').label, 'Shopping');
    });
    test('train ticket is labelled and never pre-selected', () {
      final v = classifyScreenshotText('IRCTC\nPNR 4521236587\nCoach S4 Seat 32\nDeparture 06:15');
      expect(v.label, 'Tickets & bookings');
      expect(v.tier, isNot(Tier.sure));
    });
    test('phone settings', () {
      expect(classifyScreenshotText('Settings\nWi-Fi\nBluetooth\nBattery 82%').label,
          'Phone settings & home screen');
    });
    test('almost no text = picture or meme', () {
      expect(classifyScreenshotText('lol').label, 'Pictures & memes');
    });
  });

  group('worldwide payments', () {
    void sure(String name, String text) => test(name, () {
          final v = classifyScreenshotText(text);
          expect(v.category, JunkCategory.paymentScreenshot, reason: v.toString());
          expect(v.tier, Tier.sure, reason: v.toString());
        });

    sure('PayPal (US)', 'PayPal\nYou sent \$25.00 USD to John Smith\nTransaction ID\n3AB12345CD678901E');
    sure('Venmo', 'Venmo\nYou paid Sarah Lee\n\$12.50\nPayment ID 3891776\nToday at 9:41 PM');
    sure('Revolut (euro after the number)', 'Revolut\n45,20 €\nPayment completed\nReference: Dinner');
    sure('UK bank transfer (£)', 'Monzo\n£120.00\nPayment sent to Tom\nReference number 88271');
    sure('Cash App', 'Cash App\nYou sent \$40\nto \$jsmith\nTransaction number #D-7G2K');
    sure('GCash (₱)', 'GCash\nYou sent ₱1,500.00\nRef No. 0012 345 678901\nTransfer complete');

    test('a shopping page with a price is not a payment', () {
      expect(classifyScreenshotText('Wireless earbuds\n\$79.99\nAdd to cart\nFree shipping').category,
          isNot(JunkCategory.paymentScreenshot));
    });
    test('a news headline with money is not a payment', () {
      expect(classifyScreenshotText('Markets today\nStocks fell 5% as oil rose to \$120 a barrel\nRead more').category,
          isNot(JunkCategory.paymentScreenshot));
    });
    test('"wise" in a sentence alone does not make a payment', () {
      expect(classifyScreenshotText('That was a wise decision my friend').category,
          isNot(JunkCategory.paymentScreenshot));
    });
  });

  group('worldwide verification codes', () {
    test('Microsoft-style 123-456 security code', () {
      final v = classifyScreenshotText('Your security code is 482-913. Never share this code with anyone.');
      expect(v.category, JunkCategory.otpScreenshot);
      expect(v.tier, Tier.sure);
    });
    test('login code that expires', () {
      final v = classifyScreenshotText('Instagram login code: 551204. It expires in 10 minutes.');
      expect(v.category, JunkCategory.otpScreenshot);
      expect(v.tier, Tier.sure);
    });
  });

  group('worldwide chats', () {
    test('Telegram with 24-hour times', () {
      const text = 'Alex\nlast seen recently\nAre we still on for tonight? 21:04\nYes! 21:05\n'
          'See you at 8 21:05\nGreat 21:07\nWrite a message…';
      final v = classifyScreenshotText(text);
      expect(v.category, JunkCategory.chatScreenshot);
      expect(v.tier, Tier.sure);
    });
    test('iMessage', () {
      const text = 'iMessage\nToday 9:41 AM\nRunning late\nDelivered\nOk no worries 9:43 AM\nThanks 9:44 AM\n9:50 AM';
      expect(classifyScreenshotText(text).category, JunkCategory.chatScreenshot);
    });
  });

  group('chat screenshots', () {
    test('WhatsApp chat is sure', () {
      const text = '''
Nikhil
online
Bhai kal aa raha hai? 10:12 pm
Haan 10:13 pm
Kitne baje 10:13 pm
Shaam ko 10:15 pm
Type a message''';
      final v = classifyScreenshotText(text);
      expect(v.category, JunkCategory.chatScreenshot);
      expect(v.tier, Tier.sure);
    });

    test('single time on a screen is not a chat', () {
      final v = classifyScreenshotText('Weather\n10:42\n28°C Sunny\nNew Delhi');
      expect(v.category, JunkCategory.otherScreenshot);
    });
  });

  test('OTP screenshot', () {
    final v = classifyScreenshotText('483920 is your OTP for login. Valid for 10 minutes. Do not share it with anyone.');
    expect(v.category, JunkCategory.otpScreenshot);
    expect(v.tier, Tier.sure);
  });

  test('screenshot with no clues is only a "maybe"', () {
    final v = classifyScreenshotText('Some article text about cricket');
    expect(v.category, JunkCategory.otherScreenshot);
    expect(v.tier, Tier.maybe);
  });
}
