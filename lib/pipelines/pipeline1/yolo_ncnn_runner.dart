import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
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
  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;

  @override
  String toString() =>
      'Detection(class=$classId, conf=${confidence.toStringAsFixed(2)}, '
      'bbox=[${x1.toStringAsFixed(2)},${y1.toStringAsFixed(2)},'
      '${x2.toStringAsFixed(2)},${y2.toStringAsFixed(2)}])';
}

/// Dart-side wrapper around the NCNN JNI bridge for YOLOv8-nano inference.
/// Uses the real Flutter MethodChannel bound to NarratorPlugin.kt.
class YoloNcnnRunner {
  YoloNcnnRunner._();
  static final YoloNcnnRunner instance = YoloNcnnRunner._();

  final _log = Logger();
  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  // Real Flutter MethodChannel — registered in NarratorPlugin.kt
  static const _channel = MethodChannel('com.narrator/ncnn_plugin');

  Future<bool> loadModel() async {
    final paramPath = ModelManager.instance.modelPath(AppConstants.yolov8nParamFile);
    final binPath   = ModelManager.instance.modelPath(AppConstants.yolov8nBinFile);

    if (!File(paramPath).existsSync() || !File(binPath).existsSync()) {
      _log.w('YOLOv8 model files not found — P1 running in UI-only mode');
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
    } on MissingPluginException {
      _log.w('NarratorPlugin not registered — YOLO disabled (run on device)');
      return false;
    } catch (e) {
      _log.e('Error loading YOLO model: $e');
      return false;
    }
  }

  /// Run inference on a [CameraImage] (YUV420 format).
  /// Returns empty list if model not loaded or plugin not available.
  Future<List<YoloDetection>> detect(CameraImage image) async {
    if (!_isLoaded) return [];

    try {
      final yuvBytes = _cameraImageToNv21(image);
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
    } on MissingPluginException {
      return [];
    } catch (e) {
      _log.e('Inference error: $e');
      return [];
    }
  }

  /// Converts YUV420 CameraImage to NV21 byte array for JNI.
  Uint8List _cameraImageToNv21(CameraImage image) {
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final int ySize = yPlane.bytes.length;
    final int uvSize = uPlane.bytes.length;

    final Uint8List nv21 = Uint8List(ySize + uvSize * 2);
    nv21.setRange(0, ySize, yPlane.bytes);

    // Interleave V and U for NV21 format
    for (int i = 0; i < uvSize; i++) {
      nv21[ySize + i * 2]     = vPlane.bytes[i];
      nv21[ySize + i * 2 + 1] = uPlane.bytes[i];
    }
    return nv21;
  }

  Future<void> release() async {
    try {
      await _channel.invokeMethod('releaseYoloModel');
    } catch (_) {}
    _isLoaded = false;
  }
}
