import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import '../../core/constants.dart';
import '../../core/model_manager.dart';
import '../../core/dpdp_consent.dart';

enum VlmTier { smolvlm256m, qwen3vl2b }
enum VlmState { idle, loading, generating, done, error }

/// VLM runner — SmolVLM-256M (default) or Qwen3-VL-2B (6GB+ RAM).
/// Communicates with llama.cpp Android via MethodChannel.
/// Supports streaming token callback for sentence-by-sentence TTS.
class VlmRunner {
  VlmRunner._();
  static final VlmRunner instance = VlmRunner._();

  static const _channel = MethodChannel('com.narrator/vlm_plugin');
  final _log = Logger();

  VlmTier _tier = VlmTier.smolvlm256m;
  VlmState _state = VlmState.idle;
  VlmState get state => _state;

  final _tokenController = StreamController<String>.broadcast();
  Stream<String> get tokenStream => _tokenController.stream;

  Future<void> init() async {
    _tier = await _detectTier();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onToken') {
        _tokenController.add(call.arguments as String);
      } else if (call.method == 'onGenerationDone') {
        _state = VlmState.done;
        _tokenController.add('\x00'); // sentinel
      } else if (call.method == 'onGenerationError') {
        _state = VlmState.error;
        _log.e('VLM error: ${call.arguments}');
      }
    });
  }

  Future<VlmTier> _detectTier() async {
    try {
      final ramMb = await _channel.invokeMethod<int>('getAvailableRamMb') ?? 0;
      _log.i('Device RAM: ${ramMb}MB');
      return ramMb >= AppConstants.qwen3MinRamMb
          ? VlmTier.qwen3vl2b
          : VlmTier.smolvlm256m;
    } catch (_) {
      return VlmTier.smolvlm256m;
    }
  }

  Future<bool> loadModel() async {
    _state = VlmState.loading;
    final modelFile = _tier == VlmTier.qwen3vl2b
        ? AppConstants.qwen3VlFile
        : AppConstants.smolvlmFile;
    final path = ModelManager.instance.modelPath(modelFile);
    try {
      final ok = await _channel.invokeMethod<bool>('loadVlmModel', {
        'modelPath': path,
        'tier': _tier.name,
        'contextSize': 512,
        'threads': 4,
      }) ?? false;
      _state = ok ? VlmState.idle : VlmState.error;
      _log.i('VLM loaded (${_tier.name}): $ok');
      return ok;
    } catch (e) {
      _state = VlmState.error;
      _log.e('VLM load failed: $e');
      return false;
    }
  }

  /// Run VLM inference. Tokens stream via [tokenStream].
  /// Returns the complete response string.
  Future<String> generateResponse({
    required Uint8List frameJpeg,
    required String englishQuery,
  }) async {
    if (_state == VlmState.loading) throw StateError('VLM still loading');
    _state = VlmState.generating;

    final prompt = _buildPrompt(englishQuery);

    DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
      dataType: DpdpDataType.cameraFrame,
      description: 'Frame processed by ${_tier.name} VLM, on-device',
      stayedOnDevice: true,
      timestamp: DateTime.now(),
    ));

    try {
      await _channel.invokeMethod('generateResponse', {
        'imageBytes': frameJpeg,
        'prompt': prompt,
        'maxTokens': 256,
        'temperature': 0.3,
      });

      // Collect streaming tokens
      final buffer = StringBuffer();
      await for (final token in tokenStream) {
        if (token == '\x00') break; // sentinel
        buffer.write(token);
      }
      _state = VlmState.done;
      return buffer.toString().trim();
    } catch (e) {
      _state = VlmState.error;
      _log.e('VLM inference error: $e');
      return 'Sorry, I could not process that. Please try again.';
    }
  }

  String _buildPrompt(String query) {
    return '''<|im_start|>system
You are Narrator, an AI assistant helping visually impaired users.
Describe what you see in the image to answer the user's question.
Be concise, clear, and helpful. Respond in 2-3 short sentences maximum.
<|im_end|>
<|im_start|>user
<image>
$query
<|im_end|>
<|im_start|>assistant
''';
  }

  VlmTier get currentTier => _tier;
  void forceSetTier(VlmTier tier) => _tier = tier;

  Future<void> release() async {
    await _channel.invokeMethod('releaseVlmModel');
    _state = VlmState.idle;
  }

  void dispose() { _tokenController.close(); }
}
