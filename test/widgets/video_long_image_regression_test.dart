import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/widgets/long_image_viewer.dart';
import 'package:weiyue/widgets/network_image.dart';
import 'package:weiyue/widgets/status_card.dart';

import '../helpers/fakes.dart';

const _longPic = WbPic(
  pid: 'frame1',
  thumbnail: 'https://example.com/ft.jpg',
  bmiddle: 'https://example.com/fm.jpg',
  large: 'https://example.com/fl.jpg',
  width: 192,
  height: 480, // 高宽比 2.5 → 尺寸上是「长图」（实为视频帧漏网时的形态）
);

const _video = WbVideo(
  cover: 'https://example.com/vcover.jpg',
  durationSec: 40,
  fallbackUrl: 'https://example.com/v.mp4',
);

// 默认图片清晰度为「标准」→ 列表图取 bmiddle 档，NetImage 以此 URL 渲染。
Finder _picImage() => find.byWidgetPredicate(
      (w) => w is NetImage && w.url == _longPic.bmiddle,
    );

void main() {
  testWidgets('视频帖图片区：不出现「长图」角标（解析层漏网时的 UI 兜底）',
      (tester) async {
    await mockNetworkImagesFor(() async {
      const status = WbStatus(
        id: 'vp1',
        text: '视频帖带一张漏网帧图',
        user: WbUser(id: 42, screenName: '测试博主'),
        pics: [_longPic],
        video: _video,
      );
      await tester.pumpWidget(wrapWithProviders(
        const Scaffold(
          body: SingleChildScrollView(
            child: StatusCard(status: status, tappable: false),
          ),
        ),
      ));
      await tester.pump();
      expect(_picImage(), findsOneWidget); // 图片区确实渲染了
      expect(find.text('长图'), findsNothing); // 但不标长图
    });
  });

  testWidgets('直播帖点图片：进详情页，不进长图阅读器', (tester) async {
    await mockNetworkImagesFor(() async {
      const status = WbStatus(
        id: 'lv1',
        text: '直播帖带一张漏网帧图',
        user: WbUser(id: 42, screenName: '测试博主'),
        pics: [_longPic],
        isLive: true,
        pageObjectId: '1034:live_001',
      );
      await tester.pumpWidget(wrapWithProviders(
        const Scaffold(body: StatusCard(status: status, tappable: false)),
      ));
      await tester.pump();
      expect(find.text('长图'), findsNothing);
      await tester.tap(_picImage());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.byType(LongImageReader), findsNothing);
    });
  });

  testWidgets('普通长图帖不受影响：角标在，点开进长图阅读器', (tester) async {
    await mockNetworkImagesFor(() async {
      const status = WbStatus(
        id: 'lp9',
        text: '普通长图帖',
        user: WbUser(id: 42, screenName: '测试博主'),
        pics: [_longPic],
      );
      await tester.pumpWidget(wrapWithProviders(
        const Scaffold(body: StatusCard(status: status, tappable: false)),
      ));
      await tester.pump();
      expect(find.text('长图'), findsOneWidget);
      await tester.tap(_picImage());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LongImageReader), findsOneWidget);
      expect(find.byType(DetailScreen), findsNothing);
    });
  });

  testWidgets('mix 混合帖（实证 fixture）：有视频封面与图片，无长图角标',
      (tester) async {
    await mockNetworkImagesFor(() async {
      final status = WbStatus.fromJson(
        jsonDecode(File('test/fixtures/pc_mix_media.json').readAsStringSync())
            as Map<String, dynamic>,
      );
      expect(status.hasVideo, isTrue);
      expect(status.pics.length, 3);
      await tester.pumpWidget(wrapWithProviders(
        Scaffold(
          body: SingleChildScrollView(
            child: StatusCard(status: status, tappable: false),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('长图'), findsNothing);
      // 视频封面区出现（播放图标），图片网格也在
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    });
  });

  testWidgets('转发链收口：原帖是视频帖时，外层长图不标角标', (tester) async {
    await mockNetworkImagesFor(() async {
      const status = WbStatus(
        id: 'rt1',
        text: '转发一条视频帖，自己配了张长图',
        user: WbUser(id: 42, screenName: '测试博主'),
        pics: [_longPic],
        retweeted: WbStatus(
          id: 'rt0',
          text: '原帖是视频',
          user: WbUser(id: 43, screenName: '原博主'),
          video: _video,
        ),
      );
      await tester.pumpWidget(wrapWithProviders(
        const Scaffold(
          body: SingleChildScrollView(
            child: StatusCard(status: status, tappable: false),
          ),
        ),
      ));
      await tester.pump();
      expect(_picImage(), findsOneWidget); // 外层图片仍渲染
      expect(find.text('长图'), findsNothing); // 但不作长图处理
    });
  });
}
