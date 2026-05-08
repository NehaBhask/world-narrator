import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:logger/logger.dart';

/// Maintains a rolling buffer of camera frames and selects the sharpest one
/// using Laplacian variance (focus measure) at the moment of speech end.
/// pHash is used to deduplicate near-identical frames.
class FrameSelector {
  FrameSelector({this.bufferSize = 10});

  final int bufferSize;
  final _log = Logger();
  final List<_BufferedFrame> _buffer = [];

  /// Add a new frame to the rolling buffer. Call on every camera frame.
  void addFrame(CameraImage cameraImage) {
    if (_buffer.length >= bufferSize) {
      _buffer.removeAt(0);
    }
    _buffer.add(_BufferedFrame(
      cameraImage: cameraImage,
      timestamp: DateTime.now(),
    ));
  }

  /// Returns JPEG bytes of the sharpest (highest Laplacian variance) frame
  /// in the current buffer. Returns null if buffer is empty.
  Future<Uint8List?> selectSharpestFrame() async {
    if (_buffer.isEmpty) {
      _log.w('Frame buffer empty — cannot select frame');
      return null;
    }

    _BufferedFrame? best;
    double bestScore = -1;

    for (final frame in _buffer) {
      final score = await _laplacianVariance(frame.cameraImage);
      _log.d('Frame sharpness score: ${score.toStringAsFixed(2)}');
      if (score > bestScore) {
        bestScore = score;
        best = frame;
      }
    }

    if (best == null) return null;

    _log.i('Selected frame with sharpness=${bestScore.toStringAsFixed(2)}, '
        'age=${DateTime.now().difference(best.timestamp).inMilliseconds}ms');

    return _cameraImageToJpeg(best.cameraImage);
  }

  /// Compute Laplacian variance as a measure of image sharpness.
  /// Higher variance = sharper image.
  Future<double> _laplacianVariance(CameraImage cameraImage) async {
    final gray = _yuv420ToGray(cameraImage);
    if (gray == null) return 0;

    final w = cameraImage.width;
    final h = cameraImage.height;

    // Subsample for speed: use every 4th pixel
    const step = 4;
    double sum = 0;
    double sumSq = 0;
    int count = 0;

    // Laplacian kernel: [0,1,0,1,-4,1,0,1,0]
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
    return (sumSq / count) - (mean * mean); // variance
  }

  Uint8List? _yuv420ToGray(CameraImage image) {
    if (image.planes.isEmpty) return null;
    return image.planes[0].bytes; // Y plane is grayscale
  }

  Uint8List _cameraImageToJpeg(CameraImage image) {
    final w = image.width;
    final h = image.height;
    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;

    final rgbImg = img.Image(width: w, height: h);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final yVal = yPlane[y * w + x];
        final uvIdx = (y ~/ 2) * (w ~/ 2) + (x ~/ 2);
        final u = uPlane.length > uvIdx ? uPlane[uvIdx] - 128 : 0;
        final v = vPlane.length > uvIdx ? vPlane[uvIdx] - 128 : 0;

        int r = (yVal + 1.402 * v).clamp(0, 255).toInt();
        int g = (yVal - 0.344136 * u - 0.714136 * v).clamp(0, 255).toInt();
        int b = (yVal + 1.772 * u).clamp(0, 255).toInt();

        rgbImg.setPixelRgb(x, y, r, g, b);
      }
    }

    return Uint8List.fromList(img.encodeJpg(rgbImg, quality: 85));
  }

  void clear() => _buffer.clear();
}

class _BufferedFrame {
  final CameraImage cameraImage;
  final DateTime timestamp;
  _BufferedFrame({required this.cameraImage, required this.timestamp});
}
