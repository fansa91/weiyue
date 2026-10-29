import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/screens/me_screen.dart';
import 'package:weiyue/screens/message_center_screen.dart';

import '../helpers/fakes.dart';

/// 消息中心界面测试。数据来自 FakeWeiyueService 的构造假数据，
/// 登录态真实行为待用户真机验证。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

void main() {
  group('MeScreen 消息中心入口', () {
    testWidgets('已登录：入口可见且带总未读徽标（2+1+3+4=10）', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            const MeScreen(),
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        expect(find.text('消息中心'), findsOneWidget);
        expect(find.text('10'), findsOneWidget);
      });
    });

    testWidgets('未登录：无消息中心入口', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(wrapWithProviders(const MeScreen()));
        await _settle(tester);
        expect(find.text('消息中心'), findsNothing);
      });
    });

    testWidgets('点入口进消息中心页', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            const MeScreen(),
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        await tester.tap(find.text('消息中心'));
        await _settle(tester);
        expect(find.byType(MessageCenterScreen), findsOneWidget);
      });
    });
  });

  group('MessageCenterScreen', () {
    Future<void> pumpCenter(WidgetTester tester) async {
      await tester.pumpWidget(
        wrapWithProviders(
          const MessageCenterScreen(),
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
    }

    testWidgets('四页签 + 未读徽标渲染，全部页签显示混合流条目', (tester) async {
      await mockNetworkImagesFor(() async {
        await pumpCenter(tester);
        expect(find.text('全部'), findsOneWidget);
        expect(find.text('@我的'), findsOneWidget);
        expect(find.text('评论'), findsWidgets);
        expect(find.text('赞'), findsOneWidget);
        // 徽标：@我的 3、评论 3、赞 4，共 3 个
        expect(find.byType(Badge), findsNWidgets(3));
        expect(find.text('4'), findsOneWidget);
        // 全部页签条目：动作行 + 正文 + 关联微博引用块
        expect(find.text('评论了你的微博'), findsWidgets);
        expect(
          find.textContaining('混合流里的评论一', findRichText: true),
          findsOneWidget,
        );
        expect(find.textContaining('被评论的微博一'), findsOneWidget);
      });
    });

    testWidgets('点混合流条目进帖子详情', (tester) async {
      await mockNetworkImagesFor(() async {
        await pumpCenter(tester);
        await tester.tap(find.textContaining('被评论的微博一'));
        await _settle(tester);
        expect(find.byType(DetailScreen), findsOneWidget);
      });
    });

    testWidgets('@我的页签：微博列表渲染 + 切到评论子页签', (tester) async {
      await mockNetworkImagesFor(() async {
        await pumpCenter(tester);
        await tester.tap(find.text('@我的'));
        await _settle(tester);
        expect(
          find.textContaining('@我的微博一', findRichText: true),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(SegmentedButton<bool>, '评论'));
        await _settle(tester);
        expect(
          find.textContaining('@你的评论一', findRichText: true),
          findsOneWidget,
        );
      });
    });

    testWidgets('评论页签：收到的渲染 + 子切换到发出的', (tester) async {
      await mockNetworkImagesFor(() async {
        await pumpCenter(tester);
        await tester.tap(find.text('评论').first);
        await _settle(tester);
        expect(
          find.textContaining('评论你的微博一', findRichText: true),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(SegmentedButton<bool>, '发出的'));
        await _settle(tester);
        expect(
          find.textContaining('我发出的评论一', findRichText: true),
          findsOneWidget,
        );
      });
    });

    testWidgets('赞页签：赞微博/赞评论两类条目渲染', (tester) async {
      await mockNetworkImagesFor(() async {
        await pumpCenter(tester);
        await tester.tap(find.text('赞'));
        await _settle(tester);
        expect(find.text('赞了你的微博'), findsOneWidget);
        expect(find.text('赞了你的评论'), findsOneWidget);
        expect(find.text('评论：被赞的评论一'), findsOneWidget);
        expect(find.textContaining('被赞的微博一'), findsOneWidget);
      });
    });
  });
}
