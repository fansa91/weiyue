import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/download_service.dart';
import 'package:weiyue/widgets/download_button.dart';
import 'package:weiyue/widgets/status_card.dart';

import '../helpers/fakes.dart';

class _OkDownloader implements StreamDownloader {
  @override
  Future<void> downloadToFile(
    String url,
    File file, {
    DownloadProgress? onProgress,
  }) async {
    await file.writeAsBytes([1, 2, 3]);
    onProgress?.call(3, 3);
  }

  @override
  Future<List<int>> downloadBytes(
    String url, {
    DownloadProgress? onProgress,
  }) async {
    onProgress?.call(3, 3);
    return [1, 2, 3];
  }
}

class _OkGallery implements GallerySaver {
  @override
  Future<void> saveImageBytes(List<int> bytes, {required String name}) async {}
  @override
  Future<void> saveVideoFile(String filePath) async {}
}

WbStatus videoStatus() => WbStatus(
      id: '777',
      source: '',
      user: const WbUser(id: 1, screenName: '甲'),
      text: '带视频的帖',
      repostsCount: 0,
      commentsCount: 0,
      attitudesCount: 0,
      pics: const [],
      video: const WbVideo(
        cover: 'https://img.example.com/cover.jpg',
        durationSec: 30,
        playbackList: [
          WbPlayback(label: 'mp4_hd', height: 720, url: 'https://v.example.com/hd.mp4'),
          WbPlayback(label: 'mp4_ld', height: 360, url: 'https://v.example.com/sd.mp4'),
        ],
        fallbackUrl: 'https://v.example.com/sd.mp4',
      ),
    );


/// 下载链路跨真实文件 IO 与 fake-async 区：单次 runAsync 或 pump 都不够，
/// 交替放行真实事件循环与假时间帧，直到 SnackBar 出现（上限约 12 轮）。
Future<void> _awaitDownloadFeedback(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(SnackBar).evaluate().isNotEmpty) return;
  }
}

void main() {
  late Directory root;
  late Directory downloads;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('weiyue_dl_btn');
    downloads = await Directory('${root.path}/downloads').create();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  DownloadService desktopSvc() => DownloadService(
        downloader: _OkDownloader(),
        gallerySaver: _OkGallery(),
        downloadsDirectory: () async => downloads,
        tempDirectory: () async => root,
        useGallery: false,
      );

  testWidgets('图片下载按钮：点击后 SnackBar 报保存路径', (tester) async {
    const pic = WbPic(
      pid: 'p9',
      thumbnail: 'https://img.example.com/t.jpg',
      original: 'https://img.example.com/o.jpg',
      width: 100,
      height: 100,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PicDownloadButton(
            pic: pic,
            baseName: 'weiyue_p9',
            service: desktopSvc(),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.download_outlined));
    await _awaitDownloadFeedback(tester);
    expect(find.textContaining('已保存到'), findsOneWidget);
    expect(find.textContaining('weiyue_p9.jpg'), findsOneWidget);
  });

  testWidgets('视频封面菜单：点开出现「下载视频」且不误触进详情', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        wrapWithProviders(
          StatusCard(status: videoStatus(), downloadService: desktopSvc()),
        ),
      );
      await tester.pump();
      // 封面右上角「更多」菜单按钮
      final menuBtn = find.byIcon(Icons.more_vert);
      expect(menuBtn, findsOneWidget);
      await tester.tap(menuBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('下载视频'), findsOneWidget);
      // 菜单项点选后的下载状态机与图标按钮共用 _DownloadButtonCore，
      // 其 SnackBar 反馈已由上方图片按钮用例覆盖；此处只断言菜单
      // 本身：能打开、有「下载视频」项、且没有误触整卡进详情页。
      expect(find.byType(PopupMenuItem<String>), findsOneWidget);
    });
  });
}
