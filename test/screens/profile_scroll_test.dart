import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/profile_screen.dart';

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

/// 动态/文章页签各两页数据（第一页 10 条、第二页 5 条、第三页空
/// 结束），记录各自分页请求页码。
class _PagedProfileFakeService extends FakeWeiyueService {
  final List<int> statusPages = [];
  final List<int> articlePages = [];

  @override
  Future<ContainerPage> getUserStatuses(String uid, {int page = 1}) async {
    statusPages.add(page);
    if (page == 1) {
      return ContainerPage(
        statuses: [
          for (var i = 0; i < 10; i++)
            makeStatus(id: 's1-$i', text: '主页动态第一页 $i'),
        ],
        total: 15,
        nextPage: 2,
      );
    }
    if (page == 2) {
      return ContainerPage(
        statuses: [
          for (var i = 0; i < 5; i++)
            makeStatus(id: 's2-$i', text: '主页动态第二页 $i'),
        ],
        total: 15,
        nextPage: 3,
      );
    }
    return ContainerPage(statuses: const [], total: 15, nextPage: 3);
  }

  @override
  Future<ContainerPage> getUserArticles(String uid, {int page = 1}) async {
    articlePages.add(page);
    if (page == 1) {
      return ContainerPage(
        statuses: [
          for (var i = 0; i < 10; i++)
            makeStatus(id: 'a1-$i', text: '主页文章第一页 $i'),
        ],
        total: 15,
        nextPage: 2,
      );
    }
    if (page == 2) {
      return ContainerPage(
        statuses: [
          for (var i = 0; i < 5; i++)
            makeStatus(id: 'a2-$i', text: '主页文章第二页 $i'),
        ],
        total: 15,
        nextPage: 3,
      );
    }
    return ContainerPage(statuses: const [], total: 15, nextPage: 3);
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
  testWidgets('ProfileScreen 单栏：上滑后页签栏吸顶且保持钉住', (tester) async {
    await mockNetworkImagesFor(() async {
      _usePhoneView(tester);
      await tester.pumpWidget(wrapWithProviders(
        const ProfileScreen(uid: '42'),
        weibo: _PagedProfileFakeService(),
      ));
      await _settle(tester);

      final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
      double tabTop() => tester.getTopLeft(find.byType(TabBar)).dy;
      // 初始：页签栏在资料头下方，未吸顶
      expect(tabTop(), greaterThan(appBarBottom + 40));

      // 上滑一截：资料头收起，页签栏到达顶部
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
        find.textContaining('主页动态第一页 9', findRichText: true),
        findsOneWidget,
        reason: '吸顶后内层列表应继续滚动到靠后条目',
      );
    });
  });

  testWidgets('ProfileScreen 单栏：页签列表深滚后下拉能回到资料头', (tester) async {
    await mockNetworkImagesFor(() async {
      _usePhoneView(tester);
      await tester.pumpWidget(wrapWithProviders(
        const ProfileScreen(uid: '42'),
        weibo: _PagedProfileFakeService(),
      ));
      await _settle(tester);
      expect(find.text('测试博主'), findsWidgets);

      // 深滚：资料头滚走
      for (var i = 0; i < 4; i++) {
        await _dragOnTabs(tester, -600);
      }
      // 反向下拉：内层到顶后外层接力，资料头重新展开露出
      for (var i = 0; i < 4; i++) {
        await _dragOnTabs(tester, 600);
      }
      expect(find.text('测试博主'), findsWidgets, reason: '下拉应能回到资料头');
      final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
      expect(
        tester.getTopLeft(find.byType(TabBar)).dy,
        greaterThan(appBarBottom + 40),
        reason: '回到顶部后页签栏应回到资料头下方（表头已展开）',
      );
    });
  });

  testWidgets('ProfileScreen 单栏：滚动到底自动续拉下一页', (tester) async {
    await mockNetworkImagesFor(() async {
      _usePhoneView(tester);
      final fake = _PagedProfileFakeService();
      await tester.pumpWidget(wrapWithProviders(
        const ProfileScreen(uid: '42'),
        weibo: fake,
      ));
      await _settle(tester);
      expect(fake.statusPages, [1]);

      for (var i = 0; i < 6; i++) {
        await _dragOnTabs(tester, -500);
      }
      expect(fake.statusPages, contains(2), reason: '滚到底应续拉第二页');
      expect(
        find.textContaining('主页动态第二页 0', findRichText: true),
        findsOneWidget,
      );
    });
  });

  testWidgets('ProfileScreen 单栏：切页签后仍可续拉且原页签状态保留',
      (tester) async {
    await mockNetworkImagesFor(() async {
      _usePhoneView(tester);
      final fake = _PagedProfileFakeService();
      await tester.pumpWidget(wrapWithProviders(
        const ProfileScreen(uid: '42'),
        weibo: fake,
      ));
      await _settle(tester);

      // 动态页签先续拉出第二页
      for (var i = 0; i < 6; i++) {
        await _dragOnTabs(tester, -500);
      }
      expect(fake.statusPages, contains(2));

      // 切到文章页签：首拉第一页，滚到底续拉第二页
      await tester.tap(find.text('文章'));
      await _settle(tester);
      expect(fake.articlePages, [1]);
      for (var i = 0; i < 6; i++) {
        await _dragOnTabs(tester, -500);
      }
      expect(fake.articlePages, contains(2));
      expect(
        find.textContaining('主页文章第二页 0', findRichText: true),
        findsOneWidget,
      );

      // 切回动态页签：状态保留（不重拉第一页），第二页条目仍在
      final statusCalls = List.of(fake.statusPages);
      await tester.tap(find.text('动态'));
      await _settle(tester);
      expect(fake.statusPages, statusCalls, reason: '切回不应重新请求');
      await _dragOnTabs(tester, -300);
      expect(
        find.textContaining('主页动态第二页 0', findRichText: true),
        findsWidgets,
        reason: '切回后已加载的第二页条目应保留',
      );
    });
  });
}
