import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:logger/logger.dart';
import 'package:record/record.dart';
import 'wake_word_engine.dart';
import 'silero_vad.dart';
import 'frame_selector.dart';
import 'stt_manager.dart';
import 'translation_engine.dart';
import 'vlm_runner.dart';
import 'streaming_tts.dart';
import '../../services/language_service.dart';

enum Pipeline2State { idle, awaitingWakeWord, recording, transcribing, thinking, speaking, error }

/// Orchestrates all Pipeline 2 stages end-to-end.
class ConversationCoordinator {
  ConversationCoordinator._();
  static final ConversationCoordinator instance = ConversationCoordinator._();

  final _log = Logger();
  Pipeline2State _state = Pipeline2State.idle;
  Pipeline2State get state => _state;

  final _stateController = StreamController<Pipeline2State>.broadcast();
  Stream<Pipeline2State> get stateStream => _stateController.stream;

  final _responseController = StreamController<String>.broadcast();
  Stream<String> get responseStream => _responseController.stream;

  final _transcriptController = StreamController<String>.broadcast();
  Stream<String> get transcriptStream => _transcriptController.stream;

  final _audioRecorder = AudioRecorder();
  StreamSubscription? _wakeWordSub;
  StreamSubscription? _vadSub;
  FrameSelector? _frameSelector;

  void attachFrameSelector(FrameSelector fs) { _frameSelector = fs; }

  Future<void> start() async {
    await WakeWordEngine.instance.start();
    _setState(Pipeline2State.awaitingWakeWord);

    _wakeWordSub = WakeWordEngine.instance.onWakeWordDetected.listen((_) async {
      if (_state != Pipeline2State.awaitingWakeWord) return;
      await _onWakeWordDetected();
    });

    // VAD speech-end listener
    _vadSub = SileroVad.instance.onSpeechEnd.listen((audio) async {
      if (_state == Pipeline2State.recording) {
        await _onSpeechEnd(audio);
      }
    });

    _log.i('Pipeline 2 started — awaiting wake word');
  }

  Future<void> _onWakeWordDetected() async {
    _setState(Pipeline2State.recording);
    _log.i('Wake word detected → starting recording');
    SileroVad.instance.reset();

    // Start mic stream feeding VAD
    final micStream = await _audioRecorder.startStream(
      const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1),
    );
    micStream.listen((chunk) {
      SileroVad.instance.feed(chunk);
    });
  }

  Future<void> _onSpeechEnd(Uint8List audioBytes) async {
    await _audioRecorder.stop();
    _setState(Pipeline2State.transcribing);

    // Capture sharpest frame at speech-end boundary (0ms perceived latency)
    final frameJpeg = await _frameSelector?.selectSharpestFrame();

    // STT
    final sttResult = await SttManager.instance.transcribe(audioBytes);
    final transcript = sttResult.transcript;
    _log.i('Transcript (${sttResult.provider.name}, ${sttResult.latencyMs}ms): $transcript');
    _transcriptController.add(transcript);

    // Translate → English
    _setState(Pipeline2State.thinking);
    final englishQuery = await TranslationEngine.instance
        .translateToEnglish(transcript, LanguageService.instance.currentCode);
    _log.i('English query: $englishQuery');

    // VLM inference with streaming TTS
    if (frameJpeg == null) {
      _responseController.add('I could not capture a frame. Please try again.');
      _setState(Pipeline2State.awaitingWakeWord);
      return;
    }

    _setState(Pipeline2State.speaking);
    final fullResponse = StringBuffer();
    StreamingTts.instance.startStreaming(
      VlmRunner.instance.tokenStream,
      onSentence: (s) => _responseController.add(s),
    );

    final response = await VlmRunner.instance.generateResponse(
      frameJpeg: frameJpeg,
      englishQuery: englishQuery,
    );
    _log.i('VLM response: $response');

    _setState(Pipeline2State.awaitingWakeWord);
  }

  /// Manual trigger (Push-to-Talk fallback).
  Future<void> triggerManually() async {
    if (_state == Pipeline2State.awaitingWakeWord) {
      await _onWakeWordDetected();
    }
  }

  void _setState(Pipeline2State s) {
    _state = s;
    _stateController.add(s);
  }

  Future<void> stop() async {
    _wakeWordSub?.cancel();
    _vadSub?.cancel();
    await _audioRecorder.stop();
    await WakeWordEngine.instance.stop();
    _setState(Pipeline2State.idle);
  }

  void dispose() {
    _stateController.close();
    _responseController.close();
    _transcriptController.close();
  }
}
