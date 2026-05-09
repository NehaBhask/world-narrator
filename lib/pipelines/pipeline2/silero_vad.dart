import 'dart:async';
import 'dart:typed_data';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:logger/logger.dart';
import 'package:flutter/services.dart';
import '../../core/constants.dart';
import '../../core/model_manager.dart';
import 'dart:io';

enum VadState { idle, speechDetected, speechEnded }

/// Silero VAD — detects speech boundaries using ONNX Runtime.
/// Model: silero_vad.onnx (~1.8 MB), runs at 16kHz, 30ms windows.
class SileroVad {
  SileroVad._();
  static final SileroVad instance = SileroVad._();

  final _log = Logger();
  OrtSession? _session;

  // Silero VAD stateful LSTM tensors — shape [2, 1, 64]
  // Must be updated after every inference window or VAD degrades immediately.
  List<List<List<double>>> _h =
      List.generate(2, (_) => List.generate(1, (_) => List.filled(64, 0.0)));
  List<List<List<double>>> _c =
      List.generate(2, (_) => List.generate(1, (_) => List.filled(64, 0.0)));

  static const int _sampleRate = 16000;
  static const int _windowSizeSamples = 512; // 32ms @ 16kHz
  static const double _speechThreshold = 0.5;
  static const int _silencePaddingMs = 700;

  bool _isSpeaking = false;
  int _silenceFrameCount = 0;
  final int _silenceFramesThreshold =
      (_silencePaddingMs / (1000 * _windowSizeSamples / _sampleRate)).ceil();

  final _speechEndController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get onSpeechEnd => _speechEndController.stream;

  // Accumulates PCM int16 samples across chunks for speech-end emission
  final List<int> _audioBuffer = [];

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  Future<void> init() async {
    final modelPath =
        ModelManager.instance.modelPath(AppConstants.sileroVadFile);
    if (!File(modelPath).existsSync()) {
      _log.w('Silero VAD model not found — VAD disabled. Download it first.');
      return;
    }
    try {
      OrtEnv.instance.init();
      final sessionOptions = OrtSessionOptions()
        ..setInterOpNumThreads(1)
        ..setIntraOpNumThreads(1);
      _session = await OrtSession.fromFile(File(modelPath), sessionOptions);
      _isLoaded = true;
      _log.i('Silero VAD loaded');
    } catch (e) {
      _log.e('Silero VAD init failed: $e');
    }
  }

  /// Feed 16kHz int16 PCM chunk. Internally windows into 512-sample frames.
  Future<void> feed(Uint8List pcm16leBytes) async {
    if (_session == null) return;

    // Convert bytes → int16 samples and append to buffer
    final bd = ByteData.sublistView(pcm16leBytes);
    for (int i = 0; i < pcm16leBytes.length - 1; i += 2) {
      _audioBuffer.add(bd.getInt16(i, Endian.little));
    }

    // Process complete 512-sample windows
    while (_audioBuffer.length >= _windowSizeSamples) {
      final window = _audioBuffer.sublist(0, _windowSizeSamples);
      _audioBuffer.removeRange(0, _windowSizeSamples);
      await _processWindow(window);
    }
  }

  Future<void> _processWindow(List<int> samples) async {
    // Normalise int16 → float32 [-1, 1]
    final floats =
        Float32List.fromList(samples.map((s) => s / 32768.0).toList());

    // Build ONNX input tensors
    // input: [1, 512], sr: [1], h: [2, 1, 64], c: [2, 1, 64]
    final inputTensor = OrtValueTensor.createTensorWithDataList(
        floats, [1, _windowSizeSamples]);
    final srTensor = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList([_sampleRate]), [1]);
    final hTensor = OrtValueTensor.createTensorWithDataList(
        _flattenState(_h), [2, 1, 64]);
    final cTensor = OrtValueTensor.createTensorWithDataList(
        _flattenState(_c), [2, 1, 64]);

    final inputs = {
      'input': inputTensor,
      'sr': srTensor,
      'h': hTensor,
      'c': cTensor,
    };

    final outputs = await _session!.runAsync(
      OrtRunOptions(),
      inputs,
      ['output', 'hn', 'cn'],
    );

    if (outputs == null) {
      for (final v in inputs.values) v.release();
      return;
    }

    // Extract values BEFORE releasing tensors
    final prob = (outputs[0]?.value as List<dynamic>)[0][0] as double;
    final hn = outputs[1]?.value as List<dynamic>;
    final cn = outputs[2]?.value as List<dynamic>;

    // ✅ Update LSTM state before release — this was the bug:
    // previously _updateState was never called, so h/c stayed all-zeros
    // and the model gave meaningless probabilities after the first frame.
    _updateState(hn, cn);

    // Now safe to release
    for (final v in inputs.values) v.release();
    for (final o in outputs) o?.release();

    _onProbability(prob);
  }

  void _onProbability(double prob) {
    if (prob > _speechThreshold) {
      _isSpeaking = true;
      _silenceFrameCount = 0;
    } else if (_isSpeaking) {
      _silenceFrameCount++;
      if (_silenceFrameCount >= _silenceFramesThreshold) {
        _isSpeaking = false;
        _silenceFrameCount = 0;
        _emitSpeechEnd();
      }
    }
  }

  void _emitSpeechEnd() {
    // Emit whatever remains in the buffer as the final audio chunk
    final pcm = Uint8List(_audioBuffer.length * 2);
    final bd = ByteData.sublistView(pcm);
    for (int i = 0; i < _audioBuffer.length; i++) {
      bd.setInt16(i * 2, _audioBuffer[i], Endian.little);
    }
    _audioBuffer.clear();
    _speechEndController.add(pcm);
    _log.d('VAD: speech end detected');
  }

  Float32List _flattenState(List<List<List<double>>> state) {
    final flat = <double>[];
    for (final a in state) {
      for (final b in a) {
        flat.addAll(b);
      }
    }
    return Float32List.fromList(flat);
  }

  /// Unpack new h/c LSTM states from ONNX output (shape [2, 1, 64])
  /// and store them for the next inference window.
  void _updateState(List<dynamic> hn, List<dynamic> cn) {
    for (int i = 0; i < 2; i++) {
      for (int j = 0; j < 64; j++) {
        _h[i][0][j] = (hn[i][0][j] as num).toDouble();
        _c[i][0][j] = (cn[i][0][j] as num).toDouble();
      }
    }
  }

  void reset() {
    _h = List.generate(
        2, (_) => List.generate(1, (_) => List.filled(64, 0.0)));
    _c = List.generate(
        2, (_) => List.generate(1, (_) => List.filled(64, 0.0)));
    _isSpeaking = false;
    _silenceFrameCount = 0;
    _audioBuffer.clear();
  }

  void dispose() {
    _session?.release();
    _speechEndController.close();
  }

  bool get isSpeaking => _isSpeaking;
}