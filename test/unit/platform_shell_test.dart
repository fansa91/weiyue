import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:weiyue/core/platform_shell.dart';

void main() {
  group('shellKindForPlatform', () {
    test('Windows → Fluent 壳', () {
      expect(
        shellKindForPlatform(TargetPlatform.windows),
        AppShellKind.fluent,
      );
    });

    test('iOS/macOS → Cupertino 壳', () {
      expect(shellKindForPlatform(TargetPlatform.iOS), AppShellKind.cupertino);
      expect(
        shellKindForPlatform(TargetPlatform.macOS),
        AppShellKind.cupertino,
      );
    });

    test('Android/Linux/其他 → Material 壳（回落不崩）', () {
      expect(
        shellKindForPlatform(TargetPlatform.android),
        AppShellKind.material,
      );
      expect(shellKindForPlatform(TargetPlatform.linux), AppShellKind.material);
      expect(
        shellKindForPlatform(TargetPlatform.fuchsia),
        AppShellKind.material,
      );
    });
  });

  group('brightnessForThemeMode', () {
    test('跟随系统取平台亮度', () {
      expect(
        brightnessForThemeMode(ThemeMode.system, Brightness.dark),
        Brightness.dark,
      );
      expect(
        brightnessForThemeMode(ThemeMode.system, Brightness.light),
        Brightness.light,
      );
    });

    test('强制浅/深忽略平台亮度', () {
      expect(
        brightnessForThemeMode(ThemeMode.light, Brightness.dark),
        Brightness.light,
      );
      expect(
        brightnessForThemeMode(ThemeMode.dark, Brightness.light),
        Brightness.dark,
      );
    });
  });

  group('fluentThemeModeFor', () {
    test('material ThemeMode → fluent_ui 的 ThemeMode 一一映射', () {
      expect(fluentThemeModeFor(ThemeMode.system), fluent.ThemeMode.system);
      expect(fluentThemeModeFor(ThemeMode.light), fluent.ThemeMode.light);
      expect(fluentThemeModeFor(ThemeMode.dark), fluent.ThemeMode.dark);
    });
  });
}
