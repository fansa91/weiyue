import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void _usePhoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 评论两页（首页 10 条 + 游标页 5 条，共 15）与转发两页的假服务，
/// 记录每次分页请求的参数，供滚动续拉断言。
class _PagedDetailFakeService extends FakeWeiyueService {
  final List<int> commentMaxIds = [];
  final List<int> repostPages = [];

  WbComment _comment(String id, String text) => WbComment(
        id: id,
        user: makeStatus().user,
        text: text,
        createdAtRaw: 'Mon Oct 26 13:15:08 +0800 2026',
        source: '来自 湖南',
        likeCount: 1,
      );

  @override
  Future<({List<WbComment> comments, int total, int maxId})> getComments(
    String id, {
    required String authorUid,
    int maxId = 0,
  }) async {
    commentMaxIds.add(maxId);
    if (maxId == 0) {
      return (
        comments: [
          for (var i = 0; i < 10; i++) _comment('p1-$i', '第一页评论 $i'),
        ],
        total: 15,
        maxId: 777,
      );
    }
    return (
      comments: [
        for (var i = 0; i < 5; i++) _comment('p2-$i', '第二页评论 $i'),
      ],
      total: 15,
      maxId: 0,
    );
  }

  @override
  Future<({List<WbStatus> items, int total, int maxPage})> getReposts(
    String id, {
    int page = 1,
  }) async {
    repostPages.add(page);
    return (
      items: [
        for (var i = 0; i < 6; i++)
          makeStatus(id: 'rp$page-$i', text: '转发第 $page 页第 $i 条'),
      ],
      total: 12,
      maxPage: 2,
    );
  }
}

/// 在页签区域（TabBarView 中心）做竖向拖动：手势落在当前页签的
/// 内层列表上，由 NestedScrollView 在内外层之间接力。
Future<void> _dragOnTabs(WidgetTester tester, double dy) async {
  await tester.dragFrom(
    tester.getCenter(find.byType(TabBarView)),
    Offset(0, dy),
  );
  await _settle(tester);
}

void main() {
  testWidgets('DetailScreen 单栏：上滑后页签栏吸顶且保持钉住', (tester) async {
    await mockNetworkImagesFor(() async {
      _usePhoneView(tester);
      final status = makeStatus(id: '9', text: '详情页原文', comments: 15);
      await tester.pumpWidget(wrapWithProviders(
        DetailScreen(status: status),
        weibo: _PagedDetailFakeService(),
      ));
      await _settle(tester);

      final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
      double tabTop() => tester.getTopLeft(find.byType(TabBar)).dy;
      // 初始：页签栏在正文卡下方，未吸顶
      expect(tabTop(), greaterThan(appBarBottom + 40));

      // 上滑一截：详情区收起，页签栏到达顶部
      await _dragOnTabs(tester, -500);
      expect(
        (tabTop() - appBarBottom).abs(),
        lessThan(1.5),
        reason: '页签栏应钉在 AppBar 正下方',
      );

      // 继续上滑：页签栏位置不变（仍钉住），列表内容继续滚动
      await _dragOnTabs(tester, -500);
      expect((tabTop() - appBarBottom).abs(), lessThan(1.5));
      expect(
        find.textContaining('第一页评论 9', findRichText: true),
        findsOneWidget,
        reason: '吸顶后内层评论列表应继续滚动到靠后条目',
      );
    });
  });

  testWidgets('DetailScreen 单栏：页签列表深滚后下拉能回到详情区', (tester) async {
    await mockNetworkImagesFor(() async {
      _usePhoneView(tester);
      final status = makeStatus(id: '9', text: '详情页原文', comments: 15);
      await tester.pumpWidget(wrapWithProviders(
        DetailScreen(status: status),
        weibo: _PagedDetailFakeService(),
      ));
      await _settle(tester);
      final detailText =
          find.textContaining('详情全文内容', findRichText: true);
      expect(detailText, findsOneWidget);

      // 深滚到评论区底部：详情卡滚出可视区（含缓存）之外
      for (var i = 0; i < 4; i++) {
        await _dragOnTabs(tester, -600);
      }
      expect(detailText, findsNothing, reason: '深滚后详情区应已滚出');

      // 反向下拉：内层到顶后外层接力，详情区重新展开露出
      for (var i = 0; i < 4; i++) {
        await _dragOnTabs(tester, 600);
      }
      expect(detailText, findsOneWidget, reason: '下拉应能回到帖子详情信息');
      final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
      expect(
        tester.getTopLeft(find.byType(TabBar)).dy,
        greaterThan(appBarBottom + 40),
        reason: '回到顶部后页签栏应回到正文下方（表头已展开）',
      );
    });
  });

  testWidgets('DetailScreen 单栏：滚动到底自动续拉，切页签后仍可续拉',
      (tester) async {
    await mockNetworkImagesFor(() async {
      _usePhoneView(tester);
      final fake = _PagedDetailFakeService();
      final status = makeStatus(id: '9', text: '详情页原文', comments: 15);
      await tester.pumpWidget(wrapWithProviders(
        DetailScreen(status: status),
        weibo: fake,
        session: FakeSessionService(loggedIn: true),
      ));
      await _settle(tester);
      // 评论只拉了第一页
      expect(fake.commentMaxIds, [0]);

      // 评论列表滚到底：自动以游标 777 续拉第二页（无需点按钮）
      for (var i = 0; i < 5; i++) {
        await _dragOnTabs(tester, -500);
      }
      expect(fake.commentMaxIds, [0, 777]);
      expect(
        find.textContaining('第二页评论 0', findRichText: true),
        findsOneWidget,
      );

      // 切到转发页签：首拉第 1 页，滚到底自动续拉第 2 页
      await tester.tap(find.textContaining('转发'));
      await _settle(tester);
      expect(fake.repostPages, [1]);
      for (var i = 0; i < 5; i++) {
        await _dragOnTabs(tester, -500);
      }
      expect(fake.repostPages, [1, 2]);
      expect(
        find.textContaining('转发第 2 页第 0 条', findRichText: true),
        findsOneWidget,
      );
    });
  });
}
