/// Application-wide constants for Narrator.
library;

class AppConstants {
  AppConstants._();

  // ── App Identity ────────────────────────────────────────
  static const String appName = 'Narrator';
  static const String appVersion = '1.0.0';
  static const String privacyPolicyVersion = '1.0';

  // ── DPDP ────────────────────────────────────────────────
  static const String dpdpConsentKey = 'dpdp_consent_v1';
  static const String dpdpConsentTimestampKey = 'dpdp_consent_timestamp';
  static const String dpdpOnlineSttConsentKey = 'dpdp_online_stt_consent';
  static const String dpdpAnalyticsConsentKey = 'dpdp_analytics_consent';
  static const String privacyPolicyVersionKey = 'privacy_policy_version';

  // ── Model Paths ─────────────────────────────────────────
  static const String modelDirName = 'narrator_models';
  static const String sileroVadAsset = 'assets/models/silero_vad.onnx';

  // ── Remote Model URLs ───────────────────────────────────

  // YOLOv8-nano: convert with `yolo export model=yolov8n.pt format=ncnn`,
  // then self-host the .param and .bin files.
  static const String yolov8nParamUrl = ''; // TODO: self-host after NCNN export
  static const String yolov8nBinUrl = '';   // TODO: self-host after NCNN export

  // SmolVLM-256M vision projector (mmproj, 190 MB) — unchanged, correct.
  static const String smolvlmGgufUrl =
      'https://huggingface.co/ggml-org/SmolVLM-256M-Instruct-GGUF/resolve/main/mmproj-SmolVLM-256M-Instruct-f16.gguf';

  // SmolVLM-256M language model (Q4_K_M, 125 MB).
  // FIX: ggml-org repo only has Q8_0 and F16 — no Q4_K_M there.
  // mradermacher's repo has the Q4_K_M quant (note the dot before Q4, not
  // a hyphen: SmolVLM-256M-Instruct.Q4_K_M.gguf).
  static const String smolvlmTextGgufUrl =
      'https://huggingface.co/mradermacher/SmolVLM-256M-Instruct-GGUF/resolve/main/SmolVLM-256M-Instruct.Q4_K_M.gguf';

  // IndicTrans2: no pre-built public ONNX — must self-export from AI4Bharat.
  static const String indicTrans2OnnxUrl = ''; // TODO: self-export or skip for MVP

  // Silero VAD — opset 15 / IR version 9 build, compatible with the
  // onnxruntime on Android (max supported IR version: 9).
  // FIX: onnx-community model is opset 16 / IR version 10 → "Unsupported
  // model IR version: 10, max supported IR version: 9" crash.
  // The official silero repo ships silero_vad_16k_op15.onnx at opset 15,
  // supports 16 kHz (which is all this app uses).
  static const String sileroVadOnnxUrl =
      'https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad_16k_op15.onnx';

  // Whisper-tiny multilingual ONNX — split into encoder + merged decoder.
  // FIX: there is no single model.onnx; must load two sessions separately.
  static const String whisperTinyEncoderUrl =
      'https://huggingface.co/onnx-community/whisper-tiny/resolve/main/onnx/encoder_model.onnx';
  static const String whisperTinyDecoderUrl =
      'https://huggingface.co/onnx-community/whisper-tiny/resolve/main/onnx/decoder_model_merged.onnx';

  // ── Model File Names ────────────────────────────────────
  static const String yolov8nParamFile = 'yolov8n.ncnn.param';
  static const String yolov8nBinFile = 'yolov8n.ncnn.bin';
  // mmproj — vision projector (downloaded via smolvlmGgufUrl)
  static const String smolvlmFile = 'mmproj-SmolVLM-256M-Instruct-f16.gguf';
  // text GGUF — language model (downloaded via smolvlmTextGgufUrl)
  static const String smolvlmTextFile = 'SmolVLM-256M-Instruct.Q4_K_M.gguf';
  static const String indicTrans2File = 'indictrans2_int8.onnx';
  // Silero VAD saved locally under this name regardless of remote filename
  static const String sileroVadFile = 'silero_vad.onnx';
  // Whisper split into two files
  static const String whisperTinyEncoderFile = 'whisper_tiny_encoder.onnx';
  static const String whisperTinyDecoderFile = 'whisper_tiny_decoder_merged.onnx';
  static const String qwen3VlFile = 'qwen3_vl_2b_q4.gguf';

  // SHA-256 hashes for integrity verification.
  static const Map<String, String> modelHashes = {
    // From HF xet metadata
    'mmproj-SmolVLM-256M-Instruct-f16.gguf':
        '0802360aca1748f112ea510b8ff277c65b1361c8ef30ed89b83c9c7a60d08e96',
    'whisper_tiny_encoder.onnx':
        'a048dcf0cde98db805f46be32b75d778cf824aad20b51a02e5b9cff457426238',
    // Verify these after first successful download
    'silero_vad.onnx':                    'verify_after_download',
    'SmolVLM-256M-Instruct.Q4_K_M.gguf': 'verify_after_download',
    'whisper_tiny_decoder_merged.onnx':   'verify_after_download',
    'indictrans2_int8.onnx':              'verify_after_download',
    'yolov8n.ncnn.param':                 'verify_after_download',
    'yolov8n.ncnn.bin':                   'verify_after_download',
  };

  // ── Pipeline 1 Tuning ───────────────────────────────────
  static const int targetFps = 30;
  static const double obstacleAreaThreshold = 0.12; // 12% of frame area
  static const int obstacleCooldownMs = 2000;       // 2s between alerts
  static const List<int> obstaclePulsePattern = [0, 80, 60, 80, 60, 80];

  // ── Pipeline 2 Tuning ───────────────────────────────────
  static const int frameBufferSize = 10;
  static const double vadSpeechThreshold = 0.5;
  static const int vadSilenceMs = 700; // silence after speech = end of query
  static const int maxRecordingSeconds = 30;

  // ── Online STT ──────────────────────────────────────────
  static const String groqApiBaseUrl = 'https://api.groq.com/openai/v1';
  static const String groqWhisperModel = 'whisper-large-v3-turbo';
  // API key stored in secure storage / env — never hardcoded
  static const String groqApiKeyPrefKey = 'groq_api_key';

  // ── Languages ───────────────────────────────────────────
  static const List<Map<String, String>> supportedLanguages = [
    {'code': 'hi', 'name': 'हिन्दी', 'nameEn': 'Hindi', 'locale': 'hi-IN'},
    {'code': 'en', 'name': 'English', 'nameEn': 'English', 'locale': 'en-IN'},
    {'code': 'ta', 'name': 'தமிழ்', 'nameEn': 'Tamil', 'locale': 'ta-IN'},
    {'code': 'te', 'name': 'తెలుగు', 'nameEn': 'Telugu', 'locale': 'te-IN'},
    {'code': 'bn', 'name': 'বাংলা', 'nameEn': 'Bengali', 'locale': 'bn-IN'},
    {'code': 'mr', 'name': 'मराठी', 'nameEn': 'Marathi', 'locale': 'mr-IN'},
    {'code': 'kn', 'name': 'ಕನ್ನಡ', 'nameEn': 'Kannada', 'locale': 'kn-IN'},
  ];

  // ── Obstacle Alert Messages ─────────────────────────────
  static const Map<String, String> obstacleAlertMessages = {
    'hi': 'आगे कुछ है, सावधान',
    'en': 'Obstacle ahead',
    'ta': 'முன்னால் தடை உள்ளது',
    'te': 'ముందు అడ్డంకి ఉంది',
    'bn': 'সামনে বাধা আছে',
    'mr': 'पुढे अडथळा आहे',
    'kn': 'ಮುಂದೆ ಅಡಚಣೆ ಇದೆ',
  };

  // ── Device Tier ─────────────────────────────────────────
  static const int qwen3MinRamMb = 5500; // 6GB minus OS overhead
}