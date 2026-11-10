import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/core/nav.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/services/weiyue_service.dart';
import 'package:weiyue/widgets/status_card.dart';

import '../helpers/fakes.dart';

/// 删除功能组件测试：假会话登录 uid 固定为 '777'（FakeSessionService）。
/// - 卡片：本人帖子（authorId=777）右上角更多菜单含「删除动态」，
///   他人帖子/未登录不出菜单；确认后调 destroy，失败弹服务端消息。
/// - 详情评论：本人评论与本人楼中楼回复有「删除」入口，他人没有；
///   删成功条目消失，失败条目保留并弹消息。
/// - 详情删帖：成功后关页返回，来源侧（openDetail）弹「动态已删除」。
class _DeleteService extends FakeWeiyueService {
  final List<String> deleteCommentCalls = [];
  final List<String> deleteStatusCalls = [];
  Object? deleteCommentError;
  Object? deleteStatusError;

  /// 详情页 getStatus 刷新后的帖子作者（控制详情卡是否本人帖）。
  int statusAuthorId = 42;

  @override
  Future<void> deleteComment(String cid) async {
    deleteCommentCalls.add(cid);
    if (deleteCommentError != null) throw deleteCommentError!;
  }

  @override
  Future<void> deleteStatus(String id) async {
    deleteStatusCalls.add(id);
    if (deleteStatusError != null) throw deleteStatusError!;
  }

  @override
  Future<WbStatus> getStatus(String id) async =>
      makeStatus(id: id, authorId: statusAuthorId, comments: 3);

  @override
  Future<({List<WbComment> comments, int total, int maxId})> getComments(
    String id, {
    required String authorUid,
    int maxId = 0,
  }) async {
    const me = WbUser(id: 777, screenName: '登录测试号');
    const other = WbUser(id: 42, screenName: '测试博主');
    const at = 'Mon Oct 26 13:15:08 +0800 2026';
    return (
      comments: [
        const WbComment(
          id: 'c1',
          user: me,
          text: '我自己的评论',
          createdAtRaw: at,
          replies: [
            WbComment(id: 'r1', user: me, text: '我自己的回复', createdAtRaw: at),
            WbComment(id: 'r2', user: other, text: '别人的回复', createdAtRaw: at),
          ],
        ),
        const WbComment(
          id: 'c2',
          user: other,
          text: '别人的评论',
          createdAtRaw: at,
        ),
      ],
      total: 3,
      maxId: 0,
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<void> _pumpCard(
  WidgetTester tester,
  _DeleteService svc,
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

Future<void> _pumpDetail(WidgetTester tester, _DeleteService svc) {
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

/// 打开确认框并点「删除」确认。
Future<void> _confirmDelete(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '删除'));
  await _settle(tester);
}

void main() {
  group('卡片删帖', () {
    testWidgets('本人帖子：更多菜单含删除动态，确认后调 destroy 并提示', (tester) async {
      final svc = _DeleteService();
      await _pumpCard(tester, svc, makeStatus(authorId: 777));

      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await _settle(tester);
      expect(find.text('删除动态'), findsOneWidget);

      await tester.tap(find.text('删除动态'));
      await _settle(tester);
      expect(find.text('删除这条动态？'), findsOneWidget);

      await _confirmDelete(tester);
      expect(svc.deleteStatusCalls, ['1001']);
      expect(find.text('动态已删除'), findsOneWidget);
    });

    testWidgets('他人帖子：无更多菜单', (tester) async {
      final svc = _DeleteService();
      await _pumpCard(tester, svc, makeStatus(authorId: 42));
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets('未登录：本人 id 的帖子也不出菜单', (tester) async {
      final svc = _DeleteService();
      await _pumpCard(tester, svc, makeStatus(authorId: 777), loggedIn: false);
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets('删帖失败：弹服务端消息，不提示已删除', (tester) async {
      final svc = _DeleteService()
        ..deleteStatusError = const WeiyueException('FAKE 删除失败');
      await _pumpCard(tester, svc, makeStatus(authorId: 777));

      await tester.tap(find.byIcon(Icons.more_vert));
      await _settle(tester);
      await tester.tap(find.text('删除动态'));
      await _settle(tester);
      await _confirmDelete(tester);

      expect(svc.deleteStatusCalls, ['1001']);
      expect(find.text('FAKE 删除失败'), findsOneWidget);
      expect(find.text('动态已删除'), findsNothing);
    });
  });

  group('详情页删评论', () {
    testWidgets('删除入口只出现在本人评论与本人回复上', (tester) async {
      final svc = _DeleteService();
      await _pumpDetail(tester, svc);

      expect(find.text('我自己的评论'), findsOneWidget);
      expect(find.text('别人的评论'), findsOneWidget);
      // 本人顶级评论 c1 + 本人回复 r1 各一个「删除」；他人条目没有。
      expect(find.text('删除'), findsNWidgets(2));
    });

    testWidgets('删顶级评论成功：条目消失，总数同步', (tester) async {
      final svc = _DeleteService();
      await _pumpDetail(tester, svc);

      await tester.tap(find.text('删除').first);
      await _settle(tester);
      expect(find.text('删除这条评论？'), findsOneWidget);
      await _confirmDelete(tester);

      expect(svc.deleteCommentCalls, ['c1']);
      expect(find.text('我自己的评论'), findsNothing);
      expect(find.text('我自己的回复'), findsNothing); // 随父评论一并摘除
      expect(find.text('别人的评论'), findsOneWidget);
      expect(find.text('评论已删除'), findsOneWidget);
    });

    testWidgets('删楼中楼回复成功：只摘该回复，父评论保留', (tester) async {
      final svc = _DeleteService();
      await _pumpDetail(tester, svc);

      // 第二个「删除」是本人回复 r1 的入口（树序在父评论之后）。
      await tester.tap(find.text('删除').at(1));
      await _settle(tester);
      await _confirmDelete(tester);

      expect(svc.deleteCommentCalls, ['r1']);
      expect(find.text('我自己的回复'), findsNothing);
      expect(find.text('我自己的评论'), findsOneWidget);
      expect(find.text('别人的回复'), findsOneWidget);
    });

    testWidgets('删评论失败：条目保留并弹服务端消息', (tester) async {
      final svc = _DeleteService()
        ..deleteCommentError = const WeiyueException('FAKE 评论删除失败');
      await _pumpDetail(tester, svc);

      await tester.tap(find.text('删除').first);
      await _settle(tester);
      await _confirmDelete(tester);

      expect(svc.deleteCommentCalls, ['c1']);
      expect(find.text('我自己的评论'), findsOneWidget);
      expect(find.text('FAKE 评论删除失败'), findsOneWidget);
      expect(find.text('评论已删除'), findsNothing);
    });
  });

  group('详情页删自己的帖子', () {
    testWidgets('删成功后关页返回，来源侧提示已删除', (tester) async {
      final svc = _DeleteService()..statusAuthorId = 777;
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          wrapWithProviders(
            Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () =>
                        openDetail(context, makeStatus(id: '1001')),
                    child: const Text('打开详情'),
                  ),
                ),
              ),
            ),
            weibo: svc,
            session: FakeSessionService(loggedIn: true),
          ),
        );
        await _settle(tester);

        await tester.tap(find.text('打开详情'));
        await _settle(tester);
        expect(find.byType(DetailScreen), findsOneWidget);

        await tester.tap(find.byIcon(Icons.more_vert));
        await _settle(tester);
        await tester.tap(find.text('删除动态'));
        await _settle(tester);
        await _confirmDelete(tester);
        // 对话框退出 + 路由退出动画串行，再多泵一段让关页与
        // openDetail 的结果提示都落定。
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(svc.deleteStatusCalls, ['1001']);
        expect(find.byType(DetailScreen), findsNothing);
        expect(find.text('动态已删除'), findsOneWidget);
      });
    });
  });
}
