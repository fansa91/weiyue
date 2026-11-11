import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/home_screen.dart';
import 'package:weiyue/screens/video_tab_screen.dart';
import 'package:weiyue/widgets/hot_feed_view.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// 可计数的假热门流：按频道标题记录每次 getHotTimeline 的 freshIdx；
/// 首屏（freshIdx==1）每拉一次「版本号」+1（便于断言刷新换了新数据），
/// 第 2 页固定内容，第 3 页起为空（到底）。每页 10 条带视频的帖子
/// （视频页过滤也能过），保证列表可滚动。
class CountingFeedService extends FakeWeiyueService {
  /// 条目是否带视频：视频页过滤需要 true；首页测试用 false，
  /// 否则每张卡带 16:9 封面高 500+px，视口只能放一张、拖不到底。
  bool withVideo = true;

  final Map<String, List<int>> callsByTitle = {};
  final Map<String, int> _firstPageVersions = {};

  List<int> callsOf(String title) => callsByTitle[title] ?? const [];

  @override
  Future<HotPage> getHotTimeline(
    WbChannel channel, {
    int maxId = 0,
    int freshIdx = 1,
  }) async {
    callsByTitle.putIfAbsent(channel.title, () => []).add(freshIdx);
    final tag = channel.title;
    if (freshIdx <= 1) {
      final v = (_firstPageVersions[channel.title] =
          (_firstPageVersions[channel.title] ?? 0) + 1);
      return HotPage(
        statuses: [
          for (var i = 0; i < 10; i++)
            makeStatus(
              id: '${channel.gid}-p1-v$v-$i',
              text: '$tag首屏第$v版条目$i',
              video: withVideo,
            ),
        ],
        maxId: 100,
        freshIdx: freshIdx,
      );
    }
    if (freshIdx == 2) {
      return HotPage(
        statuses: [
          for (var i = 0; i < 10; i++)
            makeStatus(
              id: '${channel.gid}-p2-$i',
              text: '$tag第二页条目$i',
              video: withVideo,
            ),
        ],
        maxId: 200,
        freshIdx: freshIdx,
      );
    }
    return HotPage(statuses: const [], maxId: 200, freshIdx: freshIdx);
  }
}

Finder _feedList(String hotFeedKey) => find.descendant(
  of: find.byKey(ValueKey(hotFeedKey)),
  matching: find.byType(ListView),
);

Finder _richText(String needle) =>
    find.textContaining(needle, findRichText: true);

/// 在指定 feed 列表上做下拉刷新手势（从一条可见条目上起手往下拖）。
Future<void> _pullToRefresh(WidgetTester tester, Finder onItem) async {
  final gesture = await tester.startGesture(tester.getCenter(onItem));
  await gesture.moveBy(const Offset(0, 120));
  await gesture.moveBy(const Offset(0, 220));
  await tester.pump();
  await gesture.up();
  await _settle(tester);
}

void main() {
  testWidgets('首页：分类切换不重新请求，切回原分类内容还在', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = CountingFeedService()..withVideo = false;
      await tester.pumpWidget(
        wrapWithProviders(const HomeScreen(), weibo: fake),
      );
      await _settle(tester);

      // 初始分类（热门）只加载一次
      expect(fake.callsOf('热门'), [1]);
      expect(_richText('热门首屏第1版条目0'), findsOneWidget);

      // 切到社会：社会首次加载一次
      await tester.tap(find.text('社会'));
      await _settle(tester);
      expect(fake.callsOf('社会'), [1]);
      expect(_richText('社会首屏第1版条目0'), findsOneWidget);

      // 切回热门：不再请求，原列表还在
      await tester.tap(find.text('热门'));
      await _settle(tester);
      expect(fake.callsOf('热门'), [1]);
      expect(_richText('热门首屏第1版条目0'), findsOneWidget);
      expect(_richText('热门首屏第1版条目1'), findsOneWidget);

      // 科技同理，来回切不重复请求
      await tester.tap(find.text('科技'));
      await _settle(tester);
      expect(fake.callsOf('科技'), [1]);
      await tester.tap(find.text('社会'));
      await _settle(tester);
      expect(fake.callsOf('社会'), [1]);
      expect(_richText('社会首屏第1版条目0'), findsOneWidget);
    });
  });

  testWidgets('首页：下拉刷新只刷新当前分类且换新数据，其余分类缓存不受影响', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      final fake = CountingFeedService()..withVideo = false;
      await tester.pumpWidget(
        wrapWithProviders(const HomeScreen(), weibo: fake),
      );
      await _settle(tester);
      expect(fake.callsOf('热门'), [1]);

      // 先去社会加载一次，形成缓存
      await tester.tap(find.text('社会'));
      await _settle(tester);
      expect(fake.callsOf('社会'), [1]);
      await tester.tap(find.text('热门'));
      await _settle(tester);

      // 在热门上下拉刷新：热门首屏再拉一次（freshIdx 仍为 1），数据换新版
      await _pullToRefresh(tester, _richText('热门首屏第1版条目0'));
      expect(fake.callsOf('热门'), [1, 1]);
      expect(_richText('热门首屏第2版条目0'), findsOneWidget);
      expect(_richText('热门首屏第1版条目0'), findsNothing);

      // 社会没有被连带刷新，切过去仍是缓存的首版数据且不发新请求
      expect(fake.callsOf('社会'), [1]);
      await tester.tap(find.text('社会'));
      await _settle(tester);
      expect(fake.callsOf('社会'), [1]);
      expect(_richText('社会首屏第1版条目0'), findsOneWidget);

      // 切回热门：显示刷新后的第 2 版，不再请求
      await tester.tap(find.text('热门'));
      await _settle(tester);
      expect(fake.callsOf('热门'), [1, 1]);
      expect(_richText('热门首屏第2版条目0'), findsOneWidget);
    });
  });

  testWidgets('首页：切走再切回，分页从已加载页数继续（freshIdx 不回退）', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = CountingFeedService()..withVideo = false;
      await tester.pumpWidget(
        wrapWithProviders(const HomeScreen(), weibo: fake),
      );
      await _settle(tester);
      expect(fake.callsOf('热门'), [1]);

      // 滚到底触发第二页
      await tester.drag(
        _feedList('102803_102803'),
        const Offset(0, -2400),
      );
      await _settle(tester);
      expect(fake.callsOf('热门'), [1, 2]);
      expect(_richText('热门第二页条目0'), findsWidgets);

      // 切到社会再切回：不重拉，分页进度保留
      await tester.tap(find.text('社会'));
      await _settle(tester);
      await tester.tap(find.text('热门'));
      await _settle(tester);
      expect(fake.callsOf('热门'), [1, 2]);

      // 再滚到底：下一次请求必须是 freshIdx=3（从已加载页数继续）
      await tester.fling(
        _feedList('102803_102803'),
        const Offset(0, -800),
        1600,
      );
      await _settle(tester);
      await tester.fling(
        _feedList('102803_102803'),
        const Offset(0, -800),
        1600,
      );
      await _settle(tester);
      expect(fake.callsOf('热门'), [1, 2, 3]);
    });
  });

  testWidgets('视频页：分类切换不重新请求，下拉刷新只刷新当前分类', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = CountingFeedService();
      await tester.pumpWidget(
        wrapWithProviders(const VideoTabScreen(), weibo: fake),
      );
      await _settle(tester);

      // 推荐首次加载一次
      expect(fake.callsOf('推荐'), [1]);
      expect(_richText('推荐首屏第1版条目0'), findsOneWidget);

      // 切到电影：首次加载一次
      await tester.tap(find.text('电影'));
      await _settle(tester);
      expect(fake.callsOf('电影'), [1]);
      expect(_richText('电影首屏第1版条目0'), findsOneWidget);

      // 切回推荐：不请求，原内容还在
      await tester.tap(find.text('推荐'));
      await _settle(tester);
      expect(fake.callsOf('推荐'), [1]);
      expect(_richText('推荐首屏第1版条目0'), findsOneWidget);

      // 下拉刷新推荐：只多一次首屏请求，数据换新版；电影不受影响
      await _pullToRefresh(tester, _richText('推荐首屏第1版条目0'));
      expect(fake.callsOf('推荐'), [1, 1]);
      expect(_richText('推荐首屏第2版条目0'), findsOneWidget);
      expect(fake.callsOf('电影'), [1]);

      await tester.tap(find.text('电影'));
      await _settle(tester);
      expect(fake.callsOf('电影'), [1]);
      expect(_richText('电影首屏第1版条目0'), findsOneWidget);
    });
  });

  testWidgets('首页：已保活分类在 IndexedStack 中只有一个可见实例', (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = CountingFeedService()..withVideo = false;
      await tester.pumpWidget(
        wrapWithProviders(const HomeScreen(), weibo: fake),
      );
      await _settle(tester);
      await tester.tap(find.text('社会'));
      await _settle(tester);
      await tester.tap(find.text('热门'));
      await _settle(tester);
      // 两个分类的 HotFeedView 都已创建保活
      expect(find.byType(HotFeedView), findsWidgets);
      expect(
        tester
            .widgetList(find.byType(HotFeedView))
            .where((w) => (w as HotFeedView).channel.title == '热门')
            .length,
        1,
      );
    });
  });
}
