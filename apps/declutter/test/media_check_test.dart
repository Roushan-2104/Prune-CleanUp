import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:declutter/review_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('real audio and video headers are recognised', () {
    expect(looksLikeMedia([0, 0, 0, 0x20, ...ascii.encode('ftypisom')]), isTrue, reason: 'MP4');
    expect(looksLikeMedia([0x1A, 0x45, 0xDF, 0xA3, 1]), isTrue, reason: 'WebM / MKV');
    expect(looksLikeMedia(ascii.encode('OggS\x00\x02')), isTrue, reason: 'WhatsApp voice note (Opus)');
    expect(looksLikeMedia(ascii.encode('ID3\x04')), isTrue, reason: 'MP3');
    expect(looksLikeMedia([0xFF, 0xFB, 0x90]), isTrue, reason: 'MP3 frame');
    expect(looksLikeMedia(ascii.encode('#!AMR\n')), isTrue, reason: 'AMR call recording');
    expect(looksLikeMedia(ascii.encode('RIFF....AVI ')), isTrue, reason: 'AVI / WAV');
  });

  test('text pretending to be a video is never played', () {
    expect(looksLikeMedia(ascii.encode('#EXTM3U\nhttp://example.com/beacon.ts\n')), isFalse, reason: 'HLS playlist');
    expect(looksLikeMedia(ascii.encode('<?xml version="1.0"?><MPD')), isFalse, reason: 'DASH manifest');
    expect(looksLikeMedia(ascii.encode('ffconcat version 1.0\nfile C:/x')), isFalse, reason: 'concat list');
    expect(looksLikeMedia(ascii.encode('[playlist]\nFile1=http://x')), isFalse, reason: 'PLS playlist');
    expect(looksLikeMedia(const []), isFalse);
  });

  test('only document types get a Windows-drawn preview', () {
    for (final ok in ['Report.pdf', 'app.APK', 'notes.docx', 'sheet.xlsx', 'deck.pptx', 'readme.txt']) {
      expect(hasDocumentPreview(ok), isTrue, reason: ok);
    }
    // Drawing these can make Windows contact a server named inside the file.
    for (final risky in ['invoice.pdf.lnk', 'link.url', 'x.library-ms', 'x.searchConnector-ms', 'x.scf', 'setup.exe',
        'page.html', 'no-extension']) {
      expect(hasDocumentPreview(risky), isFalse, reason: risky);
    }
  });

  test('unpacking stops at the size the zip claims', () {
    final icon = List.generate(5000, (i) => i % 251);
    final packed = ZLibEncoder(raw: true).convert(icon);
    expect(inflateAtMost(packed, icon.length), icon, reason: 'a real icon unpacks');

    // 50 MB of zeros packs into about 50 KB: a "zip bomb" claiming to be a small icon.
    final bomb = ZLibEncoder(raw: true).convert(Uint8List(50 << 20));
    expect(inflateAtMost(bomb, 2 << 20), isNull);
    expect(inflateAtMost([1, 2, 3, 4], 100) ?? const [], isEmpty, reason: 'not deflate data: nothing comes out');
  });
}
