import 'dart:async';
import 'dart:convert';

import 'package:extended_image_plus/extended_image_plus.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/widgets/live_photo_view.dart';
import 'package:weiyue/widgets/photo_gallery.dart';
import 'package:weiyue/widgets/status_card.dart';

import '../helpers/fakes.dart';

const _livePic = WbPic(
  pid: 'live1',
  bmiddle: 'https://img.example.com/m-live.jpg',
  large: 'https://img.example.com/l-live.jpg',
  original: 'https://img.example.com/o-live.jpg',
  width: 800,
  height: 600,
  liveVideoUrl: 'https://video.example.com/media/play?livephoto=FAKE',
  liveVideoFallbackUrl: 'https://us.example.com/fakefid000000000000001.mov',
);

const _normalPic = WbPic(
  pid: 'normal1',
  bmiddle: 'https://img.example.com/m-normal.jpg',
  large: 'https://img.example.com/l-normal.jpg',
  original: 'https://img.example.com/o-normal.jpg',
  width: 800,
  height: 600,
);

/// 假实况播放后端：记录打开过的地址，可指定哪些地址打开即失败，
/// 可手动往 errorStream 塞错误模拟播放中途失败。
class FakeLivePlayback implements LivePlayback {
  FakeLivePlayback({this.failUrls = const {}});

  final Set<String> failUrls;
  final List<String> openedUrls = [];
  final StreamController<String> _errors = StreamController<String>.broadcast();
  int playCount = 0;
  int pauseCount = 0;
  bool disposed = false;

  void emitError(String message) => _errors.add(message);

  @override
  Stream<String> get errorStream => _errors.stream;

  @override
  Future<void> open(String url) async {
    openedUrls.add(url);
    if (failUrls.contains(url)) {
      throw Exception('fake open failed');
    }
  }

  @override
  Future<void> play() async => playCount++;

  @override
  Future<void> pause() async => pauseCount++;

  @override
  Future<void> seekToStart() async {}

  @override
  Future<void> dispose() async => disposed = true;

  @override
  Widget buildSurface() =>
      const SizedBox.expand(key: ValueKey('fake-live-surface'));
}

WbStatus _statusWithPics(List<WbPic> pics) => WbStatus(
  id: 's-live',
  mblogid: 'BidLive',
  user: makeStatus().user,
  text: '带图帖',
  createdAtRaw: '刚刚',
  repostsCount: 1,
  commentsCount: 2,
  attitudesCount: 3,
  pics: pics,
);

void main() {
  testWidgets('图库：实况照片当前页有 LIVE 标识，普通照片没有', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        const MaterialApp(home: PhotoGalleryScreen(pics: [_livePic])),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('gallery-live-badge')), findsOneWidget);
      expect(find.byType(LivePhotoView), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(home: PhotoGalleryScreen(pics: [_normalPic])),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('gallery-live-badge')), findsNothing);
      expect(find.byType(LivePhotoView), findsNothing);
    });
  });

  testWidgets('帖子卡片宫格：实况照片有 LIVE 角标，普通照片不加', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        wrapWithProviders(
          Scaffold(
            body: SingleChildScrollView(
              child: StatusCard(
                status: _statusWithPics(const [_livePic, _normalPic]),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('pic-live-badge')), findsOneWidget);

      await tester.pumpWidget(
        wrapWithProviders(
          Scaffold(
            body: SingleChildScrollView(
              child: StatusCard(
                status: _statusWithPics(const [_normalPic, _normalPic]),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('pic-live-badge')), findsNothing);
    });
  });

  testWidgets('长按实况照片：主地址打开失败自动切兜底直链，松手回静图', (tester) async {
    final fake = FakeLivePlayback(failUrls: {_livePic.liveVideoUrl});
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: LivePhotoView(
            pic: _livePic,
            imageUrl: _livePic.large,
            playbackFactory: () => fake,
          ),
        ),
      );
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LivePhotoView)),
      );
      // 静止按住越过长按阈值 → 触发开播链
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump();
      expect(fake.openedUrls, [
        _livePic.liveVideoUrl,
        _livePic.liveVideoFallbackUrl,
      ]);
      expect(fake.playCount, 1);
      expect(find.byKey(const ValueKey('fake-live-surface')), findsOneWidget);
      // 松手：停播、视频层撤下回静图
      await gesture.up();
      await tester.pump();
      expect(find.byKey(const ValueKey('fake-live-surface')), findsNothing);
      expect(fake.pauseCount, greaterThanOrEqualTo(1));
    });
  });

  testWidgets('长按实况照片：播放中途出错切兜底直链', (tester) async {
    final fake = FakeLivePlayback();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: LivePhotoView(
            pic: _livePic,
            imageUrl: _livePic.large,
            playbackFactory: () => fake,
          ),
        ),
      );
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LivePhotoView)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump();
      expect(fake.openedUrls, [_livePic.liveVideoUrl]);
      expect(find.byKey(const ValueKey('fake-live-surface')), findsOneWidget);
      // 主地址播放中途报错 → 切兜底直链续播，视频层不撤
      fake.emitError('fake mid-play error');
      await tester.pump();
      await tester.pump();
      expect(fake.openedUrls, [
        _livePic.liveVideoUrl,
        _livePic.liveVideoFallbackUrl,
      ]);
      expect(find.byKey(const ValueKey('fake-live-surface')), findsOneWidget);
      await gesture.up();
      await tester.pump();
    });
  });

  testWidgets('长按实况照片：全部候选失败静默回静图（不抛错、无视频层）', (tester) async {
    final fake = FakeLivePlayback(
      failUrls: {_livePic.liveVideoUrl, _livePic.liveVideoFallbackUrl},
    );
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: LivePhotoView(
            pic: _livePic,
            imageUrl: _livePic.large,
            playbackFactory: () => fake,
          ),
        ),
      );
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LivePhotoView)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump();
      expect(fake.openedUrls, [
        _livePic.liveVideoUrl,
        _livePic.liveVideoFallbackUrl,
      ]);
      expect(fake.playCount, 0);
      expect(find.byKey(const ValueKey('fake-live-surface')), findsNothing);
      await gesture.up();
      await tester.pump();
    });
  });

  testWidgets('点 LIVE 标识：切换播放/暂停，小图标随状态变', (tester) async {
    final fake = FakeLivePlayback();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: LivePhotoView(
            pic: _livePic,
            imageUrl: _livePic.large,
            playbackFactory: () => fake,
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('live-badge-icon-play')), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-live-surface')), findsNothing);

      // 点标识开播：打开主地址、视频层出现、图标变暂停
      await tester.tap(find.byKey(const ValueKey('gallery-live-badge')));
      await tester.pump();
      await tester.pump();
      expect(fake.openedUrls, [_livePic.liveVideoUrl]);
      expect(fake.playCount, 1);
      expect(find.byKey(const ValueKey('fake-live-surface')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('live-badge-icon-pause')),
        findsOneWidget,
      );

      // 再点标识停播：暂停、视频层撤下、图标回播放
      await tester.tap(find.byKey(const ValueKey('gallery-live-badge')));
      await tester.pump();
      await tester.pump();
      expect(fake.pauseCount, greaterThanOrEqualTo(1));
      expect(find.byKey(const ValueKey('fake-live-surface')), findsNothing);
      expect(find.byKey(const ValueKey('live-badge-icon-play')), findsOneWidget);
    });
  });

  testWidgets('桌面悬停：鼠标移入自动播放、移出停止（触摸不触发）', (tester) async {
    final fake = FakeLivePlayback();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: LivePhotoView(
                pic: _livePic,
                imageUrl: _livePic.large,
                playbackFactory: () => fake,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      // 指针先落在视图外（左上角），不应触发播放
      await mouse.addPointer(location: const Offset(10, 10));
      await tester.pump();
      expect(fake.playCount, 0);

      // 移入图片区域：自动开播
      await mouse.moveTo(tester.getCenter(find.byType(LivePhotoView)));
      await tester.pump();
      await tester.pump();
      expect(fake.openedUrls, [_livePic.liveVideoUrl]);
      expect(fake.playCount, 1);
      expect(find.byKey(const ValueKey('fake-live-surface')), findsOneWidget);

      // 移出：停播回静图
      await mouse.moveTo(const Offset(10, 10));
      await tester.pump();
      await tester.pump();
      expect(fake.pauseCount, greaterThanOrEqualTo(1));
      expect(find.byKey(const ValueKey('fake-live-surface')), findsNothing);
      await mouse.removePointer();
    });
  });

  testWidgets('图库滑出配置：纵向 SlidePage 承接、图片开 enableSlideOutPage、背景随偏移渐隐', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        const MaterialApp(home: PhotoGalleryScreen(pics: [_normalPic])),
      );
      await tester.pump();
      final slidePage = tester.widget<ExtendedImageSlidePage>(
        find.byType(ExtendedImageSlidePage),
      );
      expect(slidePage.slideAxis, SlideAxis.vertical);
      final images = tester
          .widgetList<ExtendedImage>(find.byType(ExtendedImage))
          .toList();
      expect(images, isNotEmpty);
      expect(images.every((i) => i.enableSlideOutPage), isTrue);
      final handler = slidePage.slidePageBackgroundHandler!;
      const size = Size(400, 800);
      final atRest = handler(Offset.zero, size);
      final dragged = handler(const Offset(0, 200), size);
      expect(dragged.a, lessThan(atRest.a));
    });
  });

  // 图库本体的网络图带 cache:true，其图片供给在测试 mock 下永远完不成
  // 加载（转圈不止、手势层不激活，既有环境特性），无法直接对图库页做
  // 拖拽断言；故滑出 pop 用与图库完全相同的库配置（纵向 SlidePage +
  // enableSlideOutPage + 同款 GestureConfig）配内存图实证机制，
  // 图库自身的接线由上一条配置测试断言。
  testWidgets('滑出机制实证：同款配置下未缩放竖拖过阈值松手 pop', (tester) async {
    final image = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  body: ExtendedImageSlidePage(
                    slideAxis: SlideAxis.vertical,
                    slidePageBackgroundHandler: (offset, pageSize) =>
                        defaultSlidePageBackgroundHandler(
                          offset: offset,
                          pageSize: pageSize,
                          color: Colors.black,
                          pageGestureAxis: SlideAxis.vertical,
                        ),
                    // 与图库一致的紧约束全页尺寸（PageView 给的也是紧约束；
                    // loose 约束下 ExtendedImage 手势模式会缩成 0 尺寸）。
                    child: SizedBox.expand(
                      child: ExtendedImage(
                        image: image,
                        mode: ExtendedImageMode.gesture,
                        enableSlideOutPage: true,
                        initGestureConfigHandler: (_) => GestureConfig(
                          minScale: 0.8,
                          maxScale: 3.0,
                          initialScale: 1.0,
                          cacheGesture: false,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('open-viewer'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-viewer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ExtendedImageSlidePage), findsOneWidget);
    await tester.drag(find.byType(ExtendedImage), const Offset(0, 600));
    await tester.pump();
    // 路由退场动画需多帧推进（实测约 600ms 泵完）
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(ExtendedImageSlidePage), findsNothing);
  });
}
