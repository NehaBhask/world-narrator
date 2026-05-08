import 'package:vibration/vibration.dart';
import 'package:logger/logger.dart';
import '../core/constants.dart';

/// Haptic feedback service — distinctive pulse pattern for obstacle alerts.
class HapticService {
  HapticService._();
  static final HapticService instance = HapticService._();

  final _log = Logger();
  bool _hasVibrator = false;

  Future<void> init() async {
    _hasVibrator = await Vibration.hasVibrator() ?? false;
    _log.i('Vibrator available: $_hasVibrator');
  }

  /// Three-pulse pattern: distinguishable from system notifications.
  Future<void> obstacleAlert() async {
    if (!_hasVibrator) return;
    await Vibration.vibrate(
      pattern: AppConstants.obstaclePulsePattern,
      intensities: [0, 200, 0, 200, 0, 200],
    );
  }

  /// Single short pulse for wake word confirmation.
  Future<void> wakeWordConfirm() async {
    if (!_hasVibrator) return;
    await Vibration.vibrate(duration: 50, amplitude: 100);
  }

  /// Double pulse for end of P2 response.
  Future<void> responseComplete() async {
    if (!_hasVibrator) return;
    await Vibration.vibrate(pattern: [0, 60, 60, 60], intensities: [0, 150, 0, 150]);
  }

  Future<void> cancel() async {
    await Vibration.cancel();
  }
}
