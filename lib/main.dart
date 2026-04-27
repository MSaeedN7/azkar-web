import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart';
import 'prayer_notification_service.dart';
import 'reset_scheduler.dart';
import 'vibration_helper.dart';
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PrayerNotificationService.init();
  // ✅ جهّز WorkManager لـ auto-reset (صباح عند منتصف الليل، مساء عند الفجر)
  await initAndScheduleResets();
  runApp(const AzkarNativeApp());
}

enum AzkarMode { morning, evening }
enum RootTab { azkar, hifz }
enum SheetTab { streaks, calendar, tasbih, settings }

class AzkarNativeApp extends StatelessWidget {
  const AzkarNativeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'أذكار',
      locale: const Locale('ar'),
      theme: ThemeData(
        useMaterial3: true,
        textTheme: GoogleFonts.scheherazadeNewTextTheme(),
        scaffoldBackgroundColor: const Color(0xFFFDF6E3),
      ),
      home: const AzkarHomePage(),
    );
  }
}

class AzkarHomePage extends StatefulWidget {
  const AzkarHomePage({super.key});

  @override
  State<AzkarHomePage> createState() => _AzkarHomePageState();
}

class _AzkarHomePageState extends State<AzkarHomePage> {
  static const _stateKey = 'native_azkar_state_v2';
  static const _hifzKey = 'native_hifz_state_v2';
  static const _dateKey = 'native_date_v2';
  static const _settingsKey = 'native_settings_v2';
  static const _tasbihKey = 'native_tasbih_v2';
  static const _streaksKey = 'native_streaks_v2';
  static const _historyKey = 'native_history_v2';

  final ScrollController _scrollController = ScrollController();
  final ScrollController _hifzScrollController = ScrollController();

  late final Map<AzkarMode, List<int>> _counts = {
    AzkarMode.morning: List<int>.filled(azkarData.length, 0),
    AzkarMode.evening: List<int>.filled(azkarData.length, 0),
  };
  late final List<int> _hifzCounts = List<int>.filled(hifzData.length, 0);

  late final List<GlobalKey> _azkarKeys =
      List.generate(azkarData.length, (_) => GlobalKey());
  late final List<GlobalKey> _hifzKeys =
      List.generate(hifzData.length, (_) => GlobalKey());

  // Keys to measure actual rendered header + progress height at runtime
  final GlobalKey _headerKey  = GlobalKey();
  final GlobalKey _progressKey = GlobalKey();

  RootTab _rootTab = RootTab.azkar;
  AzkarMode _mode = AzkarMode.morning;
  SheetTab _sheetTab = SheetTab.streaks;

  double _fontSize = 1.35;
  bool _vibrationEnabled = true;
  bool _autoScroll = true;
  bool _notificationsEnabled = false;

  int _tasbihCount33 = 0;
  int _tasbihCountFree = 0;
  int _tasbihTarget = 33;

  int? _savedFajrHour;
  int? _savedFajrMinute;
  int? _savedMaghribHour;
  int? _savedMaghribMinute;

  // ── Manual override: set by user via TimePicker ──────────────────────────
  // null = use GPS value; non-null = user override
  int? _manualFajrHour;
  int? _manualFajrMinute;
  int? _manualMaghribHour;
  int? _manualMaghribMinute;

  bool _isInitialized = false;

  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);

  final Map<String, Map<String, dynamic>> _streaks = {
    'morning': {'streak': 0, 'best': 0, 'lastDate': ''},
    'evening': {'streak': 0, 'best': 0, 'lastDate': ''},
    'hifz': {'streak': 0, 'best': 0, 'lastDate': ''},
  };

  final Map<String, Map<String, bool>> _history = {};

  List<int> get _activeAzkarCounts =>
      _counts[_mode] ?? List<int>.filled(azkarData.length, 0);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadState();
    await PrayerNotificationService.init();
    _applyModeByClock();
    if (mounted) setState(() => _isInitialized = true);
  }


  // ═══════════════════════════════════════════════════════════════════════════
  // منطق التاريخ المنطقي
  //
  // ▸ أذكار المساء: وقتها من المغرب حتى الفجر.
  //   إذا كان الوقت بعد منتصف الليل وقبل الفجر → اليوم المنطقي = أمس
  //   (لأن المستخدم لا يزال في جلسة مساء اليوم السابق).
  //   هذا يضمن:
  //     • السلسلة لا تنقطع لو قرأ أذكار المساء بعد منتصف الليل
  //     • التقويم يُضع النقطة على اليوم الصحيح (أمس)
  //
  // ▸ أذكار الصباح والحفظ: تبدأ عند الفجر وتنتهي عند منتصف الليل.
  //   التاريخ المنطقي = التاريخ الميلادي الحقيقي دائماً.
  // ═══════════════════════════════════════════════════════════════════════════

  String _logicalDate({bool forEvening = false}) {
    final now = DateTime.now();
    if (forEvening) {
      final fajrToday = DateTime(
        now.year, now.month, now.day,
        _effectiveFajrHour, _effectiveFajrMinute,
      );
      if (now.isBefore(fajrToday)) {
        return _dateStr(now.subtract(const Duration(days: 1)));
      }
    }
    return _dateStr(now);
  }

  String _dateStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  // ── Load / Save ───────────────────────────────────────────────────────────
  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _logicalDate(); // الصباح = تاريخ حقيقي
    final savedDate = prefs.getString(_dateKey);

    if (savedDate == today) {
      // نفس اليوم → اقرأ الحالة المحفوظة كما هي
      final map = _decodeMap(prefs.getString(_stateKey));
      final hifzMap = _decodeMap(prefs.getString(_hifzKey));
      _counts[AzkarMode.morning] =
          _decodeIntList(map['morning'], azkarData.length);
      _counts[AzkarMode.evening] =
          _decodeIntList(map['evening'], azkarData.length);
      final hifzList = _decodeIntList(hifzMap['items'], hifzData.length);
      for (int i = 0; i < hifzData.length; i++) {
        _hifzCounts[i] = hifzList[i];
      }
    } else {
      // يوم جديد (تجاوزنا منتصف الليل) → صفّر الصباح والحفظ فقط
      // المساء يُصفَّر عند الفجر بواسطة WorkManager
      final map = _decodeMap(prefs.getString(_stateKey));
      map['morning'] = List<int>.filled(azkarData.length, 0);
      await prefs.setString(_stateKey, jsonEncode(map));
      await prefs.setString(
        _hifzKey,
        jsonEncode({'items': List<int>.filled(hifzData.length, 0)}),
      );
      await prefs.setString(_dateKey, today);

      // ابقِ على قيم المساء لو المستخدم لا يزال في جلسة المساء
      _counts[AzkarMode.evening] =
          _decodeIntList(map['evening'], azkarData.length);
    }

    final settings = _decodeMap(prefs.getString(_settingsKey));
    _vibrationEnabled = settings['vibration'] ?? true;
    _autoScroll = settings['autoScroll'] ?? true;
    _notificationsEnabled = settings['notifications'] ?? false;
    _vibrationEnabled = false;
    _notificationsEnabled = false;
    final savedFontSize = (settings['fontSize'] ?? 1.35).toDouble();
    if ((savedFontSize - 1.32).abs() < 0.02) {
      _fontSize = 1.35;
    } else if ((savedFontSize - 1.60).abs() < 0.02) {
      _fontSize = 1.85;
    } else if ((savedFontSize - 1.05).abs() < 0.02) {
      _fontSize = 0.95;
    } else {
      _fontSize = savedFontSize;
    }

    final tasbih = _decodeMap(prefs.getString(_tasbihKey));
    _tasbihTarget = tasbih['target'] ?? 33;
    _tasbihCount33 = tasbih['count33'] ?? 0;
    _tasbihCountFree = tasbih['countFree'] ?? 0;
    final legacyCount = tasbih['count'];
    if (legacyCount is int) {
      if (_tasbihTarget == 0 && _tasbihCountFree == 0) {
        _tasbihCountFree = legacyCount;
      } else if (_tasbihTarget != 0 && _tasbihCount33 == 0) {
        _tasbihCount33 = legacyCount;
      }
    }

    _savedFajrHour = prefs.getInt('fajr_hour');
    _savedFajrMinute = prefs.getInt('fajr_minute');
    _savedMaghribHour = prefs.getInt('maghrib_hour');
    _savedMaghribMinute = prefs.getInt('maghrib_minute');

    // manual overrides — null if never set
    final mfh = prefs.getInt('manual_fajr_hour');
    final mfm = prefs.getInt('manual_fajr_minute');
    final mmh = prefs.getInt('manual_maghrib_hour');
    final mmm = prefs.getInt('manual_maghrib_minute');
    _manualFajrHour    = mfh;
    _manualFajrMinute  = mfm;
    _manualMaghribHour = mmh;
    _manualMaghribMinute = mmm;

    // apply overrides to live fajr fields so _applyModeByClock uses them
    if (_manualFajrHour != null)   _savedFajrHour   = _manualFajrHour;
    if (_manualFajrMinute != null) _savedFajrMinute  = _manualFajrMinute;

    final streaks = _decodeMap(prefs.getString(_streaksKey));
    for (final key in _streaks.keys) {
      final value = streaks[key];
      if (value is Map) {
        _streaks[key] = {
          'streak': value['streak'] ?? 0,
          'best': value['best'] ?? 0,
          'lastDate': value['lastDate'] ?? '',
        };
      }
    }

    final historyMap = _decodeMap(prefs.getString(_historyKey));
    for (final entry in historyMap.entries) {
      final value = entry.value;
      if (value is Map) {
        _history[entry.key] = {
          'morning': value['morning'] == true,
          'evening': value['evening'] == true,
          'hifz': value['hifz'] == true,
        };
      }
    }
  }

  Map<String, dynamic> _decodeMap(String? input) {
    if (input == null || input.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(input) as Map);
    } catch (_) {
      return {};
    }
  }

  List<int> _decodeIntList(dynamic input, int size) {
    if (input is List) {
      final vals = input.map((e) => (e as num).toInt()).toList();
      return vals.length == size ? vals : List<int>.filled(size, 0);
    }
    return List<int>.filled(size, 0);
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dateKey, _logicalDate());
    await prefs.setString(
      _stateKey,
      jsonEncode({
        'morning': _counts[AzkarMode.morning],
        'evening': _counts[AzkarMode.evening],
      }),
    );
    await prefs.setString(_hifzKey, jsonEncode({'items': _hifzCounts}));
    await prefs.setString(
      _settingsKey,
      jsonEncode({
        'vibration': _vibrationEnabled,
        'autoScroll': _autoScroll,
        'notifications': _notificationsEnabled,
        'fontSize': _fontSize,
      }),
    );
    await prefs.setString(
      _tasbihKey,
      jsonEncode({
        'count33': _tasbihCount33,
        'countFree': _tasbihCountFree,
        'target': _tasbihTarget,
      }),
    );
    await prefs.setString(_streaksKey, jsonEncode(_streaks));
    await prefs.setString(_historyKey, jsonEncode(_history));
  }

  // ── وضع الصباح/المساء بناءً على وقت الفجر الحقيقي ────────────────────────
  void _applyModeByClock() {
  final now = DateTime.now();

  final fajr = DateTime(
    now.year,
    now.month,
    now.day,
    _effectiveFajrHour,
    _effectiveFajrMinute,
  );

  final maghrib = DateTime(
    now.year,
    now.month,
    now.day,
    _effectiveMaghribHour,
    _effectiveMaghribMinute,
  );

  if (now.isBefore(fajr)) {
    _mode = AzkarMode.evening;
  } else if (now.isBefore(maghrib)) {
    _mode = AzkarMode.morning;
  } else {
    _mode = AzkarMode.evening;
  }

  _setSystemBars();
}

  // ── الوقت الفعلي المستخدم: override إن وُجد، وإلا GPS ───────────────────
  int get _effectiveFajrHour      => _manualFajrHour      ?? _savedFajrHour    ?? 5;
  int get _effectiveFajrMinute    => _manualFajrMinute    ?? _savedFajrMinute  ?? 0;
  int get _effectiveMaghribHour   => _manualMaghribHour   ?? _savedMaghribHour   ?? 18;
  int get _effectiveMaghribMinute => _manualMaghribMinute ?? _savedMaghribMinute ?? 0;


  Future<void> _vibrate([List<int> pattern = const [0, 55]]) async {
    if (!_vibrationEnabled) return;
    await vibrateFeedback(pattern);
  }

  int _targetForAzkar(int index) {
    final raw = azkarData[index].count;
    return raw <= 0 ? 1 : raw;
  }

  int _targetForHifz(int index) {
    final raw = hifzData[index].count ?? 1;
    return raw <= 0 ? 1 : raw;
  }

  int get _activeTasbihCount => _tasbihTarget == 0 ? _tasbihCountFree : _tasbihCount33;

  void _incrementTasbihCount() {
    if (_tasbihTarget == 0) {
      _tasbihCountFree++;
    } else {
      _tasbihCount33++;
    }
  }

  void _resetActiveTasbihCount() {
    if (_tasbihTarget == 0) {
      _tasbihCountFree = 0;
    } else {
      _tasbihCount33 = 0;
    }
  }

  Future<void> _incrementAzkar(int index) async {
    final items = _activeAzkarCounts;
    final target = _targetForAzkar(index);
    if (items[index] >= target) return;

    setState(() => items[index]++);
    await _vibrate();
    await _saveState();

    if (items[index] >= target) {
      await _checkCompletion();
      if (_autoScroll) {
        final next = _nextIncompleteAzkarIndex(items);
        if (next != null) await _scrollToKey(_azkarKeys[next]);
      }
    }
  }

  Future<void> _incrementHifz(int index) async {
    final target = _targetForHifz(index);
    if (_hifzCounts[index] >= target) return;

    setState(() => _hifzCounts[index]++);
    await _vibrate();
    await _saveState();

    if (_hifzCounts[index] >= target) {
      await _checkCompletion();
      if (_autoScroll) {
        final next = _nextIncompleteHifzIndex();
        if (next != null) await _scrollToKey(_hifzKeys[next]);
      }
    }
  }

  int? _nextIncompleteAzkarIndex(List<int> items) {
    for (int i = 0; i < items.length; i++) {
      if (items[i] < _targetForAzkar(i)) return i;
    }
    return null;
  }

  int? _nextIncompleteHifzIndex() {
    for (int i = 0; i < _hifzCounts.length; i++) {
      if (_hifzCounts[i] < _targetForHifz(i)) return i;
    }
    return null;
  }

  Future<void> _scrollToKey(GlobalKey key) async {
    final controller =
        _rootTab == RootTab.hifz ? _hifzScrollController : _scrollController;
    if (!controller.hasClients) return;

    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;

    final renderObj = key.currentContext?.findRenderObject();
    final headerRender = _headerKey.currentContext?.findRenderObject();
    final progressRender = _progressKey.currentContext?.findRenderObject();
    if (renderObj is! RenderBox) return;

    final target = renderObj;

    // Measure the actual rendered height of header + progress bar
    double fixedAreaHeight = 0;
    if (headerRender is RenderBox)   fixedAreaHeight += headerRender.size.height;
    if (progressRender is RenderBox) fixedAreaHeight += progressRender.size.height;
    // Fallback if keys aren't attached yet
    if (fixedAreaHeight < 10) fixedAreaHeight = 180;

    final viewportHeight = MediaQuery.of(context).size.height;
    final availableHeight =
        (viewportHeight - fixedAreaHeight).clamp(120.0, double.infinity);
    final cardHeight = target.size.height;
    const double topPadding = 10.0;
    final centerOffset = (availableHeight - cardHeight) / 2;
    final desiredTopOffset = cardHeight > availableHeight * 0.72
        ? topPadding
        : centerOffset.clamp(topPadding, availableHeight / 2);

    // Short cards can sit near the middle comfortably, but long cards
    // should start close to the top so their first lines remain visible.
    final cardScreenTop = target.localToGlobal(Offset.zero).dy;
    final newOffset = controller.offset +
        cardScreenTop -
        fixedAreaHeight -
        desiredTopOffset;

    await controller.animateTo(
      newOffset.clamp(0.0, controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOut,
    );
  }

  Future<void> _checkCompletion() async {
    final key = _rootTab == RootTab.hifz
        ? 'hifz'
        : (_mode == AzkarMode.morning ? 'morning' : 'evening');

    final completed = _rootTab == RootTab.hifz
        ? _hifzCounts.asMap().entries.every((e) {
            final rawCount = hifzData[e.key].count ?? 0;
            if (rawCount <= 0) return true;
            return e.value >= rawCount;
          })
        : _activeAzkarCounts.asMap().entries
            .every((e) => e.value >= _targetForAzkar(e.key));

    if (!completed || !mounted) return;

    // ✅ المساء يستخدم forEvening: true → يحسب على التاريخ الصحيح حتى لو بعد منتصف الليل
    final today = _logicalDate(forEvening: key == 'evening');
    final alreadyMarked = _history[today]?[key] == true;
    if (alreadyMarked) return;

    await _markHistoryComplete(key);
    await _updateStreak(key);

    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await _showCompletionScreen();
    });
  }

  Future<void> _showCompletionScreen() async {
    final colors = _modeColors;
    final icon = _rootTab == RootTab.hifz
        ? Icons.shield_rounded
        : Icons.volunteer_activism_rounded;
    final subtitle = _rootTab == RootTab.hifz
        ? 'اكتملت آيات الحفظ'
        : _mode == AzkarMode.morning
            ? 'اكتملت أذكار الصباح'
            : 'اكتملت أذكار المساء';
    final secondary =
        _rootTab == RootTab.hifz ? 'حفظك الله ورعاك 🤲' : 'تقبّل الله منك 🤲';

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'completion',
      barrierColor: colors.background.withValues(alpha: 0.92),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Material(
            color: Colors.transparent,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        color: colors.card,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.border),
                        boxShadow: [
                          BoxShadow(
                            color: colors.accent.withValues(alpha: 0.18),
                            blurRadius: 22,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Icon(icon, size: 48, color: colors.accent),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'أحسنت!',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.scheherazadeNew(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        color: colors.title,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.amiri(
                          fontSize: 22, height: 1.6, color: colors.text),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      secondary,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.amiri(
                        fontSize: 20,
                        height: 1.6,
                        color: colors.accentText.withValues(alpha: 0.88),
                      ),
                    ),
                    const SizedBox(height: 26),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.accent,
                        foregroundColor:
                            _rootTab == RootTab.hifz || _mode == AzkarMode.morning
                                ? Colors.white
                                : colors.buttonFg,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 34, vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999)),
                      ),
                      child: Text(
                        'العودة',
                        style: GoogleFonts.scheherazadeNew(
                            fontSize: 22, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _markHistoryComplete(String key) async {
    final today = _logicalDate(forEvening: key == 'evening');
    final entry =
        _history[today] ?? {'morning': false, 'evening': false, 'hifz': false};
    entry[key] = true;
    _history[today] = entry;
    await _saveState();
  }

  Future<void> _updateStreak(String key) async {
    final todayKey = _logicalDate(forEvening: key == 'evening');
    final entry = _streaks[key] ?? {'streak': 0, 'best': 0, 'lastDate': ''};
    final lastDate = entry['lastDate'] as String? ?? '';

    if (lastDate == todayKey) return;

    int streak = (entry['streak'] as int?) ?? 0;
    final best = (entry['best'] as int?) ?? 0;

    if (lastDate.isNotEmpty) {
      final prev = DateTime.tryParse(lastDate);
      final logicalToday = DateTime.tryParse(todayKey)!;
      if (prev != null &&
          logicalToday
                  .difference(DateTime(prev.year, prev.month, prev.day))
                  .inDays ==
              1) {
        streak += 1;
      } else {
        streak = 1;
      }
    } else {
      streak = 1;
    }

    entry['streak'] = streak;
    entry['best'] = streak > best ? streak : best;
    entry['lastDate'] = todayKey;
    _streaks[key] = entry;
    await _saveState();
  }

  Future<void> _resetCurrent() async {
    final key = _rootTab == RootTab.hifz
        ? 'hifz'
        : (_mode == AzkarMode.morning ? 'morning' : 'evening');
    final today = _logicalDate(forEvening: key == 'evening');

    if (_rootTab == RootTab.hifz) {
      setState(() {
        for (int i = 0; i < _hifzCounts.length; i++) { _hifzCounts[i] = 0; }
      });
    } else {
      setState(() {
        _counts[_mode] = List<int>.filled(azkarData.length, 0);
      });
    }

    if (_history[today] != null) {
      _history[today]![key] = false;
    }

    await _saveState();
  }

  void _handleHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 120) return;
    setState(() {
      _rootTab = _rootTab == RootTab.azkar ? RootTab.hifz : RootTab.azkar;
    });
  }

  void _setSystemBars() {
    final colors = _modeColors;
    final darkIcons = _rootTab == RootTab.hifz || _mode == AzkarMode.morning;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: colors.background,
        systemNavigationBarDividerColor: colors.background,
        statusBarIconBrightness:
            darkIcons ? Brightness.dark : Brightness.light,
        systemNavigationBarIconBrightness:
            darkIcons ? Brightness.dark : Brightness.light,
      ),
    );
  }

  _ModeColors get _modeColors {
    if (_rootTab == RootTab.hifz) {
      return const _ModeColors(
        background: Color(0xFFE8F4FD),
        card: Color(0xFFFFFFFF),
        text: Color(0xFF0D2A3D),
        border: Color(0x332A7ABF),
        accent: Color(0xFF2A7ABF),
        accentText: Color(0xFF0D3A5C),
        title: Color(0xFF0D3A5C),
        chipBg: Color(0xFFFFFFFF),
        chipSelected: Color(0xFF2A7ABF),
        buttonFg: Color(0xFFFFFFFF),
      );
    }
    if (_mode == AzkarMode.morning) {
      return const _ModeColors(
        background: Color(0xFFFDF6E3),
        card: Color(0xFFFFFAEB),
        text: Color(0xFF2C1F0E),
        border: Color(0x338B6914),
        accent: Color(0xFFC9A84C),
        accentText: Color(0xFF5A3A0A),
        title: Color(0xFF5A3A0A),
        chipBg: Color(0xFFFFFAEB),
        chipSelected: Color(0xFFC9A84C),
        buttonFg: Color(0xFF2C1F0E),
      );
    }
    return const _ModeColors(
      background: Color(0xFF170A26),
      card: Color(0xFF342C43),
      text: Color(0xFFF2E3BC),
      border: Color(0x44C9A84C),
      accent: Color(0xFFC9A84C),
      accentText: Color(0xFFE8D08A),
      title: Color(0xFFE8D08A),
      chipBg: Color(0xFF3E3551),
      chipSelected: Color(0xFF6A5E79),
      buttonFg: Color(0xFF24163A),
    );
  }

  int get _completedItemsCount {
    if (_rootTab == RootTab.hifz) {
      int done = 0;
      for (int i = 0; i < _hifzCounts.length; i++) {
        final rawCount = hifzData[i].count ?? 0;
        if (rawCount <= 0) continue;
        if (_hifzCounts[i] >= rawCount) done++;
      }
      return done;
    }
    int done = 0;
    final items = _activeAzkarCounts;
    for (int i = 0; i < items.length; i++) {
      if (items[i] >= _targetForAzkar(i)) done++;
    }
    return done;
  }

  int get _totalItemsCount {
    if (_rootTab == RootTab.hifz) {
      return hifzData.where((item) => (item.count ?? 0) > 0).length;
    }
    return azkarData.length;
  }

  double get _progress =>
      _totalItemsCount == 0
          ? 0
          : (_completedItemsCount / _totalItemsCount).clamp(0, 1);

  String get _progressText => '$_totalItemsCount / $_completedItemsCount';

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final colors = _modeColors;
    _setSystemBars();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: colors.background,
          body: !_isInitialized
              ? const Center(child: CircularProgressIndicator())
              : GestureDetector(
                  onHorizontalDragEnd: _handleHorizontalSwipe,
                  child: Stack(
                    children: [
                      if (_mode == AzkarMode.evening && _rootTab == RootTab.azkar)
                        const _EveningStarsBackground(),
                      SafeArea(
                        top: false,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                colors.background,
                                colors.background.withValues(alpha: 0.98),
                              ],
                            ),
                          ),
                          child: Column(
                            children: [
                              _buildHeader(colors, key: _headerKey),
              _buildProgress(colors, key: _progressKey),
                              Expanded(
                                child: _rootTab == RootTab.hifz
                                    ? _buildHifzList(colors)
                                    : _buildAzkarList(colors),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          bottomNavigationBar: _buildBottomBar(colors),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _resetCurrent,
            backgroundColor: colors.chipBg,
            foregroundColor: colors.accentText,
            elevation: 10,
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('إعادة البدء'),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
        ),
      ),
    );
  }

  Widget _buildHeader(_ModeColors colors, {Key? key}) {
    final title = _rootTab == RootTab.hifz
        ? 'آيَاتُ الحِفْظ'
        : _mode == AzkarMode.morning
            ? 'أَذْكَارُ الصَّبَاحِ'
            : 'أَذْكَارُ المَسَاءِ';

    final subtitle = _rootTab == RootTab.hifz
        ? 'ورد الحفظ والتحصين'
        : _mode == AzkarMode.morning
            ? 'من الفجر إلى المغرب'
            : 'من المغرب إلى الفجر';

    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 46, 16, 18),
      decoration:
          BoxDecoration(border: Border(bottom: BorderSide(color: colors.border))),
      child: Column(
        children: [
          Row(
            textDirection: TextDirection.rtl,
            children: [
              IconButton(
                onPressed: _openBottomSheet,
                icon: Icon(Icons.more_vert_rounded,
                    color: colors.accentText, size: 30),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      'بِسْمِ اللهِ الرَّحْمَنِ الرَّحِيمِ',
                      style: GoogleFonts.amiri(
                        color: colors.accentText.withValues(alpha: 0.72),
                        fontSize: 19,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.scheherazadeNew(
                        color: colors.title,
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: GoogleFonts.amiri(
                        color: colors.accentText.withValues(alpha: 0.72),
                        fontSize: 19,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
          if (_rootTab == RootTab.azkar) ...[
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildModeButton('الصباح', AzkarMode.morning, colors,
                      icon: Icons.wb_sunny_rounded),
                  _buildModeButton('المساء', AzkarMode.evening, colors,
                      icon: Icons.nights_stay_rounded),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeButton(String label, AzkarMode mode, _ModeColors colors,
      {IconData? icon}) {
    final active = _mode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => setState(() => _mode = mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: active
              ? colors.accent
                  .withValues(alpha: _mode == AzkarMode.morning ? 1 : 0.18)
              : Colors.transparent,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          textDirection: TextDirection.rtl,
          children: [
            Text(
              label,
              style: GoogleFonts.scheherazadeNew(
                color: active && _mode == AzkarMode.morning
                    ? colors.background
                    : colors.accentText,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (icon != null) ...[
              const SizedBox(width: 3),
              Icon(
                icon,
                size: 19,
                color: active && _mode == AzkarMode.morning
                    ? colors.background
                    : colors.accentText,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProgress(_ModeColors colors, {Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: Column(
        children: [
          Row(
            textDirection: TextDirection.rtl,
            children: [
              Text('التقدم',
                  style: TextStyle(
                      color: colors.accentText.withValues(alpha: 0.8), fontSize: 18)),
              const Spacer(),
              Text(_progressText,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                      color: colors.accentText.withValues(alpha: 0.8), fontSize: 18)),
            ],
          ),
          const SizedBox(height: 8),
          Directionality(
            textDirection: TextDirection.rtl,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 7,
                backgroundColor: colors.border.withValues(alpha: 0.4),
                valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAzkarList(_ModeColors colors) {
    final items = _activeAzkarCounts;
    return ListView.builder(
      key: const PageStorageKey('azkar_list'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
      itemCount: azkarData.length,
      itemBuilder: (context, index) {
        final item = azkarData[index];
        final currentCount = items[index];
        final target = _targetForAzkar(index);
        final done = currentCount >= target;
        final text =
            _mode == AzkarMode.morning ? (item.s ?? '') : (item.e ?? item.s ?? '');
        final note = _mode == AzkarMode.morning ? item.ns : item.ne;

        return _buildZikrCard(
          cardKey: _azkarKeys[index],
          colors: colors,
          index: index,
          text: text,
          note: note ?? '',
          fadl: item.fadl ?? '',
          topText: index == 2
          ? 'أَعُوذُ بِاللهِ مِنَ الشَّيْطَانِ الرَّجِيمِ'
              : '',
          currentCount: currentCount,
          targetCount: target,
          done: done,
          onTap: () => _incrementAzkar(index),
        );
      },
    );
  }

  Widget _buildHifzList(_ModeColors colors) {
    return ListView.builder(
      key: const PageStorageKey('hifz_list'),
      controller: _hifzScrollController,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
      itemCount: hifzData.length,
      itemBuilder: (context, index) {
        final item = hifzData[index];
        final currentCount = _hifzCounts[index];
        final target = _targetForHifz(index);
        final done = currentCount >= target;
        final source = item.source ?? '';

        String topText = '';
        String displayText = item.text ?? item.s ?? '';
        const basmalaTag = '﴿بِسْمِ اللهِ الرَّحْمَنِ الرَّحِيمِ﴾';

        if (source.contains('الكرسي')) {
          topText =
              'أَعُوذُ بِاللهِ مِنَ الشَّيْطَانِ الرَّجِيمِ\n﴿بِسْمِ اللهِ الرَّحْمَنِ الرَّحِيمِ﴾';
        } else if (source.contains('البقرة') || source.contains('البروج')) {
          topText = '﴿بِسْمِ اللهِ الرَّحْمَنِ الرَّحِيمِ﴾';
        } else if (source.contains('الإخلاص') ||
            source.contains('الفلق') ||
            source.contains('الناس')) {
          if (displayText.startsWith(basmalaTag)) {
            topText = basmalaTag;
            displayText = displayText.substring(basmalaTag.length).trimLeft();
          }
        }

        return _buildZikrCard(
          cardKey: _hifzKeys[index],
          colors: colors,
          index: index,
          text: displayText,
          note: source,
          fadl: '',
          topText: topText,
          currentCount: currentCount,
          targetCount: target,
          done: done,
          onTap: () => _incrementHifz(index),
        );
      },
    );
  }

  Widget _buildZikrCard({
    required GlobalKey cardKey,
    required _ModeColors colors,
    required int index,
    required String text,
    required String note,
    required String fadl,
    required String topText,
    required int currentCount,
    required int targetCount,
    required bool done,
    required VoidCallback onTap,
  }) {
    final compactDots = targetCount >= 7;
    final dotSize = targetCount >= 30 ? 7.0 : (compactDots ? 8.0 : 9.0);
    final dotSpacing = targetCount >= 30 ? 5.0 : 6.0;
    final dotsMaxWidth = targetCount >= 30 ? 170.0 : 150.0;

    return AnimatedOpacity(
      key: cardKey,
      duration: const Duration(milliseconds: 250),
      opacity: done ? 0.55 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: colors.border),
          boxShadow: [
            BoxShadow(
              color: colors.accent
                  .withValues(alpha: _mode == AzkarMode.evening ? 0.08 : 0.05),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('${index + 1}',
                      style: TextStyle(
                          color: colors.accentText.withValues(alpha: 0.35))),
                  const Spacer(),
                  if (done)
                    Row(
                      children: [
                        Text('اكتمل',
                            style: GoogleFonts.scheherazadeNew(
                              color: const Color(0xFF5EB36C),
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            )),
                        const SizedBox(width: 4),
                        const Icon(Icons.check,
                            size: 18, color: Color(0xFF5EB36C)),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (topText.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    topText,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.scheherazadeNew(
                      fontSize: 14 * _fontSize,
                      height: 1.7,
                      color: colors.accentText.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                text,
                textAlign: TextAlign.justify,
                textDirection: TextDirection.rtl,
                style: GoogleFonts.scheherazadeNew(
                  fontSize: 18 * _fontSize,
                  height: 1.95,
                  color: colors.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (note.isNotEmpty) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    note,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.amiri(
                      color: colors.accentText.withValues(alpha: 0.7),
                      fontSize: 14 * _fontSize,
                    ),
                  ),
                ),
              ],
              if (fadl.isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: () => _showFadlPopup(fadl),
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('فضل الذكر'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.accentText,
                      side: BorderSide(color: colors.border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999)),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                textDirection: TextDirection.ltr,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildTapButton(colors, done, onTap),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Row(
                          textDirection: TextDirection.rtl,
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              '$targetCount / $currentCount',
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                color: colors.accentText,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 10),
                            ConstrainedBox(
                              constraints:
                                  BoxConstraints(maxWidth: dotsMaxWidth),
                              child: Wrap(
                                spacing: dotSpacing,
                                runSpacing: dotSpacing,
                                alignment: WrapAlignment.start,
                                children: List.generate(targetCount, (dotIdx) {
                                  final filled = dotIdx < currentCount;
                                  return AnimatedContainer(
                                    duration:
                                        const Duration(milliseconds: 160),
                                    width: dotSize,
                                    height: dotSize,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: filled
                                          ? colors.accent
                                          : Colors.transparent,
                                      border: Border.all(
                                        color: colors.accent.withValues(alpha: 0.8),
                                        width: targetCount >= 30 ? 1.0 : 1.2,
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTapButton(_ModeColors colors, bool done, VoidCallback onTap) {
    return GestureDetector(
      onTap: done ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done
              ? const Color(0xFF4CAF50).withValues(alpha: 0.12)
              : Colors.transparent,
          border: Border.all(
            color: done
                ? const Color(0xFF4CAF50)
                : colors.accent.withValues(alpha: 0.78),
            width: 2,
          ),
        ),
        child: Center(
          child: done
              ? const Icon(Icons.check_rounded,
                  color: Color(0xFF4CAF50), size: 30)
              : SvgPicture.asset(
                  'assets/SVG/dhikr_button_clean.svg',
                  width: 38,
                  height: 38,
                  colorFilter: ColorFilter.mode(
                    colors.accent,
                    BlendMode.srcIn,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(_ModeColors colors) {
    final hifzComplete = _hifzCounts
        .asMap()
        .entries
        .every((e) => e.value >= _targetForHifz(e.key));
    final azkarComplete = _activeAzkarCounts
        .asMap()
        .entries
        .every((e) => e.value >= _targetForAzkar(e.key));

    return SafeArea(
      top: false,
      child: Container(
        height: 72,
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Row(
          textDirection: TextDirection.rtl,
          children: [
            _buildTabButton(
              title: _rootTab == RootTab.azkar
                  ? (_mode == AzkarMode.morning
                      ? 'أذكار الصباح'
                      : 'أذكار المساء')
                  : 'الأذكار',
              icon: Icons.volunteer_activism_rounded,
              active: _rootTab == RootTab.azkar,
              colors: colors,
              done: azkarComplete,
              onTap: () => setState(() => _rootTab = RootTab.azkar),
            ),
            _buildTabButton(
              title: 'آيات الحفظ',
              icon: Icons.shield_moon_rounded,
              active: _rootTab == RootTab.hifz,
              colors: colors,
              done: hifzComplete,
              onTap: () => setState(() => _rootTab = RootTab.hifz),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton({
    required String title,
    required IconData icon,
    required bool active,
    required bool done,
    required _ModeColors colors,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon,
                    color: active
                        ? colors.accentText
                        : colors.accentText.withValues(alpha: 0.45)),
                if (done)
                  const Positioned(
                    top: -4,
                    left: -6,
                    child: CircleAvatar(
                      radius: 7,
                      backgroundColor: Color(0xFF4CAF50),
                      child: Icon(Icons.check, color: Colors.white, size: 10),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.scheherazadeNew(
                fontSize: 16,
                color: active
                    ? colors.accentText
                    : colors.accentText.withValues(alpha: 0.45),
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openBottomSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _modeColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModal) {
            Widget page;
            switch (_sheetTab) {
              case SheetTab.streaks:
                page = _buildStreaksPage(_modeColors);
                break;
              case SheetTab.calendar:
                page = _buildCalendarPage(_modeColors, setModal);
                break;
              case SheetTab.tasbih:
                page = _buildTasbihPage(_modeColors, setModal);
                break;
              case SheetTab.settings:
                page = _buildSettingsPage(_modeColors, setModal);
                break;
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: _modeColors.border,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        _sheetTabBtn('السلاسل', SheetTab.streaks, setModal,
                            icon: Icons.local_fire_department_rounded),
                        _sheetTabBtn('التقويم', SheetTab.calendar, setModal,
                            icon: Icons.calendar_month_rounded),
                        _sheetTabBtn('السبحة', SheetTab.tasbih, setModal,
                            svgAsset: 'assets/SVG/tasbih-clean.svg'),
                        _sheetTabBtn('الإعدادات', SheetTab.settings, setModal,
                            icon: Icons.settings_rounded),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: SingleChildScrollView(child: page),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _sheetTabBtn(String text, SheetTab tab, StateSetter setModal,
      {IconData? icon, String? svgAsset}) {
    final active = _sheetTab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setModal(() => _sheetTab = tab),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: active
                ? _modeColors.chipSelected
                : _modeColors.chipBg.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.rtl,
            children: [
              Text(
                text,
                textAlign: TextAlign.center,
                style: GoogleFonts.scheherazadeNew(
                  color: _modeColors.accentText,
                  fontSize: 18,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (svgAsset != null) ...[
                const SizedBox(width: 3),
                SvgPicture.asset(
                  svgAsset,
                  width: 22,
                  height: 22,
                  colorFilter: ColorFilter.mode(
                    _modeColors.accentText,
                    BlendMode.srcIn,
                  ),
                ),
              ] else if (icon != null) ...[
                const SizedBox(width: 3),
                Icon(
                  icon,
                  size: 18,
                  color: _modeColors.accentText,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStreaksPage(_ModeColors colors) {
    Widget box(String title, String key, IconData icon) {
      final entry = _streaks[key] ?? {'streak': 0, 'best': 0};
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          textDirection: TextDirection.rtl,
          children: [
            Expanded(
              child: Row(
                textDirection: TextDirection.rtl,
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.rtl,
                      children: [
                        Text(
                          title,
                          textAlign: TextAlign.right,
                          style: GoogleFonts.scheherazadeNew(
                              fontSize: 24, color: colors.text),
                        ),
                        const SizedBox(width: 3),
                        Icon(
                          icon,
                          size: 22,
                          color: colors.accentText.withValues(alpha: 0.9),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Column(
              children: [
                Text('${entry['streak'] ?? 0}',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: colors.accentText)),
                Text('الحالية',
                    style:
                        TextStyle(color: colors.accentText.withValues(alpha: 0.65))),
              ],
            ),
            const SizedBox(width: 16),
            Column(
              children: [
                Text('${entry['best'] ?? 0}',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: colors.accentText)),
                Text('الأطول',
                    style:
                        TextStyle(color: colors.accentText.withValues(alpha: 0.65))),
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        box('أذكار الصباح', 'morning', Icons.wb_sunny_rounded),
        box('أذكار المساء', 'evening', Icons.nights_stay_rounded),
        box('آيات الحفظ', 'hifz', Icons.shield_rounded),
      ],
    );
  }

  Widget _buildCalendarPage(_ModeColors colors, StateSetter setModal) {
    final monthStart =
        DateTime(_calendarMonth.year, _calendarMonth.month, 1);
    final daysInMonth =
        DateTime(_calendarMonth.year, _calendarMonth.month + 1, 0).day;
    final leadingEmpty = (6 - monthStart.weekday) % 7;
    final totalCells = leadingEmpty + daysInMonth;
    final trailingEmpty = (7 - (totalCells % 7)) % 7;

    const monthNames = [
      'يناير','فبراير','مارس','أبريل','مايو','يونيو',
      'يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر',
    ];
    const weekDays = ['سبت','جمع','خمي','أرب','ثلا','اثن','أحد'];

    Widget legendDot(Color color, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(label,
                style:
                    TextStyle(color: colors.accentText.withValues(alpha: 0.8))),
          ],
        );

    return Column(
      children: [
        Row(
          textDirection: TextDirection.rtl,
          children: [
            IconButton(
              onPressed: () => setModal(() {
                _calendarMonth =
                    DateTime(_calendarMonth.year, _calendarMonth.month + 1, 1);
              }),
              icon: Icon(Icons.chevron_right_rounded, color: colors.accentText),
            ),
            Expanded(
              child: Text(
                '${monthNames[_calendarMonth.month - 1]} ${_calendarMonth.year}',
                textAlign: TextAlign.center,
                style: GoogleFonts.scheherazadeNew(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: colors.title,
                ),
              ),
            ),
            IconButton(
              onPressed: () => setModal(() {
                _calendarMonth =
                    DateTime(_calendarMonth.year, _calendarMonth.month - 1, 1);
              }),
              icon:
                  Icon(Icons.chevron_left_rounded, color: colors.accentText),
            ),
          ],
        ),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          runSpacing: 8,
          children: [
            legendDot(const Color(0xFFF59E0B), 'الصباح'),
            legendDot(const Color(0xFF8B5CF6), 'المساء'),
            legendDot(const Color(0xFF3B82F6), 'الحفظ'),
          ],
        ),
        const SizedBox(height: 12),
        Directionality(
          textDirection: TextDirection.rtl,
          child: GridView.builder(
          itemCount:
              weekDays.length + leadingEmpty + daysInMonth + trailingEmpty,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisExtent: 72,
          ),
          itemBuilder: (context, index) {
            if (index < weekDays.length) {
              return Center(
                child: Text(weekDays[index],
                    style: TextStyle(
                        color: colors.accentText.withValues(alpha: 0.6))),
              );
            }

            final dayIndex = index - weekDays.length;
            if (dayIndex < leadingEmpty ||
                dayIndex >= leadingEmpty + daysInMonth) {
              return const SizedBox.shrink();
            }

            final day = dayIndex - leadingEmpty + 1;
            final date =
                DateTime(_calendarMonth.year, _calendarMonth.month, day);
            final dateKey = _dateStr(date);
            final entry = _history[dateKey] ??
                {'morning': false, 'evening': false, 'hifz': false};
            final isToday = _sameDate(date, DateTime.now());

            List<Widget> dots = [];
            if (entry['morning'] == true) {
              dots.add(_calendarDot(const Color(0xFFF59E0B)));
            }
            if (entry['evening'] == true) {
              dots.add(_calendarDot(const Color(0xFF8B5CF6)));
            }
            if (entry['hifz'] == true) {
              dots.add(_calendarDot(const Color(0xFF3B82F6)));
            }

            return Container(
              margin: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isToday ? colors.accent : Colors.transparent,
                  width: isToday ? 1.4 : 0,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('$day', style: TextStyle(color: colors.text)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 2,
                    runSpacing: 2,
                    alignment: WrapAlignment.center,
                    children: dots,
                  ),
                ],
              ),
            );
          },
          ),
        ),
      ],
    );
  }

  Widget _calendarDot(Color color) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  Widget _buildTasbihPage(_ModeColors colors, StateSetter setModal) {
    final tasbihCount = _activeTasbihCount;
    final cycleCount = _tasbihTarget <= 0
        ? 0
        : tasbihCount <= 0
            ? 0
            : ((tasbihCount - 1) % _tasbihTarget) + 1;
    final progress = _tasbihTarget == 0
        ? 1.0
        : (cycleCount / _tasbihTarget).clamp(0, 1).toDouble();

    return Column(
      children: [
        GestureDetector(
          onTap: () async {
            final reachedGoal =
                _tasbihTarget > 0 && (tasbihCount + 1) % _tasbihTarget == 0;
            setModal(() {
              _incrementTasbihCount();
            });
            if (reachedGoal) {
              await _vibrate([0, 40, 35, 70, 35, 120]);
            } else {
              await _vibrate();
            }
            await _saveState();
          },
          child: Container(
            width: 190,
            height: 190,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.card,
              border: Border.all(color: colors.border, width: 3),
              boxShadow: [
                BoxShadow(
                  color: colors.accent.withValues(alpha: 0.18),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('$tasbihCount',
                    style: TextStyle(
                        fontSize: 54,
                        fontWeight: FontWeight.bold,
                        color: colors.accentText)),
                const SizedBox(height: 6),
                Text('اضغط للتسبيح',
                    style: TextStyle(
                        color: colors.accentText.withValues(alpha: 0.7))),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _presetBtn('٣٣', 33, colors, setModal),
            const SizedBox(width: 8),
            _presetBtn('حر', 0, colors, setModal),
          ],
        ),
        const SizedBox(height: 18),
        Directionality(
          textDirection: TextDirection.rtl,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: colors.border.withValues(alpha: 0.5),
              valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _tasbihTarget == 0 ? 'وضع حر: $tasbihCount' : '$cycleCount / $_tasbihTarget',
          style: TextStyle(color: colors.accentText, fontSize: 18),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () async {
            setModal(_resetActiveTasbihCount);
            await _saveState();
          },
          icon: const Icon(Icons.restart_alt_rounded),
          label: const Text('إعادة البدء'),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.accentText,
            side: BorderSide(color: colors.border),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999)),
          ),
        ),
      ],
    );
  }

  Widget _presetBtn(
      String label, int target, _ModeColors colors, StateSetter setModal) {
    final active = _tasbihTarget == target;
    return ChoiceChip(
      label: Text(label),
      selected: active,
      onSelected: (_) async {
        setModal(() {
          _tasbihTarget = target;
        });
        await _saveState();
      },
      selectedColor: colors.chipSelected,
      side: BorderSide(color: colors.border),
      labelStyle: TextStyle(
        color: active ? colors.accentText : colors.accentText.withValues(alpha: 0.9),
      ),
      backgroundColor: colors.chipBg,
    );
  }

  Widget _buildSettingsPage(_ModeColors colors, StateSetter setModal) {
    // ── toggleRow يقرأ القيمة عبر getter لا snapshot ─────────────────────
    Widget toggleRow(
      String title,
      String subtitle,
      bool Function() getValue,
      Future<void> Function() onToggle,
      {IconData? titleIcon}
    ) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: SwitchListTile(
          value: getValue(),
          onChanged: (_) async {
            await onToggle();
            if (mounted) setModal(() {});
          },
          activeThumbColor: colors.accent,
          inactiveTrackColor: colors.chipSelected,
          inactiveThumbColor: colors.chipBg,
          title: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              textDirection: TextDirection.rtl,
              children: [
                Text(title,
                    textAlign: TextAlign.right,
                    style: GoogleFonts.scheherazadeNew(
                        fontSize: 22, color: colors.text)),
                if (titleIcon != null) ...[
                  const SizedBox(width: 3),
                  Icon(
                    titleIcon,
                    size: 22,
                    color: colors.accentText.withValues(alpha: 0.9),
                  ),
                ],
              ],
            ),
          ),
          subtitle: Text(subtitle,
              textAlign: TextAlign.right,
              style: GoogleFonts.amiri(
                  color: colors.accentText.withValues(alpha: 0.7))),
        ),
      );
    }

    Widget unavailableSettingRow(
      String title, {
      IconData? titleIcon,
    }) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              textDirection: TextDirection.rtl,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.right,
                  style: GoogleFonts.scheherazadeNew(
                    fontSize: 22,
                    color: colors.text,
                  ),
                ),
                if (titleIcon != null) ...[
                  const SizedBox(width: 3),
                  Icon(
                    titleIcon,
                    size: 22,
                    color: colors.accentText.withValues(alpha: 0.9),
                  ),
                ],
              ],
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                'لا تعمل على نسخة الويب',
                textAlign: TextAlign.right,
                textDirection: TextDirection.rtl,
                style: GoogleFonts.amiri(
                  fontSize: 15,
                  color: colors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        unavailableSettingRow(
          'تذكير بالأذكار',
          titleIcon: Icons.notifications_active_rounded,
        ),
        const Divider(height: 1),
        const SizedBox(height: 4),
        unavailableSettingRow(
          'الاهتزاز',
          titleIcon: Icons.vibration_rounded,
        ),
        toggleRow(
          'تمرير تلقائي',
          'الانتقال للذكر التالي بعد الإتمام',
          () => _autoScroll,
          () async {
            setState(() => _autoScroll = !_autoScroll);
            await _saveState();
          },
          titleIcon: Icons.vertical_align_bottom_rounded,
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          titleAlignment: ListTileTitleAlignment.center,
          leading: Directionality(
            textDirection: TextDirection.ltr,
            child: Wrap(
              spacing: 6,
              children: [
                _fontChip('ص', 0.95, colors, setModal),
                _fontChip('م', 1.35, colors, setModal),
                _fontChip('ك', 1.85, colors, setModal),
              ],
            ),
          ),
          title: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              textDirection: TextDirection.rtl,
              children: [
                Text('حجم الخط',
                    textAlign: TextAlign.right,
                    style: GoogleFonts.scheherazadeNew(
                        fontSize: 22, color: colors.text)),
                const SizedBox(width: 3),
                Icon(
                  Icons.text_fields_rounded,
                  size: 22,
                  color: colors.accentText.withValues(alpha: 0.9),
                ),
              ],
            ),
          ),
          subtitle: Text('كبير / متوسط / صغير',
              textAlign: TextAlign.right,
              style: GoogleFonts.amiri(
                  color: colors.accentText.withValues(alpha: 0.7))),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onTap: _showAboutAppPopup,
          leading: Icon(
            Icons.info_outline_rounded,
            color: colors.accentText.withValues(alpha: 0.85),
          ),
          title: Text('حول التطبيق',
              textAlign: TextAlign.right,
              style: GoogleFonts.scheherazadeNew(
                  fontSize: 22, color: colors.text)),
          subtitle: Text('نبذة مختصرة عن التطبيق ومصدر الأذكار',
              textAlign: TextAlign.right,
              style: GoogleFonts.amiri(
                  color: colors.accentText.withValues(alpha: 0.7))),
        ),
      ],
    );
  }

  Widget _fontChip(
      String label, double size, _ModeColors colors, StateSetter setModal) {
    final active = (_fontSize - size).abs() < 0.01;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(fontSize: label == 'م' ? 22 : 20),
      ),
      selected: active,
      onSelected: (_) async {
        setState(() => _fontSize = size);
        setModal(() {});
        await _saveState();
      },
      selectedColor: colors.chipSelected,
      side: BorderSide(color: colors.border),
      labelStyle: TextStyle(
        color: active ? colors.accentText : colors.accentText.withValues(alpha: 0.9),
      ),
      backgroundColor: colors.chipBg,
    );
  }

  Future<void> _showFadlPopup(String text) async {
    final normalizedText = text.trim();
    final fadlText = normalizedText.isEmpty
        ? normalizedText
        : RegExp(r'[\.!\?؟۔]$').hasMatch(normalizedText)
            ? normalizedText
            : '$normalizedText.';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _modeColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 42,
                height: 5,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: _modeColors.border,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Text(
                'فضل الذكر',
                textAlign: TextAlign.center,
                style: GoogleFonts.scheherazadeNew(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: _modeColors.title,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                fadlText,
                textAlign: TextAlign.right,
                style: GoogleFonts.amiri(
                  fontSize: 24,
                  height: 1.9,
                  color: _modeColors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAboutAppPopup() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _modeColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 42,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: _modeColors.border,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                Text(
                  'حول التطبيق',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.scheherazadeNew(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: _modeColors.title,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'تطبيق أذكار يساعدك على المحافظة على أذكار الصباح والمساء وآيات الحفظ.\n\n'
                  'جُمعت هذه الأذكار من كتاب الإمام المفسّر المحدّث الشيخ عبد الله سراج الدين الحسيني رضي الله عنه.\n\n'
                  'نسأل الله أن ينفعنا به، ويجعله خالصًا لوجهه الكريم، وفي ميزان حسناتنا.',
                  textAlign: TextAlign.right,
                  textDirection: TextDirection.rtl,
                  style: GoogleFonts.amiri(
                    fontSize: 22,
                    height: 1.9,
                    color: _modeColors.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ─── Theme ────────────────────────────────────────────────────────────────────
class _ModeColors {
  final Color background;
  final Color card;
  final Color text;
  final Color border;
  final Color accent;
  final Color accentText;
  final Color title;
  final Color chipBg;
  final Color chipSelected;
  final Color buttonFg;

  const _ModeColors({
    required this.background,
    required this.card,
    required this.text,
    required this.border,
    required this.accent,
    required this.accentText,
    required this.title,
    required this.chipBg,
    required this.chipSelected,
    required this.buttonFg,
  });
}

// ─── Stars ────────────────────────────────────────────────────────────────────
class _EveningStarsBackground extends StatelessWidget {
  const _EveningStarsBackground();

  @override
  Widget build(BuildContext context) {
    const positions = <Offset>[
      Offset(30, 90),   Offset(120, 40),  Offset(220, 120),
      Offset(310, 60),  Offset(60, 220),  Offset(180, 260),
      Offset(330, 310), Offset(80, 430),  Offset(260, 520),
      Offset(40, 630),  Offset(320, 720),
    ];

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, _) => Stack(
          children: positions
              .map((offset) => Positioned(
                    left: offset.dx,
                    top: offset.dy,
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: const BoxDecoration(
                        color: Colors.white70,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

