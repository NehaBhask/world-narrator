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

  // Remote model URLs (HuggingFace / CDN)
  static const String yolov8nParamUrl =
      'https://huggingface.co/spaces/narrator-app/models/resolve/main/yolov8n.ncnn.param';
  static const String yolov8nBinUrl =
      'https://huggingface.co/spaces/narrator-app/models/resolve/main/yolov8n.ncnn.bin';
  static const String smolvlmGgufUrl =
      'https://huggingface.co/HuggingFaceTB/SmolVLM-256M-Instruct-GGUF/resolve/main/SmolVLM-256M-Instruct-Q4_K_M.gguf';
  static const String indicTrans2OnnxUrl =
      'https://huggingface.co/spaces/narrator-app/models/resolve/main/indictrans2_int8.onnx';
  static const String whisperTinyOnnxUrl =
      'https://huggingface.co/spaces/narrator-app/models/resolve/main/whisper_tiny_multilingual.onnx';
  static const String sileroVadOnnxUrl =
      'https://huggingface.co/spaces/narrator-app/models/resolve/main/silero_vad.onnx';

  // ── Model File Names ────────────────────────────────────
  static const String yolov8nParamFile = 'yolov8n.ncnn.param';
  static const String yolov8nBinFile = 'yolov8n.ncnn.bin';
  static const String smolvlmFile = 'smolvlm_256m_q4.gguf';
  static const String indicTrans2File = 'indictrans2_int8.onnx';
  static const String whisperTinyFile = 'whisper_tiny_multilingual.onnx';
  static const String sileroVadFile = 'silero_vad.onnx';
  static const String qwen3VlFile = 'qwen3_vl_2b_q4.gguf';

  // SHA-256 hashes for integrity verification
  static const Map<String, String> modelHashes = {
    'silero_vad.onnx': 'placeholder_sha256_silero',
    'whisper_tiny_multilingual.onnx': 'placeholder_sha256_whisper',
    'indictrans2_int8.onnx': 'placeholder_sha256_indictrans2',
    'smolvlm_256m_q4.gguf': 'placeholder_sha256_smolvlm',
    'yolov8n.ncnn.param': 'placeholder_sha256_yolo_param',
    'yolov8n.ncnn.bin': 'placeholder_sha256_yolo_bin',
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
