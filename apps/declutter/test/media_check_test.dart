import 'dart:convert';

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
}
