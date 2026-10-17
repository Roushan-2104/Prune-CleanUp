import 'dart:math' as math;
import 'dart:typed_data';

/// A small grayscale image (one byte per pixel, row-major).
/// The scanner builds these from ~256px gallery thumbnails, so every metric
/// here runs in a few milliseconds per photo.
class GrayImage {
  GrayImage(this.width, this.height, this.pixels)
      : assert(pixels.length == width * height);

  final int width;
  final int height;
  final Uint8List pixels;

  int at(int x, int y) => pixels[y * width + x];
}

/// Variance of the Laplacian over a region: high = sharp edges, low = blurry.
double laplacianVariance(GrayImage img, {int x0 = 0, int y0 = 0, int? x1, int? y1}) {
  x1 ??= img.width;
  y1 ??= img.height;
  var sum = 0.0, sumSq = 0.0, n = 0;
  for (var y = math.max(y0, 1); y < math.min(y1, img.height - 1); y++) {
    for (var x = math.max(x0, 1); x < math.min(x1, img.width - 1); x++) {
      final l = img.at(x - 1, y) + img.at(x + 1, y) + img.at(x, y - 1) +
          img.at(x, y + 1) - 4 * img.at(x, y);
      sum += l;
      sumSq += l * l;
      n++;
    }
  }
  if (n == 0) return 0;
  final mean = sum / n;
  return sumSq / n - mean * mean;
}

/// Sharpness of the sharpest tile in a 3x3 grid.
///
/// Using the *best* tile instead of the whole image means a portrait with a
/// sharp face and a deliberately blurred background is NOT called blurry.
double bestTileSharpness(GrayImage img) {
  var best = 0.0;
  for (var ty = 0; ty < 3; ty++) {
    for (var tx = 0; tx < 3; tx++) {
      final v = laplacianVariance(img,
          x0: img.width * tx ~/ 3, x1: img.width * (tx + 1) ~/ 3,
          y0: img.height * ty ~/ 3, y1: img.height * (ty + 1) ~/ 3);
      best = math.max(best, v);
    }
  }
  return best;
}

double meanBrightness(GrayImage img) {
  var sum = 0;
  for (final p in img.pixels) {
    sum += p;
  }
  return sum / img.pixels.length;
}

/// Shannon entropy of the brightness histogram (0–8 bits).
/// Near-zero means a flat image: a black pocket shot, a plain wall, etc.
double entropy(GrayImage img) {
  final hist = List<int>.filled(256, 0);
  for (final p in img.pixels) {
    hist[p]++;
  }
  final n = img.pixels.length;
  var e = 0.0;
  for (final c in hist) {
    if (c == 0) continue;
    final p = c / n;
    e -= p * math.log(p) / math.ln2;
  }
  return e;
}

/// 64-bit difference hash. Visually similar photos get hashes that differ in
/// only a few bits, even after resizing or re-compression.
int dHash(GrayImage img) {
  final small = _resizeBox(img, 9, 8);
  var hash = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      hash = (hash << 1) | (small[y * 9 + x] < small[y * 9 + x + 1] ? 1 : 0);
    }
  }
  return hash;
}

int hammingDistance(int a, int b) {
  var v = a ^ b, count = 0;
  while (v != 0) {
    v &= v - 1;
    count++;
  }
  return count;
}

/// Area-average downscale to [w]x[h].
List<double> _resizeBox(GrayImage img, int w, int h) {
  final out = List<double>.filled(w * h, 0);
  for (var oy = 0; oy < h; oy++) {
    final ys = oy * img.height ~/ h, ye = math.max(ys + 1, (oy + 1) * img.height ~/ h);
    for (var ox = 0; ox < w; ox++) {
      final xs = ox * img.width ~/ w, xe = math.max(xs + 1, (ox + 1) * img.width ~/ w);
      var sum = 0, n = 0;
      for (var y = ys; y < ye; y++) {
        for (var x = xs; x < xe; x++) {
          sum += img.at(x, y);
          n++;
        }
      }
      out[oy * w + ox] = sum / n;
    }
  }
  return out;
}
