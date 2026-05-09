import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:logger/logger.dart';

/// Maintains a rolling buffer of camera frames and selects the sharpest one
/// using Laplacian variance (focus measure) at the moment of speech end.
///
/// Key performance decisions for low-RAM devices (Snapdragon 662, 3.7GB):
/// - addFrame throttled to 5fps to prevent GC pressure from large allocations
/// - Sharpness scoring is synchronous (no async microtask overhead)
/// - YUV→RGB→JPEG conversion runs in a compute() isolate, off the main thread
class FrameSelector {
  FrameSelector({this.bufferSize = 10});

  final int bufferSize;
  final _log = Logger();
  final List<_BufferedFrame> _buffer = [];
  DateTime _lastFrameTime = DateTime(0);

  /// Add a new frame to the rolling buffer.
  /// Throttled to 5fps max — we only need sharpness ranking across ~2s of
  /// speech. Storing every frame at 30fps causes severe GC pressure.
  void addFrame(CameraImage cameraImage) {
    final now = DateTime.now();
    if (now.difference(_lastFrameTime).inMilliseconds < 200) return;
    _lastFrameTime = now;

    if (_buffer.length >= bufferSize) {
      _buffer.removeAt(0);
    }
    _buffer.add(_BufferedFrame(
      cameraImage: cameraImage,
      timestamp: now,
    ));
  }

  /// Returns JPEG bytes of the sharpest frame in the buffer.
  /// Sharpness scoring is sync. JPEG conversion runs in a compute() isolate.
  /// Returns null if buffer is empty.
  Future<Uint8List?> selectSharpestFrame() async {
    if (_buffer.isEmpty) {
      _log.w('Frame buffer empty — cannot select frame');
      return null;
    }

    _BufferedFrame? best;
    double bestScore = -1;

    for (final frame in _buffer) {
      final score = _laplacianVariance(frame.cameraImage);
      if (score > bestScore) {
        bestScore = score;
        best = frame;
      }
    }

    if (best == null) return null;

    _log.i('Selected frame sharpness=${bestScore.toStringAsFixed(2)}, '
        'age=${DateTime.now().difference(best.timestamp).inMilliseconds}ms');

    // YUV→RGB→JPEG is O(width×height) — runs in isolate to avoid blocking UI.
    // Must copy plane bytes before passing to isolate (CameraImage not sendable).
    return compute(_convertToJpeg, _FrameData(
      width: best.cameraImage.width,
      height: best.cameraImage.height,
      yBytes: Uint8List.fromList(best.cameraImage.planes[0].bytes),
      uBytes: Uint8List.fromList(best.cameraImage.planes[1].bytes),
      vBytes: Uint8List.fromList(best.cameraImage.planes[2].bytes),
    ));
  }

  /// Laplacian variance as sharpness measure — sync, step=8.
  /// Samples ~3600 pixels on 480p vs ~19000 at step=4.
  /// Sufficient for relative ranking; we only need the best frame, not
  /// an absolute sharpness value.
  double _laplacianVariance(CameraImage cameraImage) {
    final gray = _yuv420ToGray(cameraImage);
    if (gray == null) return 0;

    final w = cameraImage.width;
    final h = cameraImage.height;
    const step = 8;
    double sum = 0;
    double sumSq = 0;
    int count = 0;

    for (int y = step; y < h - step; y += step) {
      for (int x = step; x < w - step; x += step) {
        final lap = -4.0 * gray[y * w + x] +
            gray[(y - step) * w + x] +
            gray[(y + step) * w + x] +
            gray[y * w + (x - step)] +
            gray[y * w + (x + step)];
        sum += lap;
        sumSq += lap * lap;
        count++;
      }
    }

    if (count == 0) return 0;
    final mean = sum / count;
    return (sumSq / count) - (mean * mean);
  }

  /// Y plane of YUV420 is raw grayscale — no conversion needed.
  Uint8List? _yuv420ToGray(CameraImage image) {
    if (image.planes.isEmpty) return null;
    return image.planes[0].bytes;
  }

  void clear() => _buffer.clear();
}

// ── Isolate-safe data class ───────────────────────────────────────────────────
// CameraImage cannot be sent across isolates — plane bytes must be copied first.
class _FrameData {
  final int width;
  final int height;
  final Uint8List yBytes;
  final Uint8List uBytes;
  final Uint8List vBytes;

  _FrameData({
    required this.width,
    required this.height,
    required this.yBytes,
    required this.uBytes,
    required this.vBytes,
  });
}

// ── Top-level function required by compute() ──────────────────────────────────
Uint8List _convertToJpeg(_FrameData d) {
  final rgbImg = img.Image(width: d.width, height: d.height);

  for (int y = 0; y < d.height; y++) {
    for (int x = 0; x < d.width; x++) {
      final yVal = d.yBytes[y * d.width + x];
      final uvIdx = (y ~/ 2) * (d.width ~/ 2) + (x ~/ 2);
      final u = d.uBytes.length > uvIdx ? d.uBytes[uvIdx] - 128 : 0;
      final v = d.vBytes.length > uvIdx ? d.vBytes[uvIdx] - 128 : 0;

      final r = (yVal + 1.402 * v).clamp(0, 255).toInt();
      final g = (yVal - 0.344136 * u - 0.714136 * v).clamp(0, 255).toInt();
      final b = (yVal + 1.772 * u).clamp(0, 255).toInt();

      rgbImg.setPixelRgb(x, y, r, g, b);
    }
  }

  // Quality 60 — fast encode, sufficient for SmolVLM-256M which resizes
  // input to 384×384 internally regardless of source JPEG quality.
  return Uint8List.fromList(img.encodeJpg(rgbImg, quality: 60));
}

class _BufferedFrame {
  final CameraImage cameraImage;
  final DateTime timestamp;
  _BufferedFrame({required this.cameraImage, required this.timestamp});
}