import 'package:extended_image_plus/extended_image_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/widgets/status_card.dart';

import '../helpers/fakes.dart';

Future<void> _pumpCard(WidgetTester tester, dynamic status,
    {bool tappable = true, bool expanded = false}) {
  return mockNetworkImagesFor(() async {
    await tester.pumpWidget(wrapWithProviders(
      Scaffold(
          body: SingleChildScrollView(
              child: StatusCard(
                  status: status, tappable: tappable, expanded: expanded))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  });
}

void main() {
  testWidgets('纯文本形态：正文与三计数可见', (tester) async {
    await _pumpCard(tester, makeStatus(text: '纯文本内容 abc'));
    expect(find.textContaining('纯文本内容 abc', findRichText: true),
        findsOneWidget);
    expect(find.text('3'), findsOneWidget); // 转发数
    expect(find.text('5'), findsOneWidget); // 评论数
    expect(find.text('9'), findsOneWidget); // 点赞数
    expect(find.byType(ExtendedImage), findsOneWidget); // 仅头像
    expect(find.text('测试博主'), findsWidgets);
  });

  testWidgets('单图：正文 1 张图、无 GridView', (tester) async {
    await _pumpCard(tester, makeStatus(pics: 1));
    // 头像 1 + 正文图 1
    expect(find.byType(ExtendedImage), findsNWidgets(2));
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('四图宫格：GridView + 4 张图', (tester) async {
    await _pumpCard(tester, makeStatus(pics: 4));
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ExtendedImage), findsNWidgets(5)); // 头像+4
  });

  testWidgets('九宫格：9 张图', (tester) async {
    await _pumpCard(tester, makeStatus(pics: 9));
    expect(find.byType(ExtendedImage), findsNWidgets(10)); // 头像+9
  });

  testWidgets('视频封面：时长与播放量可见', (tester) async {
    await _pumpCard(tester, makeStatus(video: true));
    expect(find.text('11:43'), findsOneWidget);
    expect(find.text('15.4万次观看'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
  });

  testWidgets('转发内嵌卡：原作者与原文可见', (tester) async {
    final outer = makeStatus(
      text: '转发说两句',
      retweeted: makeStatus(
          id: '2002', text: '被转发的原文内容', authorName: '原作者君'),
    );
    await _pumpCard(tester, outer);
    expect(find.textContaining('转发说两句', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('原作者君', findRichText: true), findsWidgets);
    expect(find.textContaining('被转发的原文内容', findRichText: true),
        findsOneWidget);
  });

  testWidgets('长文标记：列表态显示「全文」', (tester) async {
    await _pumpCard(tester, makeStatus(text: '长文开头……', isLongText: true));
    expect(find.text('全文'), findsOneWidget);
  });

  testWidgets('长文展开态不显示「全文」标记', (tester) async {
    await _pumpCard(
        tester, makeStatus(text: '长文全文……', isLongText: true),
        tappable: false, expanded: true);
    expect(find.text('全文'), findsNothing);
  });

  testWidgets('分享按钮：复制帖子链接到剪贴板且不进详情', (tester) async {
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText =
            (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pumpCard(tester, makeStatus(id: '1001'));
    await tester.tap(find.byIcon(Icons.share_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // makeStatus 约定：mblogid = 'AbC{id}'，作者 uid = 42
    expect(clipboardText, 'https://weibo.com/42/AbC1001');
    expect(find.text('链接已复制'), findsOneWidget);
    // 分享按钮自行拦截点击：整卡跳转没有被触发，详情页未推入
    expect(find.byType(DetailScreen), findsNothing);
  });

  test('wbStatusUrl：mblogid 为空时退详情式链接', () {
    final noMblogid = WbStatus(
      id: '777',
      mblogid: '',
      user: makeStatus().user,
      text: 'x',
    );
    expect(wbStatusUrl(noMblogid), 'https://weibo.com/detail/777');
    expect(wbStatusUrl(makeStatus(id: '1001')),
        'https://weibo.com/42/AbC1001');
  });
}
