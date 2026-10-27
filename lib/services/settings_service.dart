import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用设置：主题模式 / 主题色等，持久化到 SharedPreferences。
/// 直连小宇宙官方 API，不再需要配置自部署后端地址。
class SettingsService extends ChangeNotifier {
  static const _keyDynamicColor = 'dynamic_color';
  static const _keyThemeSeed = 'theme_seed';
  static const _keyThemeMode = 'theme_mode';
  static const _keyPureBlack = 'pure_black';
  static const _keyCustomColors = 'custom_colors';
  static const _keyWaveformProgress = 'waveform_progress';

  /// 预设主题色
  static const List<ThemePreset> themePresets = [
    ThemePreset('网易云红', 0xFFD33A31),
    ThemePreset('活力橙', 0xFFF57C00),
    ThemePreset('琥珀黄', 0xFFFFB300),
    ThemePreset('草原绿', 0xFF4CAF50),
    ThemePreset('湖水青', 0xFF00BCD4),
    ThemePreset('天空蓝', 0xFF2196F3),
    ThemePreset('靛蓝', 0xFF3F51B5),
    ThemePreset('葡萄紫', 0xFF9C27B0),
    ThemePreset('樱花粉', 0xFFE91E63),
  ];
  static const int defaultThemeSeed = 0xFFD33A31;

  late SharedPreferences _prefs;

  /// 主题模式：跟随系统 / 浅色 / 深色（参考 Bettbox）
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  /// 纯黑模式（深色下背景全黑，AMOLED 省电）
  bool _pureBlack = false;
  bool get pureBlack => _pureBlack;

  /// 用户自定义主题色（ARGB int 列表）
  List<int> _customColors = [];
  List<int> get customColors => List.unmodifiable(_customColors);

  /// 波浪形进度条（播放器进度条显示为波形样式）
  bool _waveformProgress = false;
  bool get waveformProgress => _waveformProgress;

  /// M3 动态取色（跟随系统壁纸，Android 12+ 有效），默认开启
  bool _dynamicColor = true;
  bool get dynamicColor => _dynamicColor;

  /// 从系统取到的动态种子色；不支持或未取到时为 null
  Color? _systemSeedColor;
  Color? get systemSeedColor => _systemSeedColor;

  /// 当前生效的种子色：动态取色开且系统支持时用系统色，否则用用户选的主题色
  Color get effectiveSeedColor {
    if (_dynamicColor && _systemSeedColor != null) return _systemSeedColor!;
    return Color(_themeSeed);
  }

  /// 主题色（ARGB int），默认网易云红
  int _themeSeed = defaultThemeSeed;
  int get themeSeed => _themeSeed;
  String get themeName {
    for (final p in themePresets) {
      if (p.value == _themeSeed) return p.name;
    }
    if (_customColors.contains(_themeSeed)) return '自定义';
    return '网易云红';
  }

  SettingsService();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _themeSeed = _prefs.getInt(_keyThemeSeed) ?? defaultThemeSeed;
    _dynamicColor = _prefs.getBool(_keyDynamicColor) ?? true;
    if (_dynamicColor) await _loadSystemScheme();
    final modeIndex = _prefs.getInt(_keyThemeMode) ?? ThemeMode.system.index;
    _themeMode = ThemeMode.values[modeIndex.clamp(0, 2)];
    _pureBlack = _prefs.getBool(_keyPureBlack) ?? false;
    _customColors =
        _prefs.getStringList(_keyCustomColors)?.map(int.parse).toList() ?? [];
    _waveformProgress = _prefs.getBool(_keyWaveformProgress) ?? false;
  }

  /// 通过系统 CorePalette 取种子色，M3 明暗主题分别用 fromSeed 生成
  Future<void> _loadSystemScheme() async {
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette != null) {
        _systemSeedColor = Color(palette.primary.get(40));
      }
    } catch (_) {
      _systemSeedColor = null;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    await _prefs.setInt(_keyThemeMode, mode.index);
    notifyListeners();
  }

  Future<void> setPureBlack(bool value) async {
    if (value == _pureBlack) return;
    _pureBlack = value;
    await _prefs.setBool(_keyPureBlack, value);
    notifyListeners();
  }

  Future<void> addCustomColor(int value) async {
    if (_customColors.contains(value)) return;
    _customColors = [..._customColors, value];
    await _prefs.setStringList(
        _keyCustomColors, _customColors.map((e) => e.toString()).toList());
    notifyListeners();
  }

  Future<void> removeCustomColor(int value) async {
    if (!_customColors.contains(value)) return;
    _customColors = _customColors.where((e) => e != value).toList();
    await _prefs.setStringList(
        _keyCustomColors, _customColors.map((e) => e.toString()).toList());
    // 如果删的是当前选中的颜色，回退到默认
    if (_themeSeed == value) {
      await setThemeSeed(defaultThemeSeed);
      return;
    }
    notifyListeners();
  }

  Future<void> setWaveformProgress(bool value) async {
    if (value == _waveformProgress) return;
    _waveformProgress = value;
    await _prefs.setBool(_keyWaveformProgress, value);
    notifyListeners();
  }

  Future<void> resetTheme() async {
    _themeSeed = defaultThemeSeed;
    _dynamicColor = true;
    _themeMode = ThemeMode.system;
    _pureBlack = false;
    _customColors = [];
    await _prefs.setInt(_keyThemeSeed, _themeSeed);
    await _prefs.setBool(_keyDynamicColor, true);
    await _prefs.setInt(_keyThemeMode, _themeMode.index);
    await _prefs.setBool(_keyPureBlack, false);
    await _prefs.setStringList(_keyCustomColors, []);
    await _loadSystemScheme();
    notifyListeners();
  }

  Future<void> setDynamicColor(bool value) async {
    if (value == _dynamicColor) return;
    _dynamicColor = value;
    await _prefs.setBool(_keyDynamicColor, value);
    if (value && _systemSeedColor == null) await _loadSystemScheme();
    notifyListeners();
  }

  /// 选择预设主题色：同时关闭动态取色（手动选色优先）
  Future<void> setThemeSeed(int value) async {
    if (value == _themeSeed) return;
    _themeSeed = value;
    await _prefs.setInt(_keyThemeSeed, value);
    if (_dynamicColor) {
      _dynamicColor = false;
      await _prefs.setBool(_keyDynamicColor, false);
    }
    notifyListeners();
  }
}

/// 主题预设
class ThemePreset {
  final String name;
  final int value;
  const ThemePreset(this.name, this.value);
}
