import 'dart:async';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import '../../services/haptic_service.dart';

enum WakeWordState { idle, listening, detected }

/// Wake word detection engine.
/// Uses openWakeWord (Apache 2.0) via Android native plugin.
/// Keywords: "hey narrator", "suno"
/// CPU usage: <5% (documented for wake word models of this size).
class WakeWordEngine {
  WakeWordEngine._();
  static final WakeWordEngine instance = WakeWordEngine._();

  static const _channel = MethodChannel('com.narrator/wake_word');
  final _log = Logger();

  WakeWordState _state = WakeWordState.idle;
  WakeWordState get state => _state;

  final _detectedController = StreamController<String>.broadcast();
  Stream<String> get onWakeWordDetected => _detectedController.stream;

  bool _nativeAvailable = true; // Track if native plugin is available

  Future<void> init() async {
    try {
      // Register callback handler from native
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onWakeWordDetected') {
          final keyword = call.arguments as String? ?? 'narrator';
          _log.i('Wake word detected: $keyword');
          _state = WakeWordState.detected;
          await HapticService.instance.wakeWordConfirm();
          _detectedController.add(keyword);
          // Auto-reset to listening after emit
          await Future.delayed(const Duration(milliseconds: 500));
          if (_state == WakeWordState.detected) {
            _state = WakeWordState.listening;
          }
        }
      });
      
      // Test if native plugin is available
      try {
        await _channel.invokeMethod('isAvailable');
      } catch (e) {
        _nativeAvailable = false;
        _log.w('Wake word native plugin not available: $e');
      }
    } catch (e) {
      _nativeAvailable = false;
      _log.w('Failed to initialize wake word engine: $e');
    }
  }

  Future<void> start() async {
    if (!_nativeAvailable) {
      _log.w('Wake word engine not available on this device');
      return;
    }
    if (_state != WakeWordState.idle) return;
    try {
      await _channel.invokeMethod('startListening');
      _state = WakeWordState.listening;
      _log.i('Wake word engine started');
    } on PlatformException catch (e) {
      _log.e('Failed to start wake word engine: $e');
      _nativeAvailable = false;
    } catch (e) {
      _log.e('Wake word engine error: $e');
      _nativeAvailable = false;
    }
  }

  Future<void> stop() async {
    if (!_nativeAvailable) return;
    try {
      await _channel.invokeMethod('stopListening');
      _state = WakeWordState.idle;
      _log.i('Wake word engine stopped');
    } on PlatformException catch (e) {
      _log.e('Failed to stop wake word engine: $e');
    } catch (e) {
      _log.e('Wake word stop error: $e');
    }
  }

  void dispose() {
    _detectedController.close();
  }
}
