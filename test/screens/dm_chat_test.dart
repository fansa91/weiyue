import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/dm_chat_screen.dart';
import 'package:weiyue/screens/message_center_screen.dart';

import '../helpers/fakes.dart';

/// 私信界面测试：页签会话列表（主列表 + 未关注人一节）、聊天页
/// 气泡/发送/失败重发/加载更早。数据来自 FakeWeiyueService 的
/// WebIM 罐头（结构依据见 dm_service_test 文件头注），登录态
/// 真实行为待用户真机验证。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

void main() {
  group('私信页签', () {
    testWidgets('会话列表：主列表 + 未关注人一节 + 未读徽标', (tester) async {
      await mockNetworkImagesFor(() async {
        final fake = FakeWeiyueService();
        await tester.pumpWidget(
          wrapWithProviders(
            const MessageCenterScreen(),
            weibo: fake,
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        await tester.tap(find.text('私信'));
        await _settle(tester);
        expect(find.text('私信测试博主'), findsOneWidget);
        expect(find.text('最近一条消息摘要'), findsOneWidget);
        expect(find.text('2'), findsOneWidget); // 会话未读徽标
        expect(find.text('未关注人消息'), findsOneWidget);
        expect(find.text('未关注的陌生人'), findsOneWidget);
        expect(find.text('陌生人发来的消息'), findsOneWidget);
      });
    });

    testWidgets('点会话进聊天页：气泡渲染 + 打开即标记已读', (tester) async {
      await mockNetworkImagesFor(() async {
        final fake = FakeWeiyueService();
        await tester.pumpWidget(
          wrapWithProviders(
            const MessageCenterScreen(),
            weibo: fake,
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        await tester.tap(find.text('私信'));
        await _settle(tester);
        await tester.tap(find.text('私信测试博主'));
        await _settle(tester);
        expect(find.byType(DmChatScreen), findsOneWidget);
        expect(find.text('最早的一条'), findsOneWidget);
        expect(find.text('我回复的一条'), findsOneWidget);
        expect(find.text('最新的一条'), findsOneWidget);
        expect(fake.dmReadCalls, contains('1641537791:false'));
        expect(fake.dmHistoryCalls.first, '1641537791:0:false');
      });
    });

    testWidgets('点未关注人会话：历史与已读都走 public 族', (tester) async {
      await mockNetworkImagesFor(() async {
        final fake = FakeWeiyueService();
        await tester.pumpWidget(
          wrapWithProviders(
            const MessageCenterScreen(),
            weibo: fake,
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        await tester.tap(find.text('私信'));
        await _settle(tester);
        await tester.tap(find.text('未关注的陌生人'));
        await _settle(tester);
        expect(find.byType(DmChatScreen), findsOneWidget);
        expect(find.text('暂无消息'), findsOneWidget);
        expect(fake.dmHistoryCalls, contains('2000000001:0:true'));
        expect(fake.dmReadCalls, contains('2000000001:true'));
      });
    });
  });

  group('DmChatScreen', () {
    DmConversation convOf(FakeWeiyueService fake) => fake.dmChats.single;

    Future<void> pumpChat(WidgetTester tester, FakeWeiyueService fake) async {
      await tester.pumpWidget(
        wrapWithProviders(
          DmChatScreen(conversation: convOf(fake)),
          weibo: fake,
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
    }

    testWidgets('发送成功：乐观上屏后被服务端回执替换', (tester) async {
      await mockNetworkImagesFor(() async {
        final fake = FakeWeiyueService();
        await pumpChat(tester, fake);
        await tester.enterText(find.byType(TextField), '你好，这是一条私信');
        await tester.tap(find.byIcon(Icons.send));
        await _settle(tester);
        expect(find.text('你好，这是一条私信'), findsOneWidget);
        expect(find.text('发送中…'), findsNothing);
        expect(find.text('发送失败，点击重发'), findsNothing);
        expect(fake.dmSendCalls.length, 1);
        expect(fake.dmSendCalls.single.uid, '1641537791');
        expect(fake.dmSendCalls.single.text, '你好，这是一条私信');
        // 输入框已清空
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
      });
    });

    testWidgets('发送失败：气泡标失败态 + 服务端文案 SnackBar，点气泡重发成功', (tester) async {
      await mockNetworkImagesFor(() async {
        final fake = FakeWeiyueService()..failDmSend = true;
        await pumpChat(tester, fake);
        await tester.enterText(find.byType(TextField), '注定失败的一条');
        await tester.tap(find.byIcon(Icons.send));
        await _settle(tester);
        expect(find.text('注定失败的一条'), findsOneWidget);
        expect(find.text('发送失败，点击重发'), findsOneWidget);
        expect(find.textContaining('对方设置了私信权限（假）'), findsOneWidget);

        fake.failDmSend = false;
        await tester.tap(find.text('发送失败，点击重发'));
        await _settle(tester);
        expect(find.text('发送失败，点击重发'), findsNothing);
        expect(find.text('注定失败的一条'), findsOneWidget);
        expect(fake.dmSendCalls.length, 2);
        // 排掉 SnackBar 计时器，避免测试结束挂起
        await tester.pump(const Duration(seconds: 5));
      });
    });

    testWidgets('加载更早：按钮触发 maxId 续拉，到底后按钮消失', (tester) async {
      await mockNetworkImagesFor(() async {
        final fake = FakeWeiyueService();
        fake.dmHistoryStore['1641537791'] = [
          for (var i = 1; i <= 25; i++)
            DmMessage(
              id: 100 + i,
              senderId: i.isEven ? 777 : 1641537791,
              text: '历史消息 $i',
              createdAt: DateTime(2026, 11, 12, 9, i),
            ),
        ];
        await pumpChat(tester, fake);
        // 首屏只拉最新 20 条（服务默认 count），跳底后顶部按钮
        // 不在构建范围，拖到顶部才可见
        expect(fake.dmHistoryCalls, ['1641537791:0:false']);
        await tester.dragUntilVisible(
          find.text('加载更早的消息'),
          find.byType(ListView),
          const Offset(0, 100),
        );
        await tester.tap(find.text('加载更早的消息'));
        await _settle(tester);
        // 续拉游标 = 已加载最旧一条 id（106）
        expect(fake.dmHistoryCalls.last, '1641537791:106:false');
        expect(find.text('加载更早的消息'), findsNothing);
      });
    });
  });
}
