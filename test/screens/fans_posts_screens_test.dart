import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/fans_screen.dart';
import 'package:weiyue/screens/me_screen.dart';
import 'package:weiyue/screens/my_posts_screen.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 我的粉丝页 + 我的帖子页的界面测试。数据均为构造假数据，
/// 登录态真实行为待用户真机验证。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

class _FansPostsService extends FakeWeiyueService {
  final List<String> followCalls = [];
  final List<String> unfollowCalls = [];
  final List<String> deleteStatusCalls = [];
  Object? followError;
  Object? deleteStatusError;

  static const _fans = [
    WbUser(
      id: 6001,
      screenName: '粉丝甲',
      avatar: 'https://example.com/fa.jpg',
      description: '甲是粉丝',
      followersCount: 11,
      following: false,
      followMe: true,
    ),
    WbUser(
      id: 6002,
      screenName: '粉丝乙',
      avatar: 'https://example.com/fb.jpg',
      description: '乙是粉丝',
      followersCount: 22,
      following: true,
      followMe: true,
    ),
    WbUser(
      id: 6003,
      screenName: '粉丝丙',
      avatar: 'https://example.com/fc.jpg',
      description: '丙是粉丝',
      followersCount: 33,
      following: true,
      followMe: false,
    ),
  ];

  @override
  Future<({List<WbUser> users, int total})> getMyFans(
    String uid, {
    int page = 1,
    int count = 20,
  }) async => (users: page == 1 ? _fans : const <WbUser>[], total: 3);

  @override
  Future<void> followUser(String uid) async {
    if (followError != null) throw followError!;
    followCalls.add(uid);
  }

  @override
  Future<void> unfollowUser(String uid) async {
    unfollowCalls.add(uid);
  }

  @override
  Future<ContainerPage> getUserStatuses(String uid, {int page = 1}) async =>
      ContainerPage(
        statuses: page == 1
            ? [
                makeStatus(id: 'mp1', text: '我的帖子一', authorId: 777),
                makeStatus(id: 'mp2', text: '我的帖子二', authorId: 777),
              ]
            : const [],
        total: 2,
        nextPage: page + 1,
      );

  @override
  Future<void> deleteStatus(String id) async {
    deleteStatusCalls.add(id);
    if (deleteStatusError != null) throw deleteStatusError!;
  }
}

const _profileUser = WbUser(
  id: 777,
  screenName: '构造测试本人',
  followersCount: 3,
  friendsCount: 321,
  statusesCount: 2,
);

Future<void> _pumpFans(WidgetTester tester, _FansPostsService svc) {
  return mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      wrapWithProviders(
        const FansScreen(uid: '777'),
        weibo: svc,
        session: FakeSessionService(loggedIn: true),
      ),
    );
    await _settle(tester);
  });
}

Future<void> _pumpPosts(WidgetTester tester, _FansPostsService svc) {
  return mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      wrapWithProviders(
        const MyPostsScreen(),
        weibo: svc,
        session: FakeSessionService(loggedIn: true),
      ),
    );
    await _settle(tester);
  });
}

void main() {
  group('FansScreen', () {
    testWidgets('列表渲染：总数 + 三种关系态按钮文案', (tester) async {
      final svc = _FansPostsService();
      await _pumpFans(tester, svc);

      expect(find.text('我的粉丝'), findsOneWidget);
      expect(find.text('共有 3 位粉丝'), findsOneWidget);
      expect(find.text('粉丝甲'), findsOneWidget);
      expect(find.text('粉丝乙'), findsOneWidget);
      expect(find.text('粉丝丙'), findsOneWidget);
      // following/follow_me 组合：甲未回关、乙互相关注、丙已关注
      expect(find.widgetWithText(FilledButton, '回关'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '互相关注'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '已关注'), findsOneWidget);
    });

    testWidgets('点「回关」调 followUser，成功后按钮变互相关注', (tester) async {
      final svc = _FansPostsService();
      await _pumpFans(tester, svc);

      await tester.tap(find.widgetWithText(FilledButton, '回关'));
      await _settle(tester);

      expect(svc.followCalls, ['6001']);
      expect(find.widgetWithText(FilledButton, '回关'), findsNothing);
      // 甲乙都成互相关注
      expect(find.widgetWithText(OutlinedButton, '互相关注'), findsNWidgets(2));
    });

    testWidgets('点「互相关注」调 unfollowUser，成功后按钮变回关', (tester) async {
      final svc = _FansPostsService();
      await _pumpFans(tester, svc);

      await tester.tap(find.widgetWithText(OutlinedButton, '互相关注'));
      await _settle(tester);

      expect(svc.unfollowCalls, ['6002']);
      // 甲乙都成未回关
      expect(find.widgetWithText(FilledButton, '回关'), findsNWidgets(2));
    });

    testWidgets('回关失败：回滚按钮态并弹服务端消息', (tester) async {
      final svc = _FansPostsService()
        ..followError = const WeiyueException('FAKE 回关失败');
      await _pumpFans(tester, svc);

      await tester.tap(find.widgetWithText(FilledButton, '回关'));
      await _settle(tester);

      expect(find.widgetWithText(FilledButton, '回关'), findsOneWidget);
      expect(find.text('FAKE 回关失败'), findsOneWidget);
    });
  });

  group('MyPostsScreen', () {
    testWidgets('列表渲染本人帖子（菜单在）', (tester) async {
      final svc = _FansPostsService();
      await _pumpPosts(tester, svc);

      expect(find.text('我的帖子'), findsOneWidget);
      expect(find.text('我的帖子一'), findsOneWidget);
      expect(find.text('我的帖子二'), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsNWidgets(2));
    });

    testWidgets('删帖流：菜单→确认→调 destroy→条目即时移除+提示', (tester) async {
      final svc = _FansPostsService();
      await _pumpPosts(tester, svc);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await _settle(tester);
      expect(find.text('删除动态'), findsOneWidget);
      await tester.tap(find.text('删除动态'));
      await _settle(tester);
      expect(find.text('删除这条动态？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await _settle(tester);

      expect(svc.deleteStatusCalls, ['mp1']);
      expect(find.text('我的帖子一'), findsNothing);
      expect(find.text('我的帖子二'), findsOneWidget);
      expect(find.text('动态已删除'), findsOneWidget);
    });

    testWidgets('删帖失败：条目保留并弹服务端消息', (tester) async {
      final svc = _FansPostsService()
        ..deleteStatusError = const WeiyueException('FAKE 删除失败');
      await _pumpPosts(tester, svc);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await _settle(tester);
      await tester.tap(find.text('删除动态'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await _settle(tester);

      expect(svc.deleteStatusCalls, ['mp1']);
      expect(find.text('我的帖子一'), findsOneWidget);
      expect(find.text('FAKE 删除失败'), findsOneWidget);
      expect(find.text('动态已删除'), findsNothing);
    });
  });

  group('MeScreen 入口', () {
    testWidgets('粉丝计数可点进粉丝页；我的帖子行进我的帖子页', (tester) async {
      final svc = _FansPostsService();
      await mockNetworkImagesFor(() async {
        final session = FakeSessionService(loggedIn: true)
          ..fakeProfile = _profileUser;
        await tester.pumpWidget(
          wrapWithProviders(const MeScreen(), weibo: svc, session: session),
        );
        await _settle(tester);

        // 资料头「粉丝」计数点进粉丝页
        await tester.tap(find.text('粉丝'));
        await _settle(tester);
        expect(find.byType(FansScreen), findsOneWidget);
        expect(find.text('粉丝甲'), findsOneWidget);
        await tester.pageBack();
        await _settle(tester);
        // 等返回动画彻底结束、粉丝页离开树，否则 scrollUntilVisible
        // 按全树唯一 Scrollable 定位会撞上粉丝页尚未退出的 ListView。
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();

        // 列表区「我的帖子」行
        await tester.scrollUntilVisible(find.text('我的帖子'), 200);
        await tester.tap(find.text('我的帖子'));
        await _settle(tester);
        expect(find.byType(MyPostsScreen), findsOneWidget);
        expect(find.text('我的帖子一'), findsOneWidget);
      });
    });
  });
}
