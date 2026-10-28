import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/widgets/network_image.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/widgets/long_image_viewer.dart';
import 'package:weiyue/widgets/status_card.dart';

import '../helpers/fakes.dart';

const _longPic = WbPic(
  pid: 'long1',
  thumbnail: 'https://example.com/t.jpg',
  bmiddle: 'https://example.com/m.jpg',
  large: 'https://example.com/l.jpg',
  original: 'https://example.com/o.jpg',
  width: 500,
  height: 2000, // 高宽比 4.0 → 长图
);

const _normalPic = WbPic(
  pid: 'norm1',
  thumbnail: 'https://example.com/t2.jpg',
  bmiddle: 'https://example.com/m2.jpg',
  large: 'https://example.com/l2.jpg',
  width: 800,
  height: 600,
);

void main() {
  testWidgets('长图阅读器：已知长图默认滚动阅读模式，可切缩放', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(const MaterialApp(
        home: LongImageReader(pics: [_longPic]),
      ));
      await tester.pump();
      // 滚动阅读模式：有纵向滚动视图、无手势缩放图，标题带「长图」
      expect(find.byKey(const ValueKey('long-image-scroll')), findsOneWidget);
      expect(find.byType(GestureImage), findsNothing);
      expect(find.textContaining('长图'), findsOneWidget);
      // 点模式切换按钮 → 缩放模式
      await tester.tap(find.byKey(const ValueKey('long-image-mode-toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('long-image-zoom')), findsOneWidget);
      expect(find.byKey(const ValueKey('long-image-scroll')), findsNothing);
      // 再点 → 回滚动阅读
      await tester.tap(find.byKey(const ValueKey('long-image-mode-toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('long-image-scroll')), findsOneWidget);
    });
  });

  testWidgets('长图阅读器：普通图只有缩放模式、无模式切换按钮', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(const MaterialApp(
        home: LongImageReader(pics: [_normalPic]),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('long-image-zoom')), findsOneWidget);
      expect(find.byKey(const ValueKey('long-image-scroll')), findsNothing);
      expect(find.byKey(const ValueKey('long-image-mode-toggle')),
          findsNothing);
    });
  });

  testWidgets('长图阅读器：多图时长图/普通图各自判定，按钮逐张翻页',
      (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(const MaterialApp(
        home: LongImageReader(pics: [_longPic, _normalPic]),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('long-image-scroll')), findsOneWidget);
      // 下一张 → 普通图变缩放模式
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();
      expect(find.byKey(const ValueKey('long-image-zoom')), findsOneWidget);
      expect(find.byKey(const ValueKey('long-image-scroll')), findsNothing);
      // 上一张 → 回长图滚动模式
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      expect(find.byKey(const ValueKey('long-image-scroll')), findsOneWidget);
    });
  });

  testWidgets('StatusCard 单张长图：显示「长图」角标', (tester) async {
    await mockNetworkImagesFor(() async {
      const status = WbStatus(
        id: 'lp1',
        text: '长图帖',
        user: WbUser(id: 42, screenName: '测试博主'),
        pics: [_longPic],
      );
      await tester.pumpWidget(wrapWithProviders(
        const Scaffold(body: StatusCard(status: status)),
      ));
      await tester.pump();
      expect(find.text('长图'), findsOneWidget);
    });
  });

  testWidgets('StatusCard 单张普通图：无「长图」角标', (tester) async {
    await mockNetworkImagesFor(() async {
      const status = WbStatus(
        id: 'np1',
        text: '普通图帖',
        user: WbUser(id: 42, screenName: '测试博主'),
        pics: [_normalPic],
      );
      await tester.pumpWidget(wrapWithProviders(
        const Scaffold(body: StatusCard(status: status)),
      ));
      await tester.pump();
      expect(find.text('长图'), findsNothing);
    });
  });
}
