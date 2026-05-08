import 'package:flutter_tts/flutter_tts.dart';
import 'package:logger/logger.dart';
import '../core/constants.dart';

/// Manages text-to-speech with language awareness and P1/P2 priority queuing.
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  final _log = Logger();
  bool _isSpeaking = false;
  String _currentLanguageCode = 'hi';

  // Queue: P1 alerts preempt P2 responses
  final List<_TtsRequest> _queue = [];

  Future<void> init() async {
    await _tts.setSharedInstance(true);
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() => _isSpeaking = true);
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      _processQueue();
    });
    _tts.setErrorHandler((msg) {
      _log.e('TTS error: $msg');
      _isSpeaking = false;
      _processQueue();
    });
  }

  void setLanguage(String langCode) {
    _currentLanguageCode = langCode;
    final locale = AppConstants.supportedLanguages
        .firstWhere((l) => l['code'] == langCode,
            orElse: () => {'locale': 'hi-IN'})['locale']!;
    _tts.setLanguage(locale);
  }

  /// Speak with P1 (safety alert) priority — interrupts anything playing.
  Future<void> speakAlert(String? text) async {
    final msg = text ??
        AppConstants.obstacleAlertMessages[_currentLanguageCode] ??
        'Obstacle ahead';
    // Clear P2 items, put alert at front
    _queue.removeWhere((r) => !r.isAlert);
    _queue.insert(0, _TtsRequest(text: msg, isAlert: true));
    if (_isSpeaking) await _tts.stop();
    _processQueue();
  }

  /// Speak a P2 (conversational) sentence — queued.
  Future<void> speakResponse(String text) async {
    _queue.add(_TtsRequest(text: text, isAlert: false));
    if (!_isSpeaking) _processQueue();
  }

  void _processQueue() {
    if (_queue.isEmpty || _isSpeaking) return;
    final next = _queue.removeAt(0);
    _speak(next.text);
  }

  Future<void> _speak(String text) async {
    _isSpeaking = true;
    await _tts.speak(text);
  }

  Future<void> stop() async {
    _queue.clear();
    await _tts.stop();
    _isSpeaking = false;
  }

  bool get isSpeaking => _isSpeaking;
}

class _TtsRequest {
  final String text;
  final bool isAlert;
  _TtsRequest({required this.text, required this.isAlert});
}
