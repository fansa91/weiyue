import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/screens/favorites_screen.dart';
import 'package:weiyue/screens/home_screen.dart';
import 'package:weiyue/screens/login_screen.dart';
import 'package:weiyue/screens/me_screen.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

/// 评论带楼中楼的假服务：total 与已加载一致（登录态拉全后的形态）。
class _RepliesFakeService extends FakeWeiyueService {
  @override
  Future<({List<WbComment> comments, int total, int maxId})> getComments(
    String id, {
    required String authorUid,
    int maxId = 0,
  }) async => (
    comments: [
      WbComment(
        id: 'c1',
        user: makeStatus().user,
        text: '带回复的主评论',
        createdAtRaw: 'Mon Oct 26 13:15:08 +0800 2026',
        source: '来自 湖南',
        likeCount: 12,
        replies: [
          WbComment(
            id: 'r1',
            user: makeStatus().user,
            text: '楼中楼回复内容',
            createdAtRaw: 'Mon Oct 26 13:16:08 +0800 2026',
          ),
        ],
      ),
    ],
    total: 1,
    maxId: 0,
  );
}

void main() {
  group('MeScreen 账号区', () {
    testWidgets('未登录：显示账号登录入口，无我的收藏', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(wrapWithProviders(const MeScreen()));
        await _settle(tester);
        expect(find.text('账号登录'), findsOneWidget);
        expect(find.text('我的收藏'), findsNothing);
        expect(find.text('退出登录'), findsNothing);
      });
    });

    testWidgets('已登录：昵称/两栈状态/我的收藏/退出登录齐全', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            const MeScreen(),
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        expect(find.text('登录测试号'), findsOneWidget);
        expect(find.text('我的收藏'), findsOneWidget);
        expect(find.text('退出登录'), findsOneWidget);
        // FakeSessionService：PC 已解锁、m 未解锁
        expect(find.text('已解锁'), findsOneWidget);
        expect(find.text('未解锁'), findsOneWidget);
        expect(find.text('登录已过期，请重新登录'), findsNothing);
      });
    });

    testWidgets('已过期：显示过期提示与重新登录', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            const MeScreen(),
            session: FakeSessionService(loggedIn: true, expiredFlag: true),
          ),
        );
        await _settle(tester);
        expect(find.text('登录已过期，请重新登录'), findsOneWidget);
        expect(find.text('重新登录'), findsOneWidget);
      });
    });
  });

  group('HomeScreen 关注频道', () {
    testWidgets('未登录：无关注频道', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(wrapWithProviders(const HomeScreen()));
        await _settle(tester);
        expect(find.text('关注'), findsNothing);
        expect(find.text('热门'), findsOneWidget);
      });
    });

    testWidgets('已登录：关注排最前，点开是关注流', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            const HomeScreen(),
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        final friendsChip = find.text('关注');
        final hotChip = find.text('热门');
        expect(friendsChip, findsOneWidget);
        expect(
          tester.getTopLeft(friendsChip).dx,
          lessThan(tester.getTopLeft(hotChip).dx),
        );
        await tester.tap(friendsChip);
        await _settle(tester);
        expect(
          find.textContaining('关注流第一条', findRichText: true),
          findsOneWidget,
        );
      });
    });
  });

  group('DetailScreen 登录态', () {
    testWidgets('已登录：转发页签拉到转发列表（不再是访客占位）', (tester) async {
      await mockNetworkImagesFor(() async {
        final status = makeStatus(id: '9', text: '详情页原文', reposts: 3);
        await tester.pumpWidget(
          wrapWithProviders(
            DetailScreen(status: status),
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        await tester.tap(find.textContaining('转发'));
        await _settle(tester);
        expect(
          find.textContaining('转发内容一', findRichText: true),
          findsOneWidget,
        );
        expect(find.textContaining('转发列表访客不可见'), findsNothing);
      });
    });

    testWidgets('未登录：转发页签仍是访客占位', (tester) async {
      await mockNetworkImagesFor(() async {
        final status = makeStatus(id: '9', text: '详情页原文', reposts: 3);
        await tester.pumpWidget(
          wrapWithProviders(DetailScreen(status: status)),
        );
        await _settle(tester);
        await tester.tap(find.textContaining('转发'));
        await _settle(tester);
        expect(find.textContaining('转发列表访客不可见'), findsOneWidget);
      });
    });

    testWidgets('已登录：楼中楼回复缩进渲染，且无访客横幅', (tester) async {
      await mockNetworkImagesFor(() async {
        final status = makeStatus(id: '9', text: '详情页原文', comments: 1);
        await tester.pumpWidget(
          wrapWithProviders(
            DetailScreen(status: status),
            weibo: _RepliesFakeService(),
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
        expect(
          find.textContaining('带回复的主评论', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.textContaining('楼中楼回复内容', findRichText: true),
          findsOneWidget,
        );
        expect(find.textContaining('访客仅显示热评'), findsNothing);
      });
    });
  });

  testWidgets('FavoritesScreen：收藏帖子流', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        wrapWithProviders(
          const FavoritesScreen(),
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      expect(find.text('我的收藏'), findsOneWidget);
      expect(find.textContaining('收藏的帖子一', findRichText: true), findsOneWidget);
    });
  });

  testWidgets('LoginScreen：无 WebView 实现的平台显示不支持提示', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(wrapWithProviders(const LoginScreen()));
      await _settle(tester);
      expect(find.text('账号登录'), findsOneWidget);
      // 本测试机为 Linux（四端之外），走平台不支持分支
      expect(find.text('当前平台暂不支持内置登录页'), findsOneWidget);
    });
  });
}
