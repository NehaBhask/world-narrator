import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:logger/logger.dart';
import '../../core/model_manager.dart';
import '../../core/constants.dart';

/// Detection result from YOLOv8-nano.
class YoloDetection {
  final int classId;
  final double confidence;
  final double x1, y1, x2, y2; // normalized [0, 1]

  const YoloDetection({
    required this.classId,
    required this.confidence,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  double get area => (x2 - x1) * (y2 - y1);

  // Centre of bbox — used for proximity heuristic
  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;

  @override
  String toString() =>
      'Detection(class=$classId, conf=${confidence.toStringAsFixed(2)}, '
      'bbox=[${x1.toStringAsFixed(2)},${y1.toStringAsFixed(2)},'
      '${x2.toStringAsFixed(2)},${y2.toStringAsFixed(2)}])';
}

/// Dart-side wrapper around the NCNN JNI bridge for YOLOv8-nano inference.
/// Communicates with native code via MethodChannel on Android.
class YoloNcnnRunner {
  YoloNcnnRunner._();
  static final YoloNcnnRunner instance = YoloNcnnRunner._();

  final _log = Logger();
  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  // ── Platform Channel ──────────────────────────────────────────────────────
  static const _channel = MethodChannelBridge._internal();

  Future<bool> loadModel() async {
    final paramPath = ModelManager.instance.modelPath(AppConstants.yolov8nParamFile);
    final binPath   = ModelManager.instance.modelPath(AppConstants.yolov8nBinFile);

    if (!File(paramPath).existsSync() || !File(binPath).existsSync()) {
      _log.w('YOLOv8 model files not found');
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>('loadYoloModel', {
        'paramPath': paramPath,
        'binPath': binPath,
      });
      _isLoaded = result ?? false;
      _log.i('YOLOv8 model loaded: $_isLoaded');
      return _isLoaded;
    } catch (e) {
      _log.e('Error loading YOLO model: $e');
      return false;
    }
  }

  /// Run inference on a [CameraImage] (YUV420 format).
  /// Returns list of detections (obstacle classes only).
  Future<List<YoloDetection>> detect(CameraImage image) async {
    if (!_isLoaded) return [];

    try {
      // Combine YUV planes into single byte array for JNI
      final yuvBytes = _cameraImageToYuv(image);

      final rawResult = await _channel.invokeMethod<List<dynamic>>(
        'detectObjects',
        {
          'yuvData': yuvBytes,
          'width': image.width,
          'height': image.height,
        },
      );

      if (rawResult == null || rawResult.isEmpty) return [];

      // Parse: groups of 6 floats [classId, conf, x1, y1, x2, y2]
      final detections = <YoloDetection>[];
      for (int i = 0; i + 5 < rawResult.length; i += 6) {
        detections.add(YoloDetection(
          classId: (rawResult[i] as num).toInt(),
          confidence: (rawResult[i + 1] as num).toDouble(),
          x1: (rawResult[i + 2] as num).toDouble(),
          y1: (rawResult[i + 3] as num).toDouble(),
          x2: (rawResult[i + 4] as num).toDouble(),
          y2: (rawResult[i + 5] as num).toDouble(),
        ));
      }
      return detections;
    } catch (e) {
      _log.e('Inference error: $e');
      return [];
    }
  }

  Uint8List _cameraImageToYuv(CameraImage image) {
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final int ySize = yPlane.bytes.length;
    final int uvSize = uPlane.bytes.length;

    final Uint8List nv21 = Uint8List(ySize + uvSize * 2);
    nv21.setRange(0, ySize, yPlane.bytes);

    // Interleave V and U for NV21
    for (int i = 0; i < uvSize; i++) {
      nv21[ySize + i * 2] = vPlane.bytes[i];
      nv21[ySize + i * 2 + 1] = uPlane.bytes[i];
    }
    return nv21;
  }

  Future<void> release() async {
    await _channel.invokeMethod('releaseYoloModel');
    _isLoaded = false;
  }
}

/// Thin wrapper around MethodChannel to keep runner testable.
class MethodChannelBridge {
  const MethodChannelBridge._internal();

  static const _platform =
      _FlutterMethodChannel('com.narrator/ncnn_plugin');

  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      _platform.invokeMethod<T>(method, arguments);
}

// ignore: non_constant_identifier_names
_FlutterMethodChannel get _channel =>
    const _FlutterMethodChannel('com.narrator/ncnn_plugin');

// Lightweight adapter — avoids direct flutter/services import in this file
class _FlutterMethodChannel {
  final String name;
  const _FlutterMethodChannel(this.name);
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    // Actual invocation delegated to platform channel in NarratorPlugin.kt
    // This stub is replaced at runtime by Flutter's method channel binding.
    throw UnimplementedError('MethodChannel not bound — see NarratorPlugin.kt');
  }
}
