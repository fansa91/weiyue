import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/widgets/long_image_viewer.dart';
import 'package:weiyue/widgets/photo_gallery.dart';

WbPic _pic(String pid) => WbPic(
      pid: pid,
      bmiddle: 'https://img/m$pid.jpg',
      large: 'https://img/l$pid.jpg',
      original: 'https://img/o$pid.jpg',
      width: 800,
      height: 600,
    );

final _pics = [_pic('1'), _pic('2'), _pic('3')];

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

IconButton _btn(WidgetTester tester, String key) =>
    tester.widget<IconButton>(find.byKey(ValueKey(key)));


/// 图库翻页动画 + 网络图加载会持续调度帧，pumpAndSettle 会超时；
/// 改用固定步数 pump 等动画走完（约 300ms 动画 + 若干帧缓冲）。
Future<void> _pumpSteps(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('图库宽屏：两侧按钮可见，首张禁左、点击与方向键可翻页',
      (tester) async {
    await mockNetworkImagesFor(() async {
      _setSize(tester, const Size(1500, 900));
      await tester.pumpWidget(MaterialApp(home: PhotoGalleryScreen(pics: _pics)));
      await tester.pump();

      expect(find.byKey(const ValueKey('viewer-prev-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-next-button')), findsOneWidget);
      expect(_btn(tester, 'viewer-prev-button').onPressed, isNull,
          reason: '首张时上一张应禁用');
      expect(_btn(tester, 'viewer-next-button').onPressed, isNotNull);
      expect(find.text('1 / 3'), findsWidgets);

      // 点下一张按钮
      await tester.tap(find.byKey(const ValueKey('viewer-next-button')));
      await _pumpSteps(tester);
      expect(find.text('2 / 3'), findsWidgets);

      // 方向键右 → 第 3 张，下一张禁用
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _pumpSteps(tester);
      expect(find.text('3 / 3'), findsWidgets);
      expect(_btn(tester, 'viewer-next-button').onPressed, isNull,
          reason: '末张时下一张应禁用');

      // 方向键左 → 回第 2 张
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await _pumpSteps(tester);
      expect(find.text('2 / 3'), findsWidgets);
    });
  });

  testWidgets('图库窄屏（移动端）：不显示两侧按钮', (tester) async {
    await mockNetworkImagesFor(() async {
      _setSize(tester, const Size(420, 900));
      await tester.pumpWidget(MaterialApp(home: PhotoGalleryScreen(pics: _pics)));
      await tester.pump();
      expect(find.byKey(const ValueKey('viewer-prev-button')), findsNothing);
      expect(find.byKey(const ValueKey('viewer-next-button')), findsNothing);
    });
  });

  testWidgets('长图阅读器宽屏：两侧按钮可见且可翻页', (tester) async {
    await mockNetworkImagesFor(() async {
      _setSize(tester, const Size(1500, 900));
      await tester.pumpWidget(MaterialApp(home: LongImageReader(pics: _pics)));
      await tester.pump();

      expect(find.byKey(const ValueKey('viewer-prev-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-next-button')), findsOneWidget);
      expect(_btn(tester, 'viewer-prev-button').onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('viewer-next-button')));
      await tester.pump();
      expect(find.text('2 / 3'), findsWidgets);
      expect(_btn(tester, 'viewer-prev-button').onPressed, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('3 / 3'), findsWidgets);
      expect(_btn(tester, 'viewer-next-button').onPressed, isNull);
    });
  });

  testWidgets('长图阅读器窄屏：不显示两侧按钮', (tester) async {
    await mockNetworkImagesFor(() async {
      _setSize(tester, const Size(420, 900));
      await tester.pumpWidget(MaterialApp(home: LongImageReader(pics: _pics)));
      await tester.pump();
      expect(find.byKey(const ValueKey('viewer-prev-button')), findsNothing);
      expect(find.byKey(const ValueKey('viewer-next-button')), findsNothing);
    });
  });
}
