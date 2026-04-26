import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'data.dart';

// ─── Task names ──────────────────────────────────────────────────────────────
const kResetMorningHifzTask = 'reset_morning_hifz_v1';
const kResetEveningTask     = 'reset_evening_v1';

// ─── Keys — يجب أن تطابق ما في main.dart تماماً ─────────────────────────────
const _stateKey  = 'native_azkar_state_v2';
const _hifzKey   = 'native_hifz_state_v2';
const _historyKey = 'native_history_v2';

// ─── Callback يُستدعى من WorkManager في الخلفية ─────────────────────────────
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    final prefs = await SharedPreferences.getInstance();

    // ── Reset الصباح وآيات الحفظ عند منتصف الليل ──────────────────────────
    if (taskName == kResetMorningHifzTask) {
      final state = _decodeMap(prefs.getString(_stateKey));
      state['morning'] = List<int>.filled(azkarData.length, 0);
      await prefs.setString(_stateKey, jsonEncode(state));
      await prefs.setString(
        _hifzKey,
        jsonEncode({'items': List<int>.filled(hifzData.length, 0)}),
      );

      // امسح علامة الاكتمال لليوم الجديد (الصباح + الحفظ)
      final today = _todayKey();
      final historyMap = _decodeMap(prefs.getString(_historyKey));
      final entry = historyMap[today] ?? <String, dynamic>{};
      (entry as Map<String, dynamic>)['morning'] = false;
      (entry)['hifz'] = false;
      historyMap[today] = entry;
      await prefs.setString(_historyKey, jsonEncode(historyMap));

      // أعد الجدولة لمنتصف الليل القادم
      await _scheduleMorningReset();
    }

    // ── Reset المساء عند الفجر ─────────────────────────────────────────────
    if (taskName == kResetEveningTask) {
      final state = _decodeMap(prefs.getString(_stateKey));
      state['evening'] = List<int>.filled(azkarData.length, 0);
      await prefs.setString(_stateKey, jsonEncode(state));

      // وقت الفجر = بداية "يوم المساء" الجديد — لا نمسح التاريخ السابق
      // لا نمسح history لأن المساء يُحسب على اليوم السابق
      // فقط أعد قيمة evening لليوم الذي سيأتي (اليوم الحالي بعد الفجر)
      final today = _todayKey();
      final historyMap = _decodeMap(prefs.getString(_historyKey));
      final entry = historyMap[today] ?? <String, dynamic>{};
      (entry as Map<String, dynamic>)['evening'] = false;
      historyMap[today] = entry;
      await prefs.setString(_historyKey, jsonEncode(historyMap));

      // أعد الجدولة لفجر الغد
      await _scheduleEveningReset(prefs);
    }

    return true;
  });
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _decodeMap(String? input) {
  if (input == null || input.isEmpty) return {};
  try {
    return Map<String, dynamic>.from(jsonDecode(input) as Map);
  } catch (_) {
    return {};
  }
}

String _todayKey() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

// ─── جدولة reset الصباح عند 00:00:00 اليوم التالي ───────────────────────────
Future<void> _scheduleMorningReset() async {
  final now = DateTime.now();
  final midnight =
      DateTime(now.year, now.month, now.day + 1, 0, 0, 30); // +30 ثانية هامش
  final delay = midnight.difference(now);

  await Workmanager().registerOneOffTask(
    kResetMorningHifzTask,
    kResetMorningHifzTask,
    initialDelay: delay.isNegative ? Duration.zero : delay,
    constraints: Constraints(networkType: NetworkType.not_required),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}

// ─── جدولة reset المساء عند وقت الفجر المحفوظ ───────────────────────────────
Future<void> _scheduleEveningReset(SharedPreferences prefs) async {
  final fajrHour   = prefs.getInt('fajr_hour')   ?? 5;
  final fajrMinute = prefs.getInt('fajr_minute') ?? 0;
  final now        = DateTime.now();

  // فجر اليوم
  DateTime fajrTime = DateTime(
    now.year, now.month, now.day, fajrHour, fajrMinute, 30,
  );

  // إذا الفجر مضى اليوم → جدول لفجر الغد
  if (fajrTime.isBefore(now)) {
    fajrTime = fajrTime.add(const Duration(days: 1));
  }

  final delay = fajrTime.difference(now);

  await Workmanager().registerOneOffTask(
    kResetEveningTask,
    kResetEveningTask,
    initialDelay: delay.isNegative ? Duration.zero : delay,
    constraints: Constraints(networkType: NetworkType.not_required),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}

// ─── API عام — استدعيه من main() ومن بعد جلب الفجر ──────────────────────────
Future<void> initAndScheduleResets() async {
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: false, // غيّر إلى true لو أردت رؤية لوق التشغيل
  );
  await scheduleAllResets();
}

Future<void> scheduleAllResets() async {
  final prefs = await SharedPreferences.getInstance();
  await _scheduleMorningReset();
  await _scheduleEveningReset(prefs);
}
