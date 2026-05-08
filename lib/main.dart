import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'app.dart';
import 'core/dpdp_consent.dart';
import 'core/model_manager.dart';
import 'services/tts_service.dart';
import 'services/haptic_service.dart';
import 'services/connectivity_service.dart';
import 'services/language_service.dart';
import 'pipelines/pipeline2/silero_vad.dart';
import 'pipelines/pipeline2/stt_manager.dart';
import 'pipelines/pipeline2/vlm_runner.dart';
import 'pipelines/pipeline2/wake_word_engine.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  // Enumerate cameras
  try {
    cameras = await availableCameras();
  } catch (_) {}

  // Initialise singletons
  await DpdpConsentManager.instance.init();
  await ModelManager.instance.init();
  await TtsService.instance.init();
  await HapticService.instance.init();
  await ConnectivityService.instance.init();
  await LanguageService.instance.init();
  await SttManager.instance.init();
  await WakeWordEngine.instance.init();

  runApp(const NarratorApp());
}
