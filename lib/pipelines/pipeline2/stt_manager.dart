import 'dart:typed_data';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants.dart';
import '../../core/model_manager.dart';
import '../../core/dpdp_consent.dart';
import '../../services/connectivity_service.dart';
import '../../services/language_service.dart';
import 'dart:io';

enum SttMode { auto, alwaysOnline, alwaysOffline }
enum SttProvider { groq, onDevice }

class SttResult {
  final String transcript;
  final SttProvider provider;
  final int latencyMs;
  const SttResult({required this.transcript, required this.provider, required this.latencyMs});
}

/// STT: Groq Whisper (online) + Whisper-tiny ONNX (offline).
class SttManager {
  SttManager._();
  static final SttManager instance = SttManager._();

  final _log = Logger();
  final _dio = Dio();
  SttMode _mode = SttMode.auto;

  // Whisper-tiny is split into two ONNX sessions: encoder + merged decoder
  OrtSession? _encoderSession;
  OrtSession? _decoderSession;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = SttMode.values[prefs.getInt('stt_mode') ?? 0];
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    );
  }

  Future<void> loadOfflineModel() async {
    try {
      final options = OrtSessionOptions()
        ..setInterOpNumThreads(2)
        ..setIntraOpNumThreads(2);

      _encoderSession = await OrtSession.fromFile(
        File(ModelManager.instance.modelPath(AppConstants.whisperTinyEncoderFile)),
        options,
      );
      _decoderSession = await OrtSession.fromFile(
        File(ModelManager.instance.modelPath(AppConstants.whisperTinyDecoderFile)),
        options,
      );
      _log.i('Offline STT loaded (encoder + decoder)');
    } catch (e) {
      _log.e('Offline STT load failed: $e');
      _encoderSession = null;
      _decoderSession = null;
    }
  }

  bool get _offlineReady => _encoderSession != null && _decoderSession != null;

  Future<SttResult> transcribe(Uint8List pcm16leBytes) async {
    final start = DateTime.now();
    if (_shouldUseOnline()) {
      try {
        final t = await _transcribeOnline(pcm16leBytes);
        final ms = DateTime.now().difference(start).inMilliseconds;
        DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
          dataType: DpdpDataType.networkRequest,
          description: 'Audio → Groq Whisper API (STT)',
          stayedOnDevice: false,
          timestamp: DateTime.now(),
        ));
        return SttResult(transcript: t, provider: SttProvider.groq, latencyMs: ms);
      } catch (e) {
        _log.w('Online STT failed, falling back: $e');
      }
    }
    final t = await _transcribeOffline(pcm16leBytes);
    final ms = DateTime.now().difference(start).inMilliseconds;
    DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
      dataType: DpdpDataType.audioCapture,
      description: 'Audio transcribed on-device (Whisper-tiny)',
      stayedOnDevice: true,
      timestamp: DateTime.now(),
    ));
    return SttResult(transcript: t, provider: SttProvider.onDevice, latencyMs: ms);
  }

  bool _shouldUseOnline() {
    if (_mode == SttMode.alwaysOffline) return false;
    if (_mode == SttMode.alwaysOnline) return true;
    return ConnectivityService.instance.isOnline &&
        DpdpConsentManager.instance.onlineSttAllowed;
  }

  Future<String> _transcribeOnline(Uint8List pcm) async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(AppConstants.groqApiKeyPrefKey) ?? '';
    if (key.isEmpty) throw Exception('No Groq API key');
    final wav = _pcmToWav(pcm, 16000, 1, 16);
    final lang = LanguageService.instance.currentCode;
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(wav, filename: 'audio.wav'),
      'model': AppConstants.groqWhisperModel,
      'language': lang,
      'response_format': 'text',
    });
    final resp = await _dio.post(
      '${AppConstants.groqApiBaseUrl}/audio/transcriptions',
      data: form,
      options: Options(headers: {'Authorization': 'Bearer $key'}),
    );
    return (resp.data as String).trim();
  }

  Future<String> _transcribeOffline(Uint8List pcm) async {
    if (!_offlineReady) await loadOfflineModel();
    if (!_offlineReady) return '[offline STT unavailable]';

    // Convert PCM int16 → float32 normalised to [-1, 1]
    final bd = ByteData.sublistView(pcm);
    final samples = Float32List(pcm.length ~/ 2);
    for (int i = 0; i < samples.length; i++) {
      samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }

    // ── Encoder pass ──
    final audioT = OrtValueTensor.createTensorWithDataList(
      samples, [1, samples.length],
    );
    final encOuts = await _encoderSession!.runAsync(
      OrtRunOptions(),
      {'input_features': audioT},
      ['last_hidden_state'],
    );
    audioT.release();

    final encoderHidden = encOuts![0]!; // keep alive for decoder

    // ── Decoder pass (merged encoder+decoder ONNX) ──
    // Seed with the start-of-transcript token (50258) + language token
    final langToken = _langToken(LanguageService.instance.currentCode);
    final initIds = Int64List.fromList([50258, langToken, 50359, 50363]);
    final decoderIdsT = OrtValueTensor.createTensorWithDataList(
      initIds, [1, initIds.length],
    );

    final decOuts = await _decoderSession!.runAsync(
      OrtRunOptions(),
      {
        'input_ids': decoderIdsT,
        'encoder_hidden_states': encoderHidden,
      },
      ['logits'],
    );
    decoderIdsT.release();
    encoderHidden.release();

    // Greedy-decode logits → token ids → join as placeholder text
    // (Full beam-search decoding would be a separate loop; this is MVP greedy)
    final logits = decOuts![0]?.value as List<dynamic>?;
    decOuts[0]?.release();

    if (logits == null) return '[decode error]';

    // logits shape: [1, seq_len, vocab_size] — pick argmax of last position
    final lastStep = logits[0].last as List<dynamic>;
    int bestToken = 0;
    double bestVal = double.negativeInfinity;
    for (int i = 0; i < lastStep.length; i++) {
      final v = (lastStep[i] as num).toDouble();
      if (v > bestVal) { bestVal = v; bestToken = i; }
    }

    // For a real implementation wire up the full autoregressive loop here.
    // Returning the top token as a placeholder until that is implemented.
    return '[$bestToken]';
  }

  // Whisper language token ids (offset 50259 + language index in vocab)
  int _langToken(String code) {
    const map = {'en': 50259, 'hi': 50297, 'ta': 50342, 'te': 50344,
                  'bn': 50272, 'mr': 50320, 'kn': 50308};
    return map[code] ?? 50297; // default Hindi
  }

  Uint8List _pcmToWav(Uint8List pcm, int sr, int ch, int bps) {
    final buf = ByteData(44 + pcm.length);
    void s(int o, List<int> b) { for (int i = 0; i < b.length; i++) buf.setUint8(o + i, b[i]); }
    s(0, [0x52, 0x49, 0x46, 0x46]);
    buf.setUint32(4, 36 + pcm.length, Endian.little);
    s(8, [0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20]);
    buf.setUint32(16, 16, Endian.little); buf.setUint16(20, 1, Endian.little);
    buf.setUint16(22, ch, Endian.little); buf.setUint32(24, sr, Endian.little);
    buf.setUint32(28, sr * ch * bps ~/ 8, Endian.little);
    buf.setUint16(32, ch * bps ~/ 8, Endian.little);
    buf.setUint16(34, bps, Endian.little);
    s(36, [0x64, 0x61, 0x74, 0x61]); buf.setUint32(40, pcm.length, Endian.little);
    for (int i = 0; i < pcm.length; i++) buf.setUint8(44 + i, pcm[i]);
    return buf.buffer.asUint8List();
  }

  void setMode(SttMode mode) {
    _mode = mode;
    SharedPreferences.getInstance().then((p) => p.setInt('stt_mode', mode.index));
  }

  SttMode get currentMode => _mode;
  SttMode get mode => _mode; // alias used by settings_screen

  void dispose() {
    _encoderSession?.release();
    _decoderSession?.release();
  }
}