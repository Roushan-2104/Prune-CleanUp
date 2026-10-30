import 'file_rules.dart';
import 'layout.dart';
import 'photo_rules.dart';
import 'scan_cache.dart';
import 'screenshot_groups.dart';
import 'text_rules.dart';
import 'verdict.dart';

/// What the engine knows about an image before analysing it.
class ImageFacts {
  const ImageFacts({
    required this.path,
    required this.folder,
    required this.bytes,
    required this.modifiedSec,
    this.takenMs,
    this.width,
    this.height,
  });

  final String path;
  final String folder;
  final int bytes;
  final int modifiedSec;
  final int? takenMs;
  final int? width;
  final int? height;

  String get name => path.substring(path.lastIndexOf('/') + 1);
}

/// Images worth analysing: not protected, not a cache, not stickers, not a
/// Mac "._" leftover (metadata with an image's name, not an image).
bool shouldAnalyseImage(ImageFacts f) {
  final folder = f.folder.toLowerCase();
  return !isProtected(f.folder) &&
      !f.name.startsWith('._') &&
      !folder.contains('.thumbnails/') &&
      !folder.contains('/.statuses/') &&
      !folder.contains('stickers') && // incl. "WhatsApp Backup Excluded Stickers"
      f.bytes >= 2 * 1024;
}

/// Taken with the phone's screenshot button.
bool isScreenshotByPlace(ImageFacts f) {
  final p = '${f.folder}${f.name}'.toLowerCase();
  return p.contains('screenshot');
}

/// Phone screens are much taller than camera photos (≈ 20:9 vs 4:3, 16:9).
bool isPhoneScreenShaped(int? w, int? h) {
  if (w == null || h == null || w <= 0 || h <= 0) return false;
  final long = w > h ? w : h, short = w > h ? h : w;
  return long / short >= 1.9;
}

/// Could be a screenshot that arrived another way (WhatsApp, saved from an
/// app, downloaded): worth reading its text to decide.
bool mightBeScreenshot(ImageFacts f) {
  if (isScreenshotByPlace(f)) return true;
  final folder = f.folder.toLowerCase();
  if (folder.contains('dcim/camera')) return false;
  return isPhoneScreenShaped(f.width, f.height) ||
      const ['whatsapp', 'telegram', 'instagram', 'download', 'snapchat', 'facebook', 'pictures/']
          .any(folder.contains);
}

/// After reading its text: is this image really a screenshot? Lots of text
/// alone isn't enough — photos of posters, notes and certificates have that
/// too. It needs the screenshot folder, a phone-screen shape, the phone's
/// status bar, or an app screen the rules recognise (receipt, chat, OTP).
bool looksLikeScreenshot(ImageFacts f, String? text, {int? width, int? height}) =>
    screenshotVerdict(f, text, width: width, height: height) != null;

/// What a screenshot shows, or null when the image isn't one. Reads the text
/// once for both questions (it used to be read twice per image).
Verdict? screenshotVerdict(ImageFacts f, String? text, {int? width, int? height}) {
  final byShape = isScreenshotByPlace(f) || isPhoneScreenShaped(f.width ?? width, f.height ?? height);
  if (!byShape && (text == null || text.trim().isEmpty)) return null;
  final v = classifyScreenshotText(text ?? '');
  if (byShape || hasStatusBar(text!) || v.category != JunkCategory.otherScreenshot) return v;
  return null;
}

/// Judges analysed images: screenshot categories, blurry photos, and
/// similar/identical photos (the sharpest copy is kept).
///
/// Screenshots are then grouped by who a chat is with and by the app or
/// site a screen shows ([groupScreenshots]); [installedPackages] (the
/// phone's app list) helps name apps.
Map<String, FileVerdict> judgeImages(Map<String, Analysis> analyses, Map<String, ImageFacts> facts,
    {Iterable<String> installedPackages = const []}) {
  final out = <String, FileVerdict>{};
  final fingerprints = <PhotoFingerprint>[];
  final shots = <String, (Verdict, String)>{};
  final layouts = <String, List<LineBox>>{}; // where each screenshot's lines sit, when known

  for (final MapEntry(key: path, value: a) in analyses.entries) {
    final f = facts[path];
    if (f == null || !shouldAnalyseImage(f)) continue;

    // Decided again from the saved text, so better rules apply without
    // copying anything from the phone again.
    final read = a.text != null
        ? screenshotVerdict(f, a.text)
        : (a.screenshot ? classifyScreenshotText('') : null);
    if (read != null) {
      var v = read;
      if (!isScreenshotByPlace(f)) v = Verdict(v.category, v.confidence,
          ['Screenshot saved or received from another app', ...v.reasons], label: v.label, evidence: v.evidence);
      shots[path] = (v, a.text ?? '');
      if (a.boxes case final b? when b.isNotEmpty) layouts[path] = decodeBoxes(b);
      continue;
    }
    if (a.dHash == null || a.sharpness == null || a.entropy == null) continue;

    fingerprints.add(PhotoFingerprint(
      id: path,
      takenAt: DateTime.fromMillisecondsSinceEpoch(a.takenAtMs),
      dHash: a.dHash!,
      sharpness: a.sharpness!,
      bytes: a.bytes,
      contentHash: f.width != null ? '${f.width}x${f.height}:${a.bytes}:${a.dHash}' : null,
      entropy: a.entropy!,
      landscape: a.landscape ?? false,
    ));

    // No face check yet (or it failed)? Assume there are people: never "sure".
    final blur = classifyBlurMetrics(sharpness: a.sharpness!, entropy: a.entropy!, faceCount: a.faceCount ?? 1);
    if (blur != null) out[path] = FileVerdict(blur);
  }

  for (final MapEntry(key: path, value: v)
      in groupScreenshots(shots, installedPackages: installedPackages, layouts: layouts).entries) {
    out[path] = FileVerdict(v);
  }

  // Look-alikes win over blur: "keep the best copy" is easier to trust.
  for (final group in findDuplicates(fingerprints)) {
    for (final MapEntry(key: fp, value: v) in group.others.entries) {
      out[fp.id] = FileVerdict(v, matchPath: group.keep.id);
    }
  }
  return out;
}

/// Combines file-level and image-level suggestions for one phone.
///
/// Priority: a byte-identical copy (fingerprint-confirmed) beats everything;
/// then what the image itself shows (payment screenshot, blurry, similar)
/// beats where it is (e.g. "WhatsApp sent copy"), because it's more specific.
Map<String, FileVerdict> mergeSuggestions(Map<String, FileVerdict> fileLevel, Map<String, FileVerdict> imageLevel) {
  final out = {...fileLevel};
  for (final MapEntry(key: path, value: v) in imageLevel.entries) {
    final existing = out[path];
    if (existing?.verdict.category == JunkCategory.exactDuplicate) continue;
    out[path] = v;
  }
  return out;
}
