import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

Future<void> vibrateFeedback(List<int> pattern) async {
  try {
    final hasVibrator = await Vibration.hasVibrator() == true;
    if (hasVibrator) {
      final hasCustom = await Vibration.hasCustomVibrationsSupport() == true;
      if (hasCustom && pattern.isNotEmpty) {
        await Vibration.vibrate(pattern: pattern);
      } else {
        await Vibration.vibrate(duration: 55);
      }
    } else {
      await HapticFeedback.mediumImpact();
    }
  } catch (_) {
    try {
      await HapticFeedback.mediumImpact();
    } catch (_) {}
  }
}
