import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/screens/home_screen.dart';
import 'package:weiyue/widgets/detail_scaffold.dart';
import 'package:weiyue/widgets/hot_feed_view.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void _useWideView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  // 回归锁（v0.1.3 真机反馈）：首页曾被 Center+ConstrainedBox(680)
  // 压成居中窄条，HotFeedView 的瀑布流分支在真机上从未触发；
  // 旧宽屏测试直接 pump HotFeedView 绕过了封顶层，所以全绿也没发现。
  // 本测试必须经 HomeScreen 整页进入并断言实际宽度。
  testWidgets('HomeScreen 1500px 宽：feed 铺满且瀑布流生效', (tester) async {
    await mockNetworkImagesFor(() async {
      _useWideView(tester, const Size(1500, 900));
      await tester.pumpWidget(wrapWithProviders(const HomeScreen()));
      await _settle(tester);
      final feedWidth = tester.getSize(find.byType(HotFeedView)).width;
      expect(feedWidth, greaterThan(1400),
          reason: 'feed 区域应接近整页宽 1500，而不是被压回 680');
      expect(find.byType(SliverMasonryGrid), findsOneWidget);
    });
  });

  testWidgets('HomeScreen 窄屏：feed 仍为单列（无瀑布流）', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(wrapWithProviders(const HomeScreen()));
      await _settle(tester);
      expect(find.byType(SliverMasonryGrid), findsNothing);
    });
  });

  // 追加需求回归锁：详情页经 DetailScaffold 进入（真实导航路径）时，
  // 宽屏双栏必须真的触发——左栏只有正文，页签组只在右栏出现一次，
  // 且右栏从 x=整页宽-420 起（不受任何 680 封顶影响）。
  testWidgets('DetailScreen 经 DetailScaffold 宽屏：页签只在右栏、左栏只有正文',
      (tester) async {
    await mockNetworkImagesFor(() async {
      _useWideView(tester, const Size(1500, 900));
      final status = makeStatus(id: '9', text: '详情页原文', comments: 122);
      await tester.pumpWidget(wrapWithProviders(
        DetailScaffold(child: DetailScreen(status: status)),
      ));
      await _settle(tester);
      // 详情页整体拿到整页宽（DetailScaffold 不再封顶 680）
      expect(tester.getSize(find.byType(DetailScreen)).width, 1500);
      // 页签组全局只出现一份（左栏下方没有重复）
      expect(find.byType(TabBar), findsOneWidget);
      // 页签在右栏内：左边缘 >= 1500-420
      final tabBarRect = tester.getRect(find.byType(TabBar));
      expect(tabBarRect.left, greaterThanOrEqualTo(1500 - 420 - 1));
      // 正文卡在左栏内：右边缘 <= 右栏左界
      final cardRect = tester.getRect(find.byType(Card).first);
      expect(cardRect.right, lessThanOrEqualTo(1500 - 420 + 1));
      // 右栏页签高度铺满：TabBarView 底部贴近视口底（900 高 - AppBar 56）
      final tabViewRect = tester.getRect(find.byType(TabBarView));
      expect(tabViewRect.bottom, greaterThan(900 - 56 - 2));
      expect(tabViewRect.width, lessThanOrEqualTo(420));
    });
  });

  testWidgets('DetailScreen 窄屏：页签在正文下方（保持现状）', (tester) async {
    await mockNetworkImagesFor(() async {
      final status = makeStatus(id: '9', text: '详情页原文', comments: 122);
      await tester.pumpWidget(wrapWithProviders(
        DetailScaffold(child: DetailScreen(status: status)),
      ));
      await _settle(tester);
      expect(find.byType(TabBar), findsOneWidget);
      final cardRect = tester.getRect(find.byType(Card).first);
      final tabBarRect = tester.getRect(find.byType(TabBar));
      expect(tabBarRect.top, greaterThanOrEqualTo(cardRect.bottom - 1));
      expect(tabBarRect.left, lessThan(100));
    });
  });
}
