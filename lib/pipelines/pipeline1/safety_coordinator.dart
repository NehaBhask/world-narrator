import 'dart:async';
import 'package:camera/camera.dart';
import 'package:logger/logger.dart';
import 'yolo_ncnn_runner.dart';
import 'obstacle_detector.dart';
import '../../services/haptic_service.dart';
import '../../services/tts_service.dart';
import '../../services/language_service.dart';
import '../../core/constants.dart';

enum Pipeline1State { idle, running, paused }

/// Coordinates Pipeline 1: camera frames → YOLO → obstacle → haptic + TTS alert.
/// Runs continuously regardless of Pipeline 2 state.
class SafetyCoordinator {
  SafetyCoordinator._();
  static final SafetyCoordinator instance = SafetyCoordinator._();

  final _log = Logger();
  final _yolo = YoloNcnnRunner.instance;
  final _detector = ObstacleDetector();

  Pipeline1State _state = Pipeline1State.idle;
  Pipeline1State get state => _state;

  DateTime? _lastAlertTime;
  int _frameCount = 0;
  int _detectionCount = 0;

  // Observable stream of latest detections for UI overlay
  final _detectionsController =
      StreamController<List<YoloDetection>>.broadcast();
  Stream<List<YoloDetection>> get detectionsStream =>
      _detectionsController.stream;

  // FPS tracking
  double _currentFps = 0;
  double get currentFps => _currentFps;
  DateTime? _fpsTimer;

  Future<void> start() async {
    if (_state == Pipeline1State.running) return;
    final loaded = await _yolo.loadModel();
    if (!loaded) {
      _log.w('P1: YOLOv8 not loaded — safety pipeline inactive');
      return;
    }
    _state = Pipeline1State.running;
    _log.i('Pipeline 1 started');
  }

  void pause() => _state = Pipeline1State.paused;
  void resume() => _state = Pipeline1State.running;

  /// Process a single camera frame. Called from camera stream listener.
  Future<void> processFrame(CameraImage frame) async {
    if (_state != Pipeline1State.running) return;

    final frameStart = DateTime.now();
    _frameCount++;

    // FPS computation every 30 frames
    if (_frameCount % 30 == 0) {
      final now = DateTime.now();
      if (_fpsTimer != null) {
        _currentFps = 30000 / now.difference(_fpsTimer!).inMilliseconds;
      }
      _fpsTimer = now;
    }

    final detections = await _yolo.detect(frame);

    // Publish to UI stream (non-blocking)
    if (!_detectionsController.isClosed) {
      _detectionsController.add(detections);
    }

    final threat = _detector.mostThreateningObstacle(detections);
    if (threat != null) {
      _detectionCount++;
      await _triggerAlert(threat);
    }
    // Note: per-frame logging removed — it floods logcat at 30fps
  }

  Future<void> _triggerAlert(YoloDetection threat) async {
    final now = DateTime.now();
    if (_lastAlertTime != null &&
        now.difference(_lastAlertTime!).inMilliseconds <
            AppConstants.obstacleCooldownMs) {
      return; // Cooldown active
    }
    _lastAlertTime = now;

    final distance = _detector.estimateDistanceM(threat);
    _log.i('Obstacle detected! class=${threat.classId}, '
        'dist≈${distance.toStringAsFixed(1)}m, area=${threat.area.toStringAsFixed(3)}');

    // Haptic first (zero latency perception)
    await HapticService.instance.obstacleAlert();

    // TTS alert
    final msg = LanguageService.instance.obstacleAlertText;
    await TtsService.instance.speakAlert(msg);
  }

  Future<void> stop() async {
    _state = Pipeline1State.idle;
    await _yolo.release();
    _log.i('Pipeline 1 stopped');
  }

  void dispose() {
    _detectionsController.close();
  }

  // Diagnostics
  int get frameCount => _frameCount;
  int get detectionCount => _detectionCount;
}
