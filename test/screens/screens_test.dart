import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/main.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/screens/discover_screen.dart';
import 'package:weiyue/screens/home_screen.dart';
import 'package:weiyue/screens/me_screen.dart';
import 'package:weiyue/screens/profile_screen.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void main() {
  testWidgets('HomeScreen：分类 chips 与 feed 列表渲染', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(wrapWithProviders(const HomeScreen()));
      await _settle(tester);
      // 分类 chips（HotFeedView 频道条之外的 Home 分类 chips）
      expect(find.text('热门'), findsWidgets);
      expect(find.text('社会'), findsWidgets);
      expect(find.text('科技'), findsWidgets);
      // feed 条目
      expect(find.textContaining('热门第一条', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('热门第二条带图', findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('HomeScreen：feed 失败显示错误与重试', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakeWeiyueService()..failFeed = true;
      await tester.pumpWidget(
          wrapWithProviders(const HomeScreen(), weibo: fake));
      await _settle(tester);
      expect(find.textContaining('网络错误'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  testWidgets('HomeScreen：feed 为空显示空态', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakeWeiyueService()..feedItems = [];
      await tester.pumpWidget(
          wrapWithProviders(const HomeScreen(), weibo: fake));
      await _settle(tester);
      expect(find.text('暂无内容'), findsOneWidget);
    });
  });

  testWidgets('DetailScreen：评论 1/122 时出现访客热评横幅', (tester) async {
    await mockNetworkImagesFor(() async {
      final status = makeStatus(id: '9', text: '详情页原文', comments: 122);
      await tester.pumpWidget(wrapWithProviders(DetailScreen(status: status)));
      await _settle(tester);
      expect(find.textContaining('访客仅显示热评'), findsOneWidget);
      expect(find.textContaining('122'), findsWidgets);
      expect(find.textContaining('这是一条热评', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('转发列表访客不可见'), findsNothing);
    });
  });

  testWidgets('DiscoverScreen：热搜榜名次与热度渲染', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(wrapWithProviders(const DiscoverScreen()));
      await _settle(tester);
      expect(find.text('热搜第一条'), findsOneWidget);
      expect(find.text('1146.0万'), findsOneWidget); // 11459803/1e4 四舍五入
      expect(find.text('爆'), findsWidgets);
      expect(find.text('#置顶话题#'), findsOneWidget);
      // band 六分类入口
      for (final label in ['娱乐', '生活', '社会', '科技', '体育', '动漫']) {
        expect(find.text(label), findsWidgets, reason: '分类 $label');
      }
    });
  });

  testWidgets('ProfileScreen：头部昵称/三计数与三页签', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester
          .pumpWidget(wrapWithProviders(const ProfileScreen(uid: '42')));
      await _settle(tester);
      expect(find.text('测试博主'), findsWidgets);
      expect(find.text('1.2万'), findsOneWidget); // 粉丝 12345
      expect(find.text('100'), findsOneWidget); // 关注
      expect(find.text('999'), findsOneWidget); // 动态数
      expect(find.text('动态'), findsWidgets);
      expect(find.text('视频'), findsWidgets);
      expect(find.text('相册'), findsWidgets);
      expect(find.textContaining('主页微博一', findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('MeScreen：有 SUB 显示已就绪', (tester) async {
    await tester.pumpWidget(wrapWithProviders(const MeScreen(),
        visitor: FakeVisitorService(has: true)));
    await _settle(tester);
    expect(find.textContaining('已就绪'), findsNWidgets(2));
    expect(find.text('刷新访客身份'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('主题与外观'), findsOneWidget);
  });

  testWidgets('MeScreen：无 SUB 显示未获取', (tester) async {
    await tester.pumpWidget(wrapWithProviders(const MeScreen(),
        visitor: FakeVisitorService(has: false)));
    await _settle(tester);
    expect(find.text('未获取'), findsNWidgets(2));
    expect(find.textContaining('已就绪'), findsNothing);
  });

  testWidgets('AppShell：底部四栏切换', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(wrapWithProviders(const AppShell()));
      await _settle(tester);
      final navBar = find.byType(NavigationBar);
      expect(navBar, findsOneWidget);
      for (final label in ['首页', '视频', '发现', '我的']) {
        expect(
            find.descendant(of: navBar, matching: find.text(label)),
            findsOneWidget,
            reason: '导航 $label');
      }
      // 切到发现
      await tester.tap(
          find.descendant(of: navBar, matching: find.text('发现')));
      await _settle(tester);
      expect(find.text('热搜第一条'), findsOneWidget);
      // 切到我的
      await tester.tap(
          find.descendant(of: navBar, matching: find.text('我的')));
      await _settle(tester);
      expect(find.text('刷新访客身份'), findsOneWidget);
    });
  });
}
