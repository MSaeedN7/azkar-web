import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class PrayerNotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    tz.initializeTimeZones();

    try {
      final String tzName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(tzName));
    } catch (_) {}

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(android: android, iOS: darwin);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {},
    );

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
    }

    _initialized = true;
  }

  static Future<String> scheduleFromLocation() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return 'لم يتم منح إذن الموقع';
    }

    final Position pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 15),
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('saved_lat', pos.latitude);
    await prefs.setDouble('saved_lng', pos.longitude);

    return await _scheduleWeek(pos.latitude, pos.longitude);
  }

  static Future<String> _scheduleWeek(double lat, double lng) async {
    await _plugin.cancelAll();

    final now = DateTime.now();
    int notifId = 0;
    String? todayFajrStr;
    String? todayMaghribStr;

    for (int day = 0; day < 7; day++) {
      final date = now.add(Duration(days: day));
      final url =
          'https://api.aladhan.com/v1/timings/${date.day}-${date.month}-${date.year}'
          '?latitude=$lat&longitude=$lng&method=5';

      try {
        final res = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) continue;

        final data = jsonDecode(res.body);
        final timings = data['data']['timings'] as Map<String, dynamic>;

        final fajrTime = _parseTime(timings['Fajr'] as String, date);
        final maghribTime = _parseTime(timings['Maghrib'] as String, date);

        if (day == 0) {
          todayFajrStr = _fmt(fajrTime);
          todayMaghribStr = _fmt(maghribTime);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('fajr_hour', fajrTime.hour);
          await prefs.setInt('fajr_minute', fajrTime.minute);
          await prefs.setInt('maghrib_hour', maghribTime.hour);
          await prefs.setInt('maghrib_minute', maghribTime.minute);
        }

        if (fajrTime.isAfter(DateTime.now())) {
          await _schedule(
            id: notifId++,
            title: '🌅 أذكار الصباح',
            body: 'حان وقت أذكار الصباح',
            scheduledTime: fajrTime,
          );
        }
        if (maghribTime.isAfter(DateTime.now())) {
          await _schedule(
            id: notifId++,
            title: '🌙 أذكار المساء',
            body: 'حان وقت أذكار المساء',
            scheduledTime: maghribTime,
          );
        }
      } catch (_) {
        continue;
      }
    }

    if (todayFajrStr == null) return 'تعذر جلب أوقات الصلاة';
    return 'تمت الجدولة\nالفجر: $todayFajrStr | المغرب: $todayMaghribStr';
  }

  static Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  static Future<void> scheduleManual({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
  }) =>
      _schedule(
        id: id,
        title: title,
        body: body,
        scheduledTime: scheduledTime,
      );

  static DateTime _parseTime(String timeStr, DateTime base) {
    final parts = timeStr.split(':');
    return DateTime(
      base.year,
      base.month,
      base.day,
      int.parse(parts[0]),
      int.parse(parts[1]),
    );
  }

  static String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  static Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
  }) async {
    final tzTime = tz.TZDateTime.from(scheduledTime, tz.local);
    const androidDetails = AndroidNotificationDetails(
      'azkar_prayer_channel',
      'أذكار الصلاة',
      channelDescription: 'إشعارات أذكار الصباح والمساء',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tzTime,
      const NotificationDetails(android: androidDetails),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}
