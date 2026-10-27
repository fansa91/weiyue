import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/core/scroll_signal.dart';
import 'package:weiyue/main.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/screens/discover_screen.dart';
import 'package:weiyue/screens/home_screen.dart';
import 'package:weiyue/screens/me_screen.dart';
import 'package:weiyue/screens/profile_screen.dart';
import 'package:weiyue/screens/settings_screen.dart';
import 'package:weiyue/services/settings_service.dart';
import 'package:weiyue/widgets/hot_feed_view.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// 切到桌面宽屏尺寸（逻辑像素），测试结束自动恢复。
void _useWideView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

const _hotChannel =
    WbChannel(gid: '102803', title: '热门', containerid: '102803');

void main() {
  testWidgets('HomeScreen：分类 chips 与 feed 列表渲染', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(wrapWithProviders(const HomeScreen()));
      await _settle(tester);
      // 分类 chips（HotFeedView 频道条之外的 Home 分类 chips）
      expect(find.text('热门'), findsWidgets);
      expect(find.text('社会'), findsWidgets);
      expect(find.text('科技'), findsWidgets);
      // feed 条目
      expect(find.textContaining('热门第一条', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('热门第二条带图', findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('HomeScreen：feed 失败显示错误与重试', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakeWeiyueService()..failFeed = true;
      await tester.pumpWidget(
          wrapWithProviders(const HomeScreen(), weibo: fake));
      await _settle(tester);
      expect(find.textContaining('网络错误'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  testWidgets('HomeScreen：feed 为空显示空态', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakeWeiyueService()..feedItems = [];
      await tester.pumpWidget(
          wrapWithProviders(const HomeScreen(), weibo: fake));
      await _settle(tester);
      expect(find.text('暂无内容'), findsOneWidget);
    });
  });

  testWidgets('DetailScreen：评论 1/122 时出现访客热评横幅', (tester) async {
    await mockNetworkImagesFor(() async {
      final status = makeStatus(id: '9', text: '详情页原文', comments: 122);
      await tester.pumpWidget(wrapWithProviders(DetailScreen(status: status)));
      await _settle(tester);
      expect(find.textContaining('访客仅显示热评'), findsOneWidget);
      expect(find.textContaining('122'), findsWidgets);
      expect(find.textContaining('这是一条热评', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('转发列表访客不可见'), findsNothing);
    });
  });

  testWidgets('DetailScreen 宽屏：左右双栏，评论面板在右侧', (tester) async {
    await mockNetworkImagesFor(() async {
      _useWideView(tester, const Size(1600, 900));
      final status = makeStatus(id: '9', text: '详情页原文', comments: 122);
      await tester.pumpWidget(wrapWithProviders(DetailScreen(status: status)));
      await _settle(tester);
      // 正文与评论（横幅+热评）在双栏下同时可见
      final body = find.textContaining('详情全文内容', findRichText: true);
      final comment = find.textContaining('这是一条热评', findRichText: true);
      expect(body, findsOneWidget);
      expect(find.textContaining('访客仅显示热评'), findsOneWidget);
      expect(comment, findsOneWidget);
      // 评论面板在正文右侧
      expect(tester.getCenter(comment).dx,
          greaterThan(tester.getCenter(body).dx));
    });
  });

  testWidgets('DetailScreen：评论排序切换改变列表顺序', (tester) async {
    await mockNetworkImagesFor(() async {
      final status = makeStatus(id: '9', text: '详情页原文', comments: 3);
      await tester.pumpWidget(wrapWithProviders(
        DetailScreen(status: status),
        weibo: _SortableFakeService(),
      ));
      await _settle(tester);
      double dyOf(String text) => tester.getTopLeft(find.text(text)).dy;
      // 排序控件定位：按钮本体 + 以 PopupMenuItem 为祖先的菜单项文本
      //（避免与排序栏当前值标签同名冲突）
      final sortToggle =
          find.byWidgetPredicate((w) => w is PopupMenuButton);
      Finder menuItem(String label) => find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
          );
      // 默认（服务端顺序）：甲 15:00 → 乙 10:00 → 丙 12:00
      expect(dyOf('评论甲最新'), lessThan(dyOf('评论乙最早高赞')));
      expect(dyOf('评论乙最早高赞'), lessThan(dyOf('评论丙中间')));
      // 切「最早」（时间正序）：乙 → 丙 → 甲，首尾互换
      await tester.tap(sortToggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(menuItem('最早'));
      await _settle(tester);
      expect(dyOf('评论乙最早高赞'), lessThan(dyOf('评论丙中间')));
      expect(dyOf('评论丙中间'), lessThan(dyOf('评论甲最新')));
      // 切「最多点赞」：乙（50 赞）置顶，其次甲（5）、丙（1）
      await tester.tap(sortToggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(menuItem('最多点赞'));
      await _settle(tester);
      expect(dyOf('评论乙最早高赞'), lessThan(dyOf('评论甲最新')));
      expect(dyOf('评论甲最新'), lessThan(dyOf('评论丙中间')));
    });
  });

  testWidgets('HotFeedView 宽屏：瀑布流多列', (tester) async {
    await mockNetworkImagesFor(() async {
      _useWideView(tester, const Size(1600, 900));
      await tester.pumpWidget(
          wrapWithProviders(const HotFeedView(channel: _hotChannel)));
      await _settle(tester);
      expect(find.byType(SliverMasonryGrid), findsOneWidget);
      final first = find.textContaining('热门第一条', findRichText: true);
      final second = find.textContaining('热门第二条带图', findRichText: true);
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      // 第二张卡落在另一列：横坐标与第一张不同
      expect(tester.getTopLeft(second).dx,
          isNot(equals(tester.getTopLeft(first).dx)));
    });
  });

  testWidgets('HotFeedView 窄屏：保持单列列表', (tester) async {
    await mockNetworkImagesFor(() async {
      // 默认测试视口 800x600 < 900，走单列 ListView
      await tester.pumpWidget(
          wrapWithProviders(const HotFeedView(channel: _hotChannel)));
      await _settle(tester);
      expect(find.byType(SliverMasonryGrid), findsNothing);
      final first = find.textContaining('热门第一条', findRichText: true);
      final second = find.textContaining('热门第二条带图', findRichText: true);
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      // 单列：两卡横坐标一致，第二张在第一张下方
      expect(tester.getTopLeft(second).dx,
          equals(tester.getTopLeft(first).dx));
      expect(tester.getTopLeft(second).dy,
          greaterThan(tester.getTopLeft(first).dy));
    });
  });

  testWidgets('DiscoverScreen：热搜榜名次与热度渲染', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(wrapWithProviders(const DiscoverScreen()));
      await _settle(tester);
      expect(find.text('热搜第一条'), findsOneWidget);
      expect(find.text('1146.0万'), findsOneWidget); // 11459803/1e4 四舍五入
      expect(find.text('爆'), findsWidgets);
      expect(find.text('#置顶话题#'), findsOneWidget);
      // band 六分类入口
      for (final label in ['娱乐', '生活', '社会', '科技', '体育', '动漫']) {
        expect(find.text(label), findsWidgets, reason: '分类 $label');
      }
    });
  });

  testWidgets('ProfileScreen：头部昵称/三计数与三页签', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester
          .pumpWidget(wrapWithProviders(const ProfileScreen(uid: '42')));
      await _settle(tester);
      expect(find.text('测试博主'), findsWidgets);
      expect(find.text('1.2万'), findsOneWidget); // 粉丝 12345
      expect(find.text('100'), findsOneWidget); // 关注
      expect(find.text('999'), findsOneWidget); // 动态数
      expect(find.text('动态'), findsWidgets);
      expect(find.text('视频'), findsWidgets);
      expect(find.text('相册'), findsWidgets);
      expect(find.textContaining('主页微博一', findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('MeScreen：有 SUB 显示已就绪', (tester) async {
    await tester.pumpWidget(wrapWithProviders(const MeScreen(),
        visitor: FakeVisitorService(has: true)));
    await _settle(tester);
    expect(find.textContaining('已就绪'), findsNWidgets(2));
    expect(find.text('刷新访客身份'), findsOneWidget);
    expect(find.text('访客模式说明'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('主题与外观'), findsOneWidget);
  });

  testWidgets('SettingsScreen：仅设置项+视频自动播放开关，无关于/访客说明',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await tester.runAsync(() async {
      final s = SettingsService();
      await s.init();
      return s;
    });
    await tester.pumpWidget(
        wrapWithProviders(const SettingsScreen(), settings: settings));
    await _settle(tester);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('视频自动播放'), findsOneWidget);
    expect(find.text('关于微阅'), findsNothing);
    expect(find.text('访客模式说明'), findsNothing);
    // 开关可切换并落到 SettingsService
    expect(settings!.videoAutoplay, isTrue);
    await tester.tap(find.byType(Switch));
    await _settle(tester);
    expect(settings.videoAutoplay, isFalse);
  });

  testWidgets('DetailScreen：相关视频在第四页签内，不再夹在正文与页签之间',
      (tester) async {
    await mockNetworkImagesFor(() async {
      final status = makeStatus(id: '9', text: '视频帖', video: true);
      await tester.pumpWidget(wrapWithProviders(
        DetailScreen(status: status),
        weibo: _RelatedFakeService(),
      ));
      await _settle(tester);
      // 视频区域较高，页签栏在首屏下方，先滚动外层列表使其构建出来
      await tester.drag(find.byType(ListView).first, const Offset(0, -350));
      await _settle(tester);
      // 页签栏有「相关视频」，且列表内容默认不在正文下方直接露出
      expect(find.text('相关视频'), findsOneWidget);
      expect(find.textContaining('相关视频条目一', findRichText: true),
          findsNothing);
      // 切到相关视频页签后条目可见
      await tester.tap(find.text('相关视频'));
      await _settle(tester);
      expect(find.textContaining('相关视频条目一', findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('DetailScreen：无相关视频时页签显示占位', (tester) async {
    await mockNetworkImagesFor(() async {
      final status = makeStatus(id: '9', text: '视频帖', video: true);
      await tester.pumpWidget(wrapWithProviders(
        DetailScreen(status: status),
        weibo: _NoRelatedFakeService(),
      ));
      await _settle(tester);
      await tester.drag(find.byType(ListView).first, const Offset(0, -350));
      await _settle(tester);
      await tester.tap(find.text('相关视频'));
      await _settle(tester);
      expect(find.text('暂无相关视频'), findsOneWidget);
    });
  });

  testWidgets('HotFeedView：首页回顶信号让已滚动的列表平滑回顶', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakeWeiyueService()
        ..feedItems = [
          for (var i = 0; i < 12; i++)
            makeStatus(id: 't$i', text: '回顶测试第 $i 条'),
        ];
      await tester.pumpWidget(wrapWithProviders(
        const HotFeedView(channel: _hotChannel, homeTopSignalEnabled: true),
        weibo: fake,
      ));
      await _settle(tester);
      final scrollable = find
          .descendant(
              of: find.byType(HotFeedView), matching: find.byType(Scrollable))
          .first;
      double pixels() =>
          tester.state<ScrollableState>(scrollable).position.pixels;
      expect(pixels(), 0);
      // 向下滚动一段
      await tester.drag(find.byType(HotFeedView), const Offset(0, -400));
      await tester.pump();
      expect(pixels(), greaterThan(0));
      // 发回顶信号 → 动画回顶
      homeTopSignal.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(pixels(), 0);
    });
  });

  testWidgets('MeScreen：无 SUB 显示未获取', (tester) async {
    await tester.pumpWidget(wrapWithProviders(const MeScreen(),
        visitor: FakeVisitorService(has: false)));
    await _settle(tester);
    expect(find.text('未获取'), findsNWidgets(2));
    expect(find.textContaining('已就绪'), findsNothing);
  });

  testWidgets('AppShell：底部四栏切换', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(wrapWithProviders(const AppShell()));
      await _settle(tester);
      final navBar = find.byType(NavigationBar);
      expect(navBar, findsOneWidget);
      for (final label in ['首页', '视频', '发现', '我的']) {
        expect(
            find.descendant(of: navBar, matching: find.text(label)),
            findsOneWidget,
            reason: '导航 $label');
      }
      // 切到发现
      await tester.tap(
          find.descendant(of: navBar, matching: find.text('发现')));
      await _settle(tester);
      expect(find.text('热搜第一条'), findsOneWidget);
      // 切到我的
      await tester.tap(
          find.descendant(of: navBar, matching: find.text('我的')));
      await _settle(tester);
      expect(find.text('刷新访客身份'), findsOneWidget);
    });
  });
}

/// 相关视频页签测试专用假服务：详情刷新返回带视频的帖
/// （保证 _status.hasVideo 触发相关视频加载），且有一条相关视频。
class _RelatedFakeService extends FakeWeiyueService {
  @override
  Future<WbStatus> getStatus(String id) async => makeStatus(
      id: id, text: '详情全文内容', comments: 122, attitudes: 881, video: true);

  @override
  Future<List<WbStatus>> getRelatedVideos(String mid, {int page = 1}) async =>
      [makeStatus(id: 'r1', text: '相关视频条目一', video: true)];
}

/// 无相关视频版：其余同上，相关视频走父类默认空列表。
class _NoRelatedFakeService extends FakeWeiyueService {
  @override
  Future<WbStatus> getStatus(String id) async => makeStatus(
      id: id, text: '详情全文内容', comments: 122, attitudes: 881, video: true);
}

/// 评论排序测试专用假服务：3 条评论，时间/点赞各不相同，
/// 服务端返回顺序为 甲（最新）→ 乙（最早、高赞）→ 丙（中间）。
class _SortableFakeService extends FakeWeiyueService {
  @override
  Future<({List<WbComment> comments, int total, int maxId})> getComments(
      String id,
      {required String authorUid,
      int maxId = 0}) async {
    WbComment c(String id, String text, String time, int likes) => WbComment(
          id: id,
          user: makeStatus().user,
          text: text,
          createdAtRaw: time,
          likeCount: likes,
        );
    return (
      comments: [
        c('a', '评论甲最新', 'Mon Oct 26 15:00:00 +0800 2026', 5),
        c('b', '评论乙最早高赞', 'Mon Oct 26 10:00:00 +0800 2026', 50),
        c('c', '评论丙中间', 'Mon Oct 26 12:00:00 +0800 2026', 1),
      ],
      total: 3,
      maxId: 0,
    );
  }
}
