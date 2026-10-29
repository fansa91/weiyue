import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:network_image_mock/network_image_mock.dart';
import 'package:provider/provider.dart';
import 'package:weiyue/main.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/settings_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void _useView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 不带 MaterialApp 的应用根脚手架：WeiyueApp 自带三套根，
/// 用 platformOverride 注入目标平台，providers 用假服务。
Widget _app(TargetPlatform platform) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<VisitorService>.value(value: FakeVisitorService()),
      ChangeNotifierProvider<SessionService>.value(
        value: FakeSessionService(),
      ),
      Provider<WeiyueService>.value(value: FakeWeiyueService()),
      ChangeNotifierProvider<SettingsService>(
        create: (_) => SettingsService(),
      ),
    ],
    child: WeiyueApp(platformOverride: platform),
  );
}

void main() {
  // 换壳第一阶段 smoke：三套壳各渲染出四 tab、首页内容出现、能切 tab。
  // 内容断言沿用既有假服务口径（首页 feed「热门第一条」、
  // 发现页热搜「热搜第一条」），IndexedStack 非当前页对 finder 不可见，
  // 所以切前断言不存在、切后断言出现，能证明切换真实发生。

  testWidgets('Material 壳（Android）：底部四栏 + 切发现', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_app(TargetPlatform.android));
      await _settle(tester);
      final navBar = find.byType(NavigationBar);
      expect(navBar, findsOneWidget);
      for (final label in ['首页', '视频', '发现', '我的']) {
        expect(
          find.descendant(of: navBar, matching: find.text(label)),
          findsOneWidget,
          reason: '导航 $label',
        );
      }
      expect(find.text('热门第一条'), findsOneWidget);
      expect(find.text('热搜第一条'), findsNothing);
      await tester.tap(
        find.descendant(of: navBar, matching: find.text('发现')),
      );
      await _settle(tester);
      expect(find.text('热搜第一条'), findsOneWidget);
    });
  });

  testWidgets('Cupertino 壳（iOS 窄屏）：底部 tab 栏 + 切发现', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_app(TargetPlatform.iOS));
      await _settle(tester);
      final tabBar = find.byType(CupertinoTabBar);
      expect(tabBar, findsOneWidget);
      for (final label in ['首页', '视频', '发现', '我的']) {
        expect(
          find.descendant(of: tabBar, matching: find.text(label)),
          findsOneWidget,
          reason: '导航 $label',
        );
      }
      expect(find.text('热门第一条'), findsOneWidget);
      expect(find.text('热搜第一条'), findsNothing);
      await tester.tap(
        find.descendant(of: tabBar, matching: find.text('发现')),
      );
      await _settle(tester);
      expect(find.text('热搜第一条'), findsOneWidget);
    });
  });

  testWidgets('Cupertino 壳（macOS 宽屏）：侧栏形态 + 切发现', (tester) async {
    await mockNetworkImagesFor(() async {
      _useView(tester, const Size(1600, 900));
      await tester.pumpWidget(_app(TargetPlatform.macOS));
      await _settle(tester);
      // 宽屏走侧栏，没有底部 tab 栏
      expect(find.byType(CupertinoTabBar), findsNothing);
      for (final label in ['首页', '视频', '发现', '我的']) {
        expect(find.text(label), findsOneWidget, reason: '侧栏 $label');
      }
      expect(find.text('热门第一条'), findsOneWidget);
      expect(find.text('热搜第一条'), findsNothing);
      await tester.tap(find.text('发现'));
      await _settle(tester);
      expect(find.text('热搜第一条'), findsOneWidget);
    });
  });

  testWidgets('Fluent 壳（Windows 宽屏）：NavigationView + 切发现', (tester) async {
    await mockNetworkImagesFor(() async {
      _useView(tester, const Size(1600, 900));
      await tester.pumpWidget(_app(TargetPlatform.windows));
      await _settle(tester);
      final navView = find.byType(fluent.NavigationView);
      expect(navView, findsOneWidget);
      for (final label in ['首页', '视频', '发现', '我的']) {
        expect(
          find.descendant(of: navView, matching: find.text(label)),
          findsWidgets,
          reason: '导航 $label',
        );
      }
      expect(find.text('热门第一条'), findsOneWidget);
      expect(find.text('热搜第一条'), findsNothing);
      await tester.tap(
        find.descendant(of: navView, matching: find.text('发现')).first,
      );
      await _settle(tester);
      expect(find.text('热搜第一条'), findsOneWidget);
    });
  });
}
