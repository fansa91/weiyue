import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/widgets/long_image_viewer.dart';
import 'package:weiyue/widgets/photo_gallery.dart';

const _p1 = WbPic(
  pid: 'p1',
  bmiddle: 'https://img/m1.jpg',
  large: 'https://img/l1.jpg',
  original: 'https://img/o1.jpg',
  width: 800,
  height: 600,
);
const _p2 = WbPic(
  pid: 'p2',
  bmiddle: 'https://img/m2.jpg',
  large: 'https://img/l2.jpg',
  original: 'https://img/o2.jpg',
  width: 800,
  height: 600,
);

void main() {
  testWidgets('图库：多图时标题与底部页码显示 1 / 2，单图不显示', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        const MaterialApp(home: PhotoGalleryScreen(pics: [_p1, _p2])),
      );
      await tester.pump();
      expect(find.text('1 / 2'), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('gallery-page-indicator')),
        findsOneWidget,
      );

      await tester.pumpWidget(
        const MaterialApp(home: PhotoGalleryScreen(pics: [_p1])),
      );
      await tester.pump();
      expect(find.text('1 / 1'), findsNothing);
      expect(
        find.byKey(const ValueKey('gallery-page-indicator')),
        findsNothing,
      );
    });
  });

  testWidgets('长图查看：多图时底部页码显示，单图不显示', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        const MaterialApp(home: LongImageReader(pics: [_p1, _p2])),
      );
      await tester.pump();
      expect(find.text('1 / 2'), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('long-image-page-indicator')),
        findsOneWidget,
      );

      await tester.pumpWidget(
        const MaterialApp(home: LongImageReader(pics: [_p1])),
      );
      await tester.pump();
      expect(find.text('1 / 1'), findsNothing);
      expect(
        find.byKey(const ValueKey('long-image-page-indicator')),
        findsNothing,
      );
    });
  });
}
