import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/home_screen.dart';
import 'package:weiyue/screens/video_tab_screen.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 可计数的假热门流（与 feed_keepalive_test 同口径）：按频道标题记录
/// 每次 getHotTimeline 的 freshIdx；首屏每拉一次版本号 +1，
/// 便于断言刷新确实重拉且换了新数据。
class CountingFeedService extends FakeWeiyueService {
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
    return HotPage(statuses: const [], maxId: 200, freshIdx: freshIdx);
  }
}

Finder _richText(String needle) =>
    find.textContaining(needle, findRichText: true);

void main() {
  testWidgets('首页宽屏：刷新按钮只重拉当前分类，其余分类缓存不受影响', (tester) async {
    await mockNetworkImagesFor(() async {
      _setSize(tester, const Size(1500, 900));
      final fake = CountingFeedService()..withVideo = false;
      await tester.pumpWidget(
        wrapWithProviders(const HomeScreen(), weibo: fake),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('home-refresh-button')), findsOneWidget);
      expect(fake.callsOf('热门'), [1]);

      // 点刷新：当前分类（热门）首屏再拉一次，数据换新版
      await tester.tap(find.byKey(const ValueKey('home-refresh-button')));
      await _settle(tester);
      expect(fake.callsOf('热门'), [1, 1]);
      expect(_richText('热门首屏第2版条目0'), findsOneWidget);

      // 切到社会加载一次，再点刷新：只刷社会，热门不再动
      await tester.tap(find.text('社会'));
      await _settle(tester);
      expect(fake.callsOf('社会'), [1]);
      await tester.tap(find.byKey(const ValueKey('home-refresh-button')));
      await _settle(tester);
      expect(fake.callsOf('社会'), [1, 1]);
      expect(fake.callsOf('热门'), [1, 1]);

      // 切回热门：仍是刷新后的第 2 版缓存，不发新请求
      await tester.tap(find.text('热门'));
      await _settle(tester);
      expect(fake.callsOf('热门'), [1, 1]);
      expect(_richText('热门首屏第2版条目0'), findsOneWidget);
    });
  });

  testWidgets('首页窄屏：不显示刷新按钮（继续下拉刷新）', (tester) async {
    await mockNetworkImagesFor(() async {
      _setSize(tester, const Size(420, 900));
      final fake = CountingFeedService()..withVideo = false;
      await tester.pumpWidget(
        wrapWithProviders(const HomeScreen(), weibo: fake),
      );
      await _settle(tester);
      expect(fake.callsOf('热门'), [1]);
      expect(find.byKey(const ValueKey('home-refresh-button')), findsNothing);
    });
  });

  testWidgets('视频页宽屏：刷新按钮只重拉当前分类', (tester) async {
    await mockNetworkImagesFor(() async {
      _setSize(tester, const Size(1500, 900));
      final fake = CountingFeedService();
      await tester.pumpWidget(
        wrapWithProviders(const VideoTabScreen(), weibo: fake),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('video-refresh-button')), findsOneWidget);
      expect(fake.callsOf('推荐'), [1]);

      // 点刷新：推荐首屏再拉一次，数据换新版
      await tester.tap(find.byKey(const ValueKey('video-refresh-button')));
      await _settle(tester);
      expect(fake.callsOf('推荐'), [1, 1]);
      expect(_richText('推荐首屏第2版条目0'), findsOneWidget);

      // 切到电影加载一次，再点刷新：只刷电影，推荐不再动
      await tester.tap(find.text('电影'));
      await _settle(tester);
      expect(fake.callsOf('电影'), [1]);
      await tester.tap(find.byKey(const ValueKey('video-refresh-button')));
      await _settle(tester);
      expect(fake.callsOf('电影'), [1, 1]);
      expect(fake.callsOf('推荐'), [1, 1]);
    });
  });

  testWidgets('视频页窄屏：不显示刷新按钮（继续下拉刷新）', (tester) async {
    await mockNetworkImagesFor(() async {
      _setSize(tester, const Size(420, 900));
      final fake = CountingFeedService();
      await tester.pumpWidget(
        wrapWithProviders(const VideoTabScreen(), weibo: fake),
      );
      await _settle(tester);
      expect(fake.callsOf('推荐'), [1]);
      expect(find.byKey(const ValueKey('video-refresh-button')), findsNothing);
    });
  });
}
