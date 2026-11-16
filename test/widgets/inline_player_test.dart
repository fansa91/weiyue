import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/services/settings_service.dart';
import 'package:weiyue/widgets/inline_player.dart';
import 'package:weiyue/widgets/network_image.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// 假播放后端：不触碰 media_kit 原生库，只记录调用并渲染占位面。
class FakePlayback implements InlinePlayback {
  int openCalls = 0;
  String? lastUrl;
  int playCalls = 0;
  int pauseCalls = 0;
  bool disposed = false;
  final _width = StreamController<int?>.broadcast();
  final _height = StreamController<int?>.broadcast();
  final _playing = StreamController<bool>.broadcast();

  @override
  Stream<int?> get widthStream => _width.stream;

  @override
  Stream<int?> get heightStream => _height.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Future<void> open(String url) async {
    openCalls++;
    lastUrl = url;
    // 模拟 media_kit 开播即播放
    _playing.add(true);
  }

  @override
  Future<void> play() async {
    playCalls++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing.add(false);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Widget buildSurface() {
    return Container(
      color: Colors.black,
      child: const Center(child: Text('FakeSurface')),
    );
  }
}

InlinePlaybackFactory _factoryOf(FakePlayback fake) {
  return ({
    required Future<void> Function() onEnterFullscreen,
    required Future<void> Function() onExitFullscreen,
  }) =>
      fake;
}

/// 详情页集成用假服务：getStatus 返回带视频的帖（与入口帖一致，
/// 避免刷新后 _status 被换成无视频帖把内嵌播放器卸掉）。
class _VideoDetailFakeService extends FakeWeiyueService {
  @override
  Future<WbStatus> getStatus(String id) async => makeStatus(
      id: id, text: '详情全文内容', comments: 122, attitudes: 881, video: true);
}

/// 详情刷新丢媒体的假服务：getStatus 返回无视频、无图片的帖
///（模拟详情接口返回形态与列表不同、媒体字段缺失）。
class _MediaDroppingFakeService extends FakeWeiyueService {
  @override
  Future<WbStatus> getStatus(String id) async =>
      makeStatus(id: id, text: '详情全文内容（媒体缺失）');
}

void main() {
  testWidgets('InlineVideoPlayer 自动播放开：进入即开播，附加层只有画质/下载',
      (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakePlayback();
      await tester.pumpWidget(wrapWithProviders(
        InlineVideoPlayer(
          status: makeStatus(id: 'v1', video: true),
          autoplay: true,
          playbackFactory: _factoryOf(fake),
        ),
      ));
      await _settle(tester);
      // 进入即开播，默认档为 ≤720p 最高档（假数据 720p 档）
      expect(fake.openCalls, 1);
      expect(fake.lastUrl, contains('v720'));
      expect(find.text('FakeSurface'), findsOneWidget);
      // 附加层：画质按钮（假数据两档）与下载按钮在位
      expect(find.byIcon(Icons.high_quality_outlined), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      // 播放/暂停、全屏不自绘（归 media_kit 默认控制层一套）：
      // 附加层里没有暂停键、没有全屏/暂停/播放图标
      expect(find.byKey(const ValueKey('inline-player-pause')), findsNothing);
      expect(find.byIcon(Icons.fullscreen), findsNothing);
      expect(find.byIcon(Icons.pause), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });
  });

  testWidgets('InlineVideoPlayer 自动播放关：只显示封面+大播放按钮，点击才播',
      (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakePlayback();
      await tester.pumpWidget(wrapWithProviders(
        InlineVideoPlayer(
          status: makeStatus(id: 'v1', video: true),
          autoplay: false,
          playbackFactory: _factoryOf(fake),
        ),
      ));
      await _settle(tester);
      expect(fake.openCalls, 0);
      expect(find.text('FakeSurface'), findsNothing);
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      // 点击大播放按钮后才建播放器开播
      await tester.tap(find.byIcon(Icons.play_circle_fill));
      await _settle(tester);
      expect(fake.openCalls, 1);
      expect(find.text('FakeSurface'), findsOneWidget);
    });
  });

  testWidgets('InlineVideoPlayer 附加层自动隐藏：播放 3 秒后隐藏，点画面唤回，暂停时常显',
      (tester) async {
    await mockNetworkImagesFor(() async {
      final fake = FakePlayback();
      await tester.pumpWidget(wrapWithProviders(
        InlineVideoPlayer(
          status: makeStatus(id: 'v1', video: true),
          autoplay: true,
          playbackFactory: _factoryOf(fake),
        ),
      ));
      await _settle(tester);
      expect(find.byIcon(Icons.high_quality_outlined), findsOneWidget);
      // 播放中 3 秒无操作 -> 附加层隐藏
      await tester.pump(const Duration(seconds: 4));
      expect(find.byIcon(Icons.high_quality_outlined), findsNothing);
      expect(find.byIcon(Icons.download_outlined), findsNothing);
      // 点画面唤回
      await tester.tap(find.text('FakeSurface'));
      await _settle(tester);
      expect(find.byIcon(Icons.high_quality_outlined), findsOneWidget);
      // 暂停（经 media_kit 默认层操作，状态流回传）后即使 4 秒也不隐藏
      await fake.pause();
      await _settle(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byIcon(Icons.high_quality_outlined), findsOneWidget);
      // 续播后恢复自动隐藏
      await fake.play();
      await _settle(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byIcon(Icons.high_quality_outlined), findsNothing);
    });
  });

  testWidgets('DetailScreen 内嵌播放：设置关时不自动播（封面态）', (tester) async {
    SharedPreferences.setMockInitialValues({'video_autoplay': false});
    final settings = await tester.runAsync(() async {
      final s = SettingsService();
      await s.init();
      return s;
    });
    await mockNetworkImagesFor(() async {
      final fake = FakePlayback();
      await tester.pumpWidget(wrapWithProviders(
        DetailScreen(
          status: makeStatus(id: '9', text: '视频帖', video: true),
          inlinePlaybackFactory: _factoryOf(fake),
        ),
        weibo: _VideoDetailFakeService(),
        settings: settings,
      ));
      await _settle(tester);
      // 仍在详情页内（没有跳独立播放页），且未自动开播
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(fake.openCalls, 0);
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      expect(find.text('FakeSurface'), findsNothing);
    });
  });

  testWidgets('DetailScreen 内嵌播放：设置开时进入详情即自动播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await tester.runAsync(() async {
      final s = SettingsService();
      await s.init();
      return s;
    });
    await mockNetworkImagesFor(() async {
      final fake = FakePlayback();
      await tester.pumpWidget(wrapWithProviders(
        DetailScreen(
          status: makeStatus(id: '9', text: '视频帖', video: true),
          inlinePlaybackFactory: _factoryOf(fake),
        ),
        weibo: _VideoDetailFakeService(),
        settings: settings,
      ));
      await _settle(tester);
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(fake.openCalls, 1);
      expect(
        find.descendant(
          of: find.byType(DetailScreen),
          matching: find.text('FakeSurface'),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.high_quality_outlined), findsOneWidget);
    });
  });

  testWidgets('DetailScreen 刷新丢媒体：保留入口帖的视频与图片（混合帖回归）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await tester.runAsync(() async {
      final s = SettingsService();
      await s.init();
      return s;
    });
    await mockNetworkImagesFor(() async {
      final fake = FakePlayback();
      await tester.pumpWidget(wrapWithProviders(
        DetailScreen(
          // 入口帖：图文+视频混合帖（2 图 + 视频）
          status: makeStatus(id: '10', text: '混合帖', pics: 2, video: true),
          inlinePlaybackFactory: _factoryOf(fake),
        ),
        weibo: _MediaDroppingFakeService(),
        settings: settings,
      ));
      await _settle(tester);
      // 详情刷新返回丢了媒体，合并后视频播放器与图片都还在
      expect(find.byType(InlineVideoPlayer), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is NetImage && w.url == 'https://example.com/m0.jpg',
        ),
        findsOneWidget,
      );
    });
  });
}
