import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/screens/profile_screen.dart';
import 'package:weiyue/services/weiyue_service.dart';
import 'package:weiyue/widgets/status_card.dart';

import '../helpers/fakes.dart';

/// 记录写动作调用的假服务：可指定某个动作抛错，验证乐观更新/回滚。
class _ActionService extends FakeWeiyueService {
  int likeCalls = 0;
  int unlikeCalls = 0;
  int favCalls = 0;
  int unfavCalls = 0;
  int repostCalls = 0;
  int followCalls = 0;
  int unfollowCalls = 0;
  String? lastRepostComment;
  final List<(String, String)> commentCalls = [];
  final List<(String, String, String)> replyCalls = [];
  Object? likeError;
  Object? favError;
  Object? followError;
  bool profileFollowing = false;

  @override
  Future<void> likeStatus(String id) async {
    likeCalls++;
    if (likeError != null) throw likeError!;
  }

  @override
  Future<void> unlikeStatus(String id) async {
    unlikeCalls++;
  }

  @override
  Future<void> createFavorite(String id) async {
    favCalls++;
    if (favError != null) throw favError!;
  }

  @override
  Future<void> destroyFavorite(String id) async {
    unfavCalls++;
  }

  @override
  Future<void> repostStatus(String id, {String comment = ''}) async {
    repostCalls++;
    lastRepostComment = comment;
  }

  @override
  Future<WbComment?> createComment(String statusId, String text) async {
    commentCalls.add((statusId, text));
    return null;
  }

  @override
  Future<WbComment?> replyComment({
    required String statusId,
    required String commentId,
    required String text,
  }) async {
    replyCalls.add((statusId, commentId, text));
    return null;
  }

  @override
  Future<void> followUser(String uid) async {
    followCalls++;
    if (followError != null) throw followError!;
  }

  @override
  Future<void> unfollowUser(String uid) async {
    unfollowCalls++;
  }

  @override
  Future<WbUser> getProfileInfo(String uid) async {
    final base = await super.getProfileInfo(uid);
    return base.copyWith(following: profileFollowing);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<void> _pumpCard(
  WidgetTester tester,
  _ActionService svc,
  WbStatus status, {
  bool loggedIn = true,
}) {
  return mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      wrapWithProviders(
        Scaffold(body: SingleChildScrollView(child: StatusCard(
          status: status,
          tappable: false,
        ))),
        weibo: svc,
        session: FakeSessionService(loggedIn: loggedIn),
      ),
    );
    await _settle(tester);
  });
}

void main() {
  group('卡片动作条', () {
    testWidgets('点赞：乐观更新（红心+计数+1），调 setLike', (tester) async {
      final svc = _ActionService();
      await _pumpCard(tester, svc, makeStatus(attitudes: 9));
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('9'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.favorite_border));
      await _settle(tester);

      expect(svc.likeCalls, 1);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
    });

    testWidgets('取消赞：已赞态点心形调 cancelLike 并计数-1', (tester) async {
      final svc = _ActionService();
      await _pumpCard(
        tester,
        svc,
        makeStatus(attitudes: 9).copyWith(liked: true),
      );
      await tester.tap(find.byIcon(Icons.favorite));
      await _settle(tester);
      expect(svc.unlikeCalls, 1);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
    });

    testWidgets('点赞失败：回滚图标与计数，弹服务端消息', (tester) async {
      final svc = _ActionService()
        ..likeError = const WeiyueException('FAKE 不能重复点赞');
      await _pumpCard(tester, svc, makeStatus(attitudes: 9));
      await tester.tap(find.byIcon(Icons.favorite_border));
      await _settle(tester);
      expect(svc.likeCalls, 1);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('FAKE 不能重复点赞'), findsOneWidget);
    });

    testWidgets('收藏：切换书签态并提示，取消再切回', (tester) async {
      final svc = _ActionService();
      await _pumpCard(tester, svc, makeStatus());
      await tester.tap(find.byIcon(Icons.bookmark_border));
      await _settle(tester);
      expect(svc.favCalls, 1);
      expect(find.byIcon(Icons.bookmark), findsOneWidget);
      expect(find.text('已收藏'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.bookmark));
      await _settle(tester);
      expect(svc.unfavCalls, 1);
      expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
      expect(find.text('已取消收藏'), findsOneWidget);
    });

    testWidgets('收藏失败：回滚书签态并弹消息', (tester) async {
      final svc = _ActionService()
        ..favError = const WeiyueException('FAKE 收藏失败');
      await _pumpCard(tester, svc, makeStatus());
      await tester.tap(find.byIcon(Icons.bookmark_border));
      await _settle(tester);
      expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
      expect(find.text('FAKE 收藏失败'), findsOneWidget);
    });

    testWidgets('未登录点赞：只提示「登录后可用」，不发请求', (tester) async {
      final svc = _ActionService();
      await _pumpCard(tester, svc, makeStatus(), loggedIn: false);
      await tester.tap(find.byIcon(Icons.favorite_border));
      await _settle(tester);
      expect(svc.likeCalls, 0);
      expect(find.text('登录后可用'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
    });

    testWidgets('转发：编辑框提交转发语，成功计数+1', (tester) async {
      final svc = _ActionService();
      await _pumpCard(tester, svc, makeStatus(reposts: 3));
      await tester.tap(find.byIcon(Icons.repeat));
      await _settle(tester);
      expect(find.text('转发动态'), findsOneWidget); // 编辑框标题

      await tester.enterText(find.byType(TextField), '说得好');
      await tester.tap(find.text('转发'));
      await _settle(tester);

      expect(svc.repostCalls, 1);
      expect(svc.lastRepostComment, '说得好');
      expect(find.text('4'), findsOneWidget);
      expect(find.text('转发成功'), findsOneWidget);
    });

    testWidgets('转发：空语也可直接提交（无语转发）', (tester) async {
      final svc = _ActionService();
      await _pumpCard(tester, svc, makeStatus(reposts: 3));
      await tester.tap(find.byIcon(Icons.repeat));
      await _settle(tester);
      await tester.tap(find.text('转发'));
      await _settle(tester);
      expect(svc.repostCalls, 1);
      expect(svc.lastRepostComment, '');
    });
  });

  group('详情页评论', () {
    Future<void> pumpDetail(WidgetTester tester, _ActionService svc) {
      return mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            DetailScreen(status: makeStatus(id: '1001')),
            weibo: svc,
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);
      });
    }

    testWidgets('评论按钮打开编辑框：空文本发送禁用，输入后组装参数提交', (
      tester,
    ) async {
      final svc = _ActionService();
      await pumpDetail(tester, svc);

      await tester.tap(find.byIcon(Icons.mode_comment_outlined));
      await _settle(tester);
      expect(find.text('发表评论'), findsOneWidget);
      // 空文本时发送禁用
      final sendBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '发送'),
      );
      expect(sendBtn.onPressed, isNull);
      expect(svc.commentCalls, isEmpty);

      await tester.enterText(find.byType(TextField), '新评论内容');
      await _settle(tester);
      await tester.tap(find.text('发送'));
      await _settle(tester);

      expect(svc.commentCalls, [('1001', '新评论内容')]);
      expect(find.text('评论已发表'), findsOneWidget);
    });

    testWidgets('评论的「回复」：打开回复编辑框并以 cid 提交', (tester) async {
      final svc = _ActionService();
      await pumpDetail(tester, svc);

      final replyFinder = find.text('回复');
      await tester.ensureVisible(replyFinder);
      await _settle(tester);
      await tester.tap(replyFinder);
      await _settle(tester);
      expect(find.text('回复评论'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '回复内容');
      await _settle(tester); // 等编辑框重建出「发送」可点态
      await tester.tap(find.widgetWithText(FilledButton, '发送'));
      await _settle(tester);

      // FakeWeiyueService 的评论固定为 c1
      expect(svc.replyCalls, [('1001', 'c1', '回复内容')]);
      expect(find.text('回复已发送'), findsOneWidget);
    });
  });

  group('用户主页关注按钮', () {
    Future<void> pumpProfile(
      WidgetTester tester,
      _ActionService svc, {
      bool loggedIn = true,
    }) {
      return mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            const ProfileScreen(uid: '42'),
            weibo: svc,
            session: FakeSessionService(loggedIn: loggedIn),
          ),
        );
        await _settle(tester);
      });
    }

    testWidgets('未关注→点「关注」调 create 并变「已关注」，再点取关切回', (tester) async {
      final svc = _ActionService();
      await pumpProfile(tester, svc);
      // 注意：资料头计数行也有「关注」标签，按钮用类型+文本定位
      final followBtn = find.widgetWithText(FilledButton, '关注');
      expect(followBtn, findsOneWidget);

      await tester.tap(followBtn);
      await _settle(tester);
      expect(svc.followCalls, 1);
      final unfollowBtn = find.widgetWithText(OutlinedButton, '已关注');
      expect(unfollowBtn, findsOneWidget);

      await tester.tap(unfollowBtn);
      await _settle(tester);
      expect(svc.unfollowCalls, 1);
      expect(find.widgetWithText(FilledButton, '关注'), findsOneWidget);
    });

    testWidgets('接口 following=true 时初始即「已关注」', (tester) async {
      final svc = _ActionService()..profileFollowing = true;
      await pumpProfile(tester, svc);
      expect(find.widgetWithText(OutlinedButton, '已关注'), findsOneWidget);
    });

    testWidgets('关注失败：回滚为「关注」并弹服务端消息', (tester) async {
      final svc = _ActionService()
        ..followError = const WeiyueException('FAKE 关注失败');
      await pumpProfile(tester, svc);
      await tester.tap(find.widgetWithText(FilledButton, '关注'));
      await _settle(tester);
      expect(svc.followCalls, 1);
      expect(find.widgetWithText(FilledButton, '关注'), findsOneWidget);
      expect(find.text('FAKE 关注失败'), findsOneWidget);
    });

    testWidgets('未登录点关注：只提示不发请求', (tester) async {
      final svc = _ActionService();
      await pumpProfile(tester, svc, loggedIn: false);
      await tester.tap(find.widgetWithText(FilledButton, '关注'));
      await _settle(tester);
      expect(svc.followCalls, 0);
      expect(find.text('登录后可用'), findsOneWidget);
    });
  });
}
