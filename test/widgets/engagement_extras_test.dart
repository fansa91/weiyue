import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/screens/home_screen.dart';
import 'package:weiyue/screens/likes_screen.dart';
import 'package:weiyue/screens/me_screen.dart';
import 'package:weiyue/screens/profile_screen.dart';
import 'package:weiyue/widgets/interactions.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// 评论假服务：一条顶级评论（12 赞）+ 一条楼中楼（3 赞）。
class _CommentLikeFakeService extends FakeWeiyueService {
  @override
  Future<({List<WbComment> comments, int total, int maxId})> getComments(
    String id, {
    required String authorUid,
    int maxId = 0,
  }) async {
    if (maxId != 0) {
      return (comments: const <WbComment>[], total: 1, maxId: 0);
    }
    return (
      comments: [
        WbComment(
          id: 'c-top',
          user: makeStatus().user,
          text: '顶级评论一条',
          createdAtRaw: 'Mon Oct 26 13:15:08 +0800 2026',
          likeCount: 12,
          replies: [
            WbComment(
              id: 'c-reply',
              user: makeStatus().user,
              text: '楼中楼回复一条',
              createdAtRaw: 'Mon Oct 26 13:16:08 +0800 2026',
              likeCount: 3,
            ),
          ],
        ),
      ],
      total: 1,
      maxId: 0,
    );
  }
}

void main() {
  testWidgets('我赞过的：列表渲染赞过的帖子', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        wrapWithProviders(
          const LikesScreen(),
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      expect(find.text('我赞过的帖子一'), findsOneWidget);
      expect(find.text('我赞过的帖子二'), findsOneWidget);
    });
  });

  testWidgets('我的页：我赞过的入口进入赞列表页', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        wrapWithProviders(
          const MeScreen(),
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      expect(find.text('我赞过的'), findsOneWidget);
      await tester.tap(find.text('我赞过的'));
      await _settle(tester);
      expect(find.byType(LikesScreen), findsOneWidget);
      expect(find.text('我赞过的帖子一'), findsOneWidget);
    });
  });

  testWidgets('评论点赞：顶级评论与楼中楼都可赞/取消，计数乐观增减', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = _CommentLikeFakeService();
      await tester.pumpWidget(
        wrapWithProviders(
          DetailScreen(status: makeStatus(id: '9', text: '详情页原文')),
          weibo: fake,
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      expect(find.text('顶级评论一条'), findsOneWidget);
      final likeButtons = find.byType(CommentLikeButton);
      expect(likeButtons, findsNWidgets(2));
      Finder countIn(Finder button, String text) =>
          find.descendant(of: button, matching: find.text(text));
      expect(countIn(likeButtons.first, '12'), findsOneWidget);
      expect(countIn(likeButtons.last, '3'), findsOneWidget);

      // 顶级评论点赞：计数 12→13，服务收到 c-top
      await tester.tap(likeButtons.first);
      await _settle(tester);
      expect(fake.likedCommentIds, ['c-top']);
      expect(countIn(likeButtons.first, '13'), findsOneWidget);

      // 再点取消：计数回 12
      await tester.tap(likeButtons.first);
      await _settle(tester);
      expect(fake.unlikedCommentIds, ['c-top']);
      expect(countIn(likeButtons.first, '12'), findsOneWidget);

      // 楼中楼点赞：计数 3→4，服务收到 c-reply
      await tester.tap(likeButtons.last);
      await _settle(tester);
      expect(fake.likedCommentIds, ['c-top', 'c-reply']);
      expect(countIn(likeButtons.last, '4'), findsOneWidget);
    });
  });

  testWidgets('评论点赞失败：回滚计数并提示', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = _CommentLikeFakeService()..failCommentLike = true;
      await tester.pumpWidget(
        wrapWithProviders(
          DetailScreen(status: makeStatus(id: '9', text: '详情页原文')),
          weibo: fake,
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      final button = find.byType(CommentLikeButton).first;
      await tester.tap(button);
      await _settle(tester);
      expect(
        find.descendant(of: button, matching: find.text('12')),
        findsOneWidget,
      );
      expect(find.textContaining('点赞失败'), findsOneWidget);
    });
  });

  testWidgets('首页分组频道：登录后出现分组 chip，点开看分组流', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakeWeiyueService()
        ..followGroups = const [
          WbFollowGroup(gid: '100051641537045', title: '悄悄关注'),
        ];
      await tester.pumpWidget(
        wrapWithProviders(
          const HomeScreen(),
          weibo: fake,
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      expect(find.text('悄悄关注'), findsOneWidget);
      await tester.tap(find.text('悄悄关注'));
      await _settle(tester);
      expect(fake.groupTimelineGids, ['100051641537045']);
      expect(find.text('分组流帖子一'), findsOneWidget);
    });
  });

  testWidgets('首页分组频道：未登录不出现分组', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakeWeiyueService()
        ..followGroups = const [
          WbFollowGroup(gid: '100051641537045', title: '悄悄关注'),
        ];
      await tester.pumpWidget(
        wrapWithProviders(const HomeScreen(), weibo: fake),
      );
      await _settle(tester);
      expect(find.text('悄悄关注'), findsNothing);
    });
  });

  testWidgets('用户主页拉黑：更多菜单→确认框→已拉黑态与提示', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakeWeiyueService();
      await tester.pumpWidget(
        wrapWithProviders(
          const ProfileScreen(uid: '42'),
          weibo: fake,
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await _settle(tester);
      await tester.tap(find.text('屏蔽/拉黑'));
      await _settle(tester);
      // 主包同款对话框：标题+三开关（默认全开）
      expect(find.text('屏蔽用户'), findsOneWidget);
      expect(find.text('不看TA的微博'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await _settle(tester);
      expect(fake.filterUserCalls, hasLength(1));
      expect(fake.filterUserCalls.single.uid, '42');
      expect(fake.filterUserCalls.single.statuses, isTrue);
      expect(fake.filterUserCalls.single.interact, isTrue);
      expect(fake.filterUserCalls.single.follow, isTrue);
      // 关注按钮让位给「已拉黑」，且有成功提示
      expect(find.text('已拉黑'), findsWidgets);
    });
  });
}
