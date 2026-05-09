import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:logger/logger.dart';
import 'constants.dart';

enum ModelStatus { notDownloaded, downloading, ready, corrupted }

class ModelInfo {
  final String name;
  final String fileName;
  final String url;
  final int estimatedSizeMb;
  final String description;
  ModelStatus status;
  double progress; // 0.0 – 1.0

  ModelInfo({
    required this.name,
    required this.fileName,
    required this.url,
    required this.estimatedSizeMb,
    required this.description,
    this.status = ModelStatus.notDownloaded,
    this.progress = 0.0,
  });
}

/// Manages download, integrity verification, and lifecycle of AI model files.
class ModelManager {
  ModelManager._();
  static final ModelManager instance = ModelManager._();

  final _log = Logger();
  final _dio = Dio();
  late Directory _modelDir;

  // Callbacks for UI updates
  void Function(String fileName, double progress)? onProgress;
  void Function(String fileName, ModelStatus status)? onStatusChanged;

  final List<ModelInfo> models = [
    ModelInfo(
      name: 'YOLOv8-nano (Param)',
      fileName: AppConstants.yolov8nParamFile,
      url: AppConstants.yolov8nParamUrl,
      estimatedSizeMb: 1,
      description: 'Object detection network config',
    ),
    ModelInfo(
      name: 'YOLOv8-nano (Weights)',
      fileName: AppConstants.yolov8nBinFile,
      url: AppConstants.yolov8nBinUrl,
      estimatedSizeMb: 6,
      description: 'Obstacle detection weights',
    ),
    ModelInfo(
      name: 'Silero VAD',
      fileName: AppConstants.sileroVadFile,
      url: AppConstants.sileroVadOnnxUrl,
      estimatedSizeMb: 2,
      description: 'Voice activity detection',
    ),
    // Whisper-tiny is two files: encoder + merged decoder
    ModelInfo(
      name: 'Whisper-tiny Encoder',
      fileName: AppConstants.whisperTinyEncoderFile,
      url: AppConstants.whisperTinyEncoderUrl,
      estimatedSizeMb: 33,
      description: 'Offline STT encoder (all Indian languages)',
    ),
    ModelInfo(
      name: 'Whisper-tiny Decoder',
      fileName: AppConstants.whisperTinyDecoderFile,
      url: AppConstants.whisperTinyDecoderUrl,
      estimatedSizeMb: 119,
      description: 'Offline STT merged decoder (all Indian languages)',
    ),
    ModelInfo(
      name: 'IndicTrans2 INT8',
      fileName: AppConstants.indicTrans2File,
      url: AppConstants.indicTrans2OnnxUrl,
      estimatedSizeMb: 280,
      description: 'Indian language → English translation',
    ),
    ModelInfo(
      name: 'SmolVLM-256M (Vision Projector)',
      fileName: AppConstants.smolvlmFile,
      url: AppConstants.smolvlmGgufUrl,
      estimatedSizeMb: 190,
      description: 'Vision-language model projector',
    ),
    ModelInfo(
      name: 'SmolVLM-256M (Language Model)',
      fileName: AppConstants.smolvlmTextFile,
      url: AppConstants.smolvlmTextGgufUrl,
      estimatedSizeMb: 125,
      description: 'Vision-language model (scene description)',
    ),
  ];

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _modelDir = Directory('${appDir.path}/${AppConstants.modelDirName}');
    if (!await _modelDir.exists()) {
      await _modelDir.create(recursive: true);
    }
    await _refreshStatuses();
  }

  Future<void> _refreshStatuses() async {
    for (final model in models) {
      final file = File('${_modelDir.path}/${model.fileName}');
      if (await file.exists()) {
        model.status = ModelStatus.ready;
        model.progress = 1.0;
      } else {
        model.status = ModelStatus.notDownloaded;
        model.progress = 0.0;
      }
    }
  }

  String modelPath(String fileName) => '${_modelDir.path}/$fileName';

  bool isReady(String fileName) {
    return models
        .where((m) => m.fileName == fileName)
        .any((m) => m.status == ModelStatus.ready);
  }

  bool get coreModelsReady =>
      isReady(AppConstants.yolov8nParamFile) &&
      isReady(AppConstants.yolov8nBinFile) &&
      isReady(AppConstants.sileroVadFile);

  // Both whisper files must be present for offline STT to work
  bool get pipeline2Ready =>
      coreModelsReady &&
      isReady(AppConstants.whisperTinyEncoderFile) &&
      isReady(AppConstants.whisperTinyDecoderFile) &&
      isReady(AppConstants.smolvlmFile) &&
      isReady(AppConstants.smolvlmTextFile);

  Future<bool> downloadModel(ModelInfo model, {int retries = 3}) async {
    // Skip models that require manual download (empty URL)
    if (model.url.isEmpty) {
      model.status = ModelStatus.notDownloaded;
      model.progress = 0.0;
      return false; // Silently skip
    }

    final destFile = File('${_modelDir.path}/${model.fileName}');
    final tempFile = File('${_modelDir.path}/${model.fileName}.tmp');

    // ── Resumable download: check if partial download exists ──
    int startBytes = 0;
    if (await tempFile.exists()) {
      startBytes = await tempFile.length();
      _log.i('Resuming ${model.fileName} from byte $startBytes');
    }

    model.status = ModelStatus.downloading;
    model.progress = startBytes > 0 ? (startBytes / (model.estimatedSizeMb * 1024 * 1024)) : 0.0;
    onStatusChanged?.call(model.fileName, model.status);

    for (int attempt = 1; attempt <= retries; attempt++) {
      try {
        final dio = Dio();

        // ── Set resume headers if partial download exists ──
        final headers = startBytes > 0
            ? {'Range': 'bytes=$startBytes-'}
            : <String, String>{};

        await dio.download(
          model.url,
          tempFile.path,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              model.progress = (startBytes + received) / total;
              onProgress?.call(model.fileName, model.progress);
            }
          },
          options: Options(
            receiveTimeout: const Duration(minutes: 30),
            headers: headers,
          ),
        );

        // Move temp → final
        await tempFile.rename(destFile.path);

        model.status = ModelStatus.ready;
        model.progress = 1.0;
        onStatusChanged?.call(model.fileName, model.status);
        _log.i('Downloaded ${model.fileName}');
        return true;
      } catch (e) {
        _log.e('Download attempt $attempt/$retries failed for ${model.fileName}: $e');
        if (attempt < retries) {
          await Future.delayed(Duration(seconds: 2 * attempt)); // exponential backoff
          startBytes = await tempFile.exists() ? await tempFile.length() : 0;
        }
      }
    }

    // ── All retries failed ──
    if (await tempFile.exists()) await tempFile.delete();
    model.status = ModelStatus.notDownloaded;
    model.progress = 0.0;
    onStatusChanged?.call(model.fileName, model.status);
    return false;
  }

  Future<void> downloadAll({bool allowPartial = true}) async {
    for (final model in models) {
      if (model.url.isEmpty) {
        // Skip models without URLs (like YOLO, IndicTrans2)
        model.status = ModelStatus.notDownloaded;
        continue;
      }
      if (model.status != ModelStatus.ready) {
        final success = await downloadModel(model);
        if (!success && !allowPartial) {
          throw Exception('Failed to download required model: ${model.fileName}');
        }
      }
    }
  }

  /// Graceful degradation: starts pipelines with available models
  bool get essentialModelsReady =>
      isReady(AppConstants.sileroVadFile); // Only VAD is truly essential

  /// Optional: only needed for real-time obstacle detection
  bool get pipeline1Ready =>
      isReady(AppConstants.yolov8nParamFile) &&
      isReady(AppConstants.yolov8nBinFile);

  Future<bool> verifyIntegrity(String fileName) async {
    final expectedHash = AppConstants.modelHashes[fileName];
    if (expectedHash == null || expectedHash.startsWith('placeholder') ||
        expectedHash == 'verify_after_download') {
      return true; // skip verification for placeholder hashes
    }
    final file = File(modelPath(fileName));
    if (!await file.exists()) return false;
    final bytes = await file.readAsBytes();
    final hash = sha256.convert(bytes).toString();
    return hash == expectedHash;
  }

  Future<void> deleteAll() async {
    for (final file in _modelDir.listSync()) {
      await file.delete();
    }
    await _refreshStatuses();
  }

  int get totalDownloadedMb {
    return models
        .where((m) => m.status == ModelStatus.ready)
        .fold(0, (sum, m) => sum + m.estimatedSizeMb);
  }

  int get totalRequiredMb {
    return models.fold(0, (sum, m) => sum + m.estimatedSizeMb);
  }
}