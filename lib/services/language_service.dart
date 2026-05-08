import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants.dart';
import 'tts_service.dart';

/// Manages user language preferences and TTS locale binding.
class LanguageService {
  LanguageService._();
  static final LanguageService instance = LanguageService._();

  static const String _langKey = 'user_language_code';
  String _currentCode = 'hi';

  String get currentCode => _currentCode;

  Map<String, String> get currentLang => AppConstants.supportedLanguages
      .firstWhere((l) => l['code'] == _currentCode,
          orElse: () => AppConstants.supportedLanguages.first);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _currentCode = prefs.getString(_langKey) ?? 'hi';
    TtsService.instance.setLanguage(_currentCode);
  }

  Future<void> setLanguage(String code) async {
    _currentCode = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_langKey, code);
    TtsService.instance.setLanguage(code);
  }

  String get obstacleAlertText =>
      AppConstants.obstacleAlertMessages[_currentCode] ?? 'Obstacle ahead';
}
