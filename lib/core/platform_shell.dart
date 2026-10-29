import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Brightness, ThemeMode;
import 'package:fluent_ui/fluent_ui.dart' as fluent;

/// 应用外壳种类（换壳第一阶段）：按运行平台分流——
/// Windows 用 Fluent、iOS/macOS 用 Cupertino、其余（Android/Linux）用 Material。
///
/// 分流只换「导航壳 + 主题 + 转场」，各屏内部仍是现有 Material 控件，
/// 在非 Material 壳内由应用根的桥接层（Theme + Material 祖先）承载。
enum AppShellKind { material, cupertino, fluent }

/// 平台 → 壳种类的集中判定（纯函数，可单测）。
/// 未列出的平台（fuchsia 等）一律回落 Material 壳，保证不崩。
AppShellKind shellKindForPlatform(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.windows => AppShellKind.fluent,
    TargetPlatform.iOS || TargetPlatform.macOS => AppShellKind.cupertino,
    _ => AppShellKind.material,
  };
}

/// 把用户主题模式（浅/深/跟随系统）解析成确定的亮度。
/// MaterialApp/FluentApp 自带 themeMode 不需要它；CupertinoApp 没有
/// themeMode 概念、桥接主题也要确定亮度，共用此解析。
Brightness brightnessForThemeMode(
  ThemeMode mode,
  Brightness platformBrightness,
) {
  return switch (mode) {
    ThemeMode.system => platformBrightness,
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
  };
}

/// 设置里的主题模式（Flutter material 的 ThemeMode）→ FluentApp 的
/// themeMode。注意 fluent_ui 4.17 的 ThemeMode 来自其 material_ui 包，
/// 与 material 的 ThemeMode 是两个同名不同源的类型，必须显式映射。
fluent.ThemeMode fluentThemeModeFor(ThemeMode mode) {
  return switch (mode) {
    ThemeMode.system => fluent.ThemeMode.system,
    ThemeMode.light => fluent.ThemeMode.light,
    ThemeMode.dark => fluent.ThemeMode.dark,
  };
}
