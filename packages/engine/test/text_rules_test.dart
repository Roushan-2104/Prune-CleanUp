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
