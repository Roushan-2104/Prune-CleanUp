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
          'Instagram');
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

  group('chats are told apart by app', () {
    test('WhatsApp: read ticks after each time (OCR reads ✓✓ as "W", "V/")', () {
      const text = '22:26\nNikhil\nYou\nKal milte hain\n22:23\n22:24 w\nTheek hai\n22:24 W\nOk bye 22:25 V/';
      final v = classifyScreenshotText(text);
      expect(v.category, JunkCategory.chatScreenshot);
      expect(v.label, 'WhatsApp chats');
    });
    test('Instagram DM', () {
      const text = '10:12\nalex.k\nActive now\nReplied to your story\nhaha nice\nMessage...';
      expect(classifyScreenshotText(text).label, 'Instagram DMs');
    });
    test("LinkedIn's \"Write a message...\" is not an Instagram DM", () {
      const text = '21:03\nMeera Iyer\nMobile • 6m ago\nMeera Iyer (She/Her) • 8:43 PM\nThanks for connecting!\n'
          'You • 8:50 PM\nSure\nWrite a message...';
      expect(classifyScreenshotText(text).label, 'LinkedIn messages');
    });
    test('a page that only mentions an app is not a chat', () {
      const text = '15:24\nReels\n7 videos on building an AI startup\nFrom Stanford, Sequoia and ChatGPT creators\n'
          'Follow for more on Instagram';
      expect(classifyScreenshotText(text).category, isNot(JunkCategory.chatScreenshot));
    });
    test('notification shade with several times is not a chat', () {
      const text = '20:42 Sun, 10 Aug\nWi-Fi\nBluetooth\nOff\nInstagram • now\nSale ends 6 hrs left 20:41\n'
          'Calendar 19:00\nReminder 19:30';
      expect(classifyScreenshotText(text).category, isNot(JunkCategory.chatScreenshot));
    });
    test('a train booking page is not a chat', () {
      const text = '10:21\nNDLS - Agra\n18:50 Fri, 12 Mar\n23:00 Sat, 13 Mar\nFew Seats\n07:30 PNR\nPassenger details';
      expect(classifyScreenshotText(text).category, isNot(JunkCategory.chatScreenshot));
    });
  });

  group('payments need proof', () {
    test('OCR turns ₹ into "?" and zeros into "O": still a receipt', () {
      const text = 'QIOO.OO\nPaid to\nAMIT SINGH\nPhonePe • 9876543210@ybl\n24 December 2025, 9:50 pm';
      final v = classifyScreenshotText(text);
      expect(v.category, JunkCategory.paymentScreenshot);
      expect(v.tier, Tier.sure);
      expect(v.label, 'PhonePe payments');
    });
    test('"Payment Successful" with a UPI ID but an unreadable amount is still sure', () {
      const text = '19:30\nPayment Successful\n22 February 2026 at 07:30 PM\nTiffin Corner\n9000000001@okbizaxis\n'
          'View Details\nDone\nShare Receipt';
      final v = classifyScreenshotText(text);
      expect(v.category, JunkCategory.paymentScreenshot);
      expect(v.tier, Tier.sure);
      expect(v.label, 'UPI payments');
    });
    test('a shop\'s "Scan & Pay" QR code is not a receipt', () {
      const text = 'PhonePe\nACCEPTED HERE\nScan & Pay Using PhonePe App\nSample Stores\nshop123@ybl';
      final v = classifyScreenshotText(text);
      expect(v.category, JunkCategory.otherScreenshot);
      expect(v.label, 'Payment QR codes');
    });
    test('a checkout page is not a receipt', () {
      const text = '17:07\nSubtotal\nRoll on Deo\nQty: 1\nShipping\nTo Pay ₹745\nUPI\nG Pay\nAmazon Pay\nPay now';
      expect(classifyScreenshotText(text).category, isNot(JunkCategory.paymentScreenshot));
    });
    test('an email footer "You received this message" is not a payment', () {
      const text = '2:19 PM\nImran\nOct 23, 2025\nPlease share how to enroll ₹500\n'
          'You received this message because you are subscribed';
      expect(classifyScreenshotText(text).category, isNot(JunkCategory.paymentScreenshot));
    });
  });

  group('status bar', () {
    test('clock at the very top', () => expect(hasStatusBar('17:50 0 @ m\nAdmissions 2025\nDear Candidate'), isTrue));
    test('battery and clock on the first line', () => expect(hasStatusBar('LTE 64% 10:21\nTrain list'), isTrue));
    test('a poster with a time in the middle has none',
        () => expect(hasStatusBar('THE PLAY\nfrom the world of\nSherlock Holmes\n10 SEPTEMBER 6:30 PM'), isFalse));
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

  test('codes (OTPs) are just other screenshots now, never pre-ticked', () {
    final v = classifyScreenshotText('483920 is your OTP for login. Valid for 10 minutes. Do not share it with anyone.');
    expect(v.category, JunkCategory.otherScreenshot);
    expect(v.tier, isNot(Tier.sure));
  });

  test('screenshot with no clues is only a "maybe"', () {
    final v = classifyScreenshotText('Some article text about cricket');
    expect(v.category, JunkCategory.otherScreenshot);
    expect(v.tier, Tier.maybe);
  });
}
