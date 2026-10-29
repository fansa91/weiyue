import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/screens/login_screen.dart';
import 'package:weiyue/screens/me_screen.dart';
import 'package:weiyue/services/session_service.dart';

import '../helpers/fakes.dart';

/// 登录修复入口 + 诊断面板的组件测试（假会话数据，无真实 Cookie）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

FakeSessionService _diagSession() {
  final s = FakeSessionService(loggedIn: true);
  s.fakeHasXsrf = true;
  s.fakeProbeDiag = ProbeDiagnostic(
    timeMs: DateTime(2026, 10, 29, 20, 55).millisecondsSinceEpoch,
    pcUnlocked: false,
    mUnlocked: true,
    hasUid: false,
    hasXsrf: false,
  );
  s.fakeFailures = [
    LoginApiFailure(
      timeMs: DateTime(2026, 10, 29, 20, 55).millisecondsSinceEpoch,
      endpoint: '/ajax/friendships/friends',
      message: '接口返回非 JSON（HTTP 400）',
    ),
  ];
  return s;
}

void main() {
  testWidgets('未登录：无修复登录态、无登录诊断', (tester) async {
    await mockNetworkImagesFor(() async {
      _tallViewport(tester);
      await tester.pumpWidget(wrapWithProviders(const MeScreen()));
      await _settle(tester);
      expect(find.text('修复登录态'), findsNothing);
      expect(find.text('登录诊断'), findsNothing);
    });
  });

  testWidgets('已登录：修复入口存在，诊断面板展开显示快照与失败记录', (tester) async {
    await mockNetworkImagesFor(() async {
      _tallViewport(tester);
      await tester.pumpWidget(
        wrapWithProviders(const MeScreen(), session: _diagSession()),
      );
      await _settle(tester);
      expect(find.text('修复登录态'), findsOneWidget);
      expect(find.text('登录诊断'), findsOneWidget);

      await tester.tap(find.text('登录诊断'));
      await _settle(tester);

      // 探活快照行：标签齐全，uid 未获取、失败记录带路径与消息
      expect(find.text('最近检测'), findsOneWidget);
      expect(find.text('用户 ID'), findsOneWidget);
      expect(find.text('未获取'), findsOneWidget);
      expect(find.text('XSRF 令牌'), findsOneWidget);
      expect(find.text('当前令牌'), findsOneWidget);
      expect(find.text('最近失败记录'), findsOneWidget);
      expect(find.textContaining('/ajax/friendships/friends'), findsOneWidget);
      expect(find.textContaining('接口返回非 JSON（HTTP 400）'), findsOneWidget);
      expect(find.text('暂无失败记录'), findsNothing);
      expect(find.text('重新检测'), findsOneWidget);
    });
  });

  testWidgets('已登录无诊断数据：面板显示尚未检测与暂无失败记录', (tester) async {
    await mockNetworkImagesFor(() async {
      _tallViewport(tester);
      await tester.pumpWidget(
        wrapWithProviders(
          const MeScreen(),
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text('登录诊断'));
      await _settle(tester);
      expect(find.text('尚未检测'), findsOneWidget);
      expect(find.text('暂无失败记录'), findsOneWidget);
    });
  });

  testWidgets('LoginScreen 修复模式标题为「修复登录态」，普通模式为「账号登录」', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapWithProviders(const LoginScreen(startOnPcSite: true)),
    );
    await _settle(tester);
    expect(find.text('修复登录态'), findsOneWidget);

    await tester.pumpWidget(wrapWithProviders(const LoginScreen()));
    await _settle(tester);
    expect(find.text('账号登录'), findsOneWidget);
  });
}
