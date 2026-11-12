import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/core/emoticons.dart';
import 'package:weiyue/screens/compose_screen.dart';
import 'package:weiyue/screens/home_screen.dart';

import '../helpers/fakes.dart';

/// 发帖页组件测试（全走 FakeWeiyueService，不碰真实接口）：
/// 草稿恢复/清除、发布成功/失败流、表情插入、#话题# 占位选中、
/// @选人插入、选图缩略图+删除、带图发布（先上传再发布）、
/// 上传失败保留内容并可重试、首页入口的登录门闩。
/// 与 screens_test 同款的定步进 settle：工程内 ExtendedImage 等组件
/// 永远有待处理帧，pumpAndSettle 会超时或把 SnackBar 泵过期，
/// 统一用固定小步进泵（微任务/路由动画/进出场都够，SnackBar 还在）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 一张合法的 1×1 PNG（缩略图能真解码，避免图片异常干扰断言）。
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  late FakeWeiyueService svc;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    svc = FakeWeiyueService();
  });

  tearDown(() => Emoticons.resetForTest());

  /// 打开一页发帖页的宿主：点按钮 push，发帖页 pop 后回到宿主，
  /// 用来断言「发布成功才返回」。
  Widget host({ComposeImagePicker? picker}) {
    return wrapWithProviders(
      Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute(
                  builder: (_) => ComposeScreen(imagePicker: picker),
                ),
              ),
              child: const Text('打开编辑器'),
            ),
          ),
        ),
      ),
      weibo: svc,
      session: FakeSessionService(loggedIn: true),
    );
  }

  Future<void> openCompose(
    WidgetTester tester, {
    ComposeImagePicker? picker,
  }) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(host(picker: picker));
      await tester.tap(find.text('打开编辑器'));
      await _settle(tester);
    });
    expect(find.byType(ComposeScreen), findsOneWidget);
  }

  TextEditingController fieldController(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText).first).controller;

  testWidgets('草稿恢复：重开自动填回上次文本', (tester) async {
    SharedPreferences.setMockInitialValues({
      'weiyue_compose_draft_text_v1': '未发出的草稿',
      'weiyue_compose_draft_pics_v1': <String>[],
    });
    await openCompose(tester);
    expect(fieldController(tester).text, '未发出的草稿');
  });

  testWidgets('纯文字发布：调用 publishStatus、pop 返回、草稿清除', (tester) async {
    SharedPreferences.setMockInitialValues({
      'weiyue_compose_draft_text_v1': '旧草稿',
      'weiyue_compose_draft_pics_v1': <String>[],
    });
    await openCompose(tester);
    await tester.enterText(
      find.byKey(const ValueKey('compose-text-field')),
      '今天的第一条动态',
    );
    await tester.pump(); // 等发布按钮可用态重建（滞后一帧）
    await tester.tap(find.byKey(const ValueKey('compose-publish-button')));
    await _settle(tester);

    expect(svc.publishCalls, hasLength(1));
    expect(svc.publishCalls.single.content, '今天的第一条动态');
    expect(svc.publishCalls.single.pics, isEmpty);
    await _settle(tester);
    expect(find.byType(ComposeScreen), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('weiyue_compose_draft_text_v1'), isNull);
    expect(prefs.getStringList('weiyue_compose_draft_pics_v1'), isNull);
  });

  testWidgets('发布失败：停在发帖页、显示服务端消息、内容保留', (tester) async {
    svc.failPublish = true;
    await openCompose(tester);
    await tester.enterText(
      find.byKey(const ValueKey('compose-text-field')),
      '会失败的内容',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('compose-publish-button')));
    await _settle(tester);

    expect(find.byType(ComposeScreen), findsOneWidget);
    expect(find.textContaining('发布失败（假）'), findsWidgets);
    expect(fieldController(tester).text, '会失败的内容');
    expect(svc.publishCalls, isEmpty);
  });

  testWidgets('输入即存草稿：SharedPreferences 落盘文本', (tester) async {
    await openCompose(tester);
    await tester.enterText(
      find.byKey(const ValueKey('compose-text-field')),
      '写到一半',
    );
    await _settle(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('weiyue_compose_draft_text_v1'), '写到一半');
  });

  testWidgets('表情插入：面板点选把短码插入正文（与渲染映射同名同格式）', (tester) async {
    Emoticons.install({
      '[微笑]': 'https://example.com/emo/smile.png',
      '[泪]': 'https://example.com/emo/lei.png',
    });
    await openCompose(tester);
    await tester.enterText(
      find.byKey(const ValueKey('compose-text-field')),
      '心情',
    );
    await tester.tap(find.byKey(const ValueKey('compose-emoticon-button')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('compose-emoticon-panel')),
      findsOneWidget,
    );
    await mockNetworkImagesFor(() async {
      await tester.tap(find.byKey(const ValueKey('compose-emoticon-[微笑]')));
      await _settle(tester);
    });
    expect(fieldController(tester).text, '心情[微笑]');
  });

  testWidgets('# 话题：插入 #话题# 并选中中间占位文字', (tester) async {
    await openCompose(tester);
    await tester.enterText(
      find.byKey(const ValueKey('compose-text-field')),
      '聊聊',
    );
    await tester.tap(find.byKey(const ValueKey('compose-topic-button')));
    await _settle(tester);
    final c = fieldController(tester);
    expect(c.text, '聊聊#话题#');
    expect(c.selection.baseOffset, 3);
    expect(c.selection.extentOffset, 5);
    expect(c.text.substring(3, 5), '话题');
  });

  testWidgets('@选人：搜索点中用户后插入 @昵称 ', (tester) async {
    await openCompose(tester);
    await tester.tap(find.byKey(const ValueKey('compose-mention-button')));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('mention-keyword-field')),
      '测试',
    );
    await mockNetworkImagesFor(() async {
      await tester.tap(find.byKey(const ValueKey('mention-search-button')));
      await _settle(tester);
    });
    // FakeWeiyueService 的用户分类返回「测试博主」（id 42）
    await tester.tap(find.byKey(const ValueKey('mention-user-42')));
    await _settle(tester);
    expect(fieldController(tester).text, '@测试博主 ');
  });

  testWidgets('选图：缩略图出现、可删除', (tester) async {
    Future<List<ComposePickedImage>> picker(int remaining) async => [
      ComposePickedImage(
        path: '/tmp/fake_a.png',
        bytes: pngBytes,
        mimeType: 'image/png',
      ),
    ];
    await openCompose(tester, picker: picker);
    await tester.tap(find.byKey(const ValueKey('compose-pick-image-button')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('compose-image-remove-0')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('compose-image-remove-0')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('compose-image-remove-0')), findsNothing);
  });

  testWidgets('带图发布：先逐张上传拿 pid，再按 pid+type 组装发布', (tester) async {
    Future<List<ComposePickedImage>> picker(int remaining) async => [
      ComposePickedImage(
        path: '/tmp/fake_b.jpg',
        bytes: pngBytes,
        mimeType: 'image/jpeg',
      ),
    ];
    await openCompose(tester, picker: picker);
    await tester.enterText(
      find.byKey(const ValueKey('compose-text-field')),
      '带图动态',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('compose-pick-image-button')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('compose-publish-button')));
    await _settle(tester);

    expect(svc.uploadCalls, hasLength(1));
    expect(svc.uploadCalls.single, pngBytes);
    expect(svc.publishCalls, hasLength(1));
    expect(svc.publishCalls.single.pics, [
      (pid: 'FAKE_PID_1', type: 'image/jpeg'),
    ]);
    await _settle(tester);
    expect(find.byType(ComposeScreen), findsNothing);
  });

  testWidgets('上传失败：留在页面显示失败态，点重试成功后可发布', (tester) async {
    svc.failUpload = true;
    Future<List<ComposePickedImage>> picker(int remaining) async => [
      ComposePickedImage(
        path: '/tmp/fake_c.png',
        bytes: pngBytes,
        mimeType: 'image/png',
      ),
    ];
    await openCompose(tester, picker: picker);
    await tester.enterText(
      find.byKey(const ValueKey('compose-text-field')),
      '图传不上去',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('compose-pick-image-button')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('compose-publish-button')));
    await _settle(tester);

    expect(find.byType(ComposeScreen), findsOneWidget);
    expect(find.textContaining('上传图片失败'), findsWidgets);
    expect(find.byKey(const ValueKey('compose-image-retry-0')), findsOneWidget);
    expect(svc.publishCalls, isEmpty);
    expect(fieldController(tester).text, '图传不上去');

    svc.failUpload = false;
    await tester.tap(find.byKey(const ValueKey('compose-image-retry-0')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('compose-publish-button')));
    await _settle(tester);
    expect(svc.publishCalls, hasLength(1));
    expect(svc.publishCalls.single.pics.single.pid, 'FAKE_PID_1');
    await _settle(tester);
    expect(find.byType(ComposeScreen), findsNothing);
  });

  testWidgets('图片草稿恢复：路径文件还在才恢复，发布时按路径读字节上传', (tester) async {
    // 同步 IO 建文件：testWidgets 的 fake zone 里 await 真实异步 IO
    // 永远等不到完成（会挂死整场测试）。
    final dir = Directory.systemTemp.createTempSync('weiyue_compose_');
    final file = File('${dir.path}/draft.png')..writeAsBytesSync(pngBytes);
    SharedPreferences.setMockInitialValues({
      'weiyue_compose_draft_text_v1': '带图草稿',
      'weiyue_compose_draft_pics_v1': [file.path, '/nonexistent/gone.png'],
    });
    addTearDown(() => dir.delete(recursive: true));

    await openCompose(tester);
    expect(fieldController(tester).text, '带图草稿');
    // 只恢复存在的那张，已删除的文件被忽略
    expect(
      find.byKey(const ValueKey('compose-image-remove-0')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('compose-image-remove-1')), findsNothing);

    // 发布要按路径读文件字节（异步 IO）：fake zone 里 IO 完成事件
    // 送达不了，必须把点击与等待放进 runAsync 的真实 zone 等它落账。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('compose-publish-button')));
      for (var i = 0; i < 100 && svc.publishCalls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await _settle(tester);
    await _settle(tester);
    expect(svc.uploadCalls.single, pngBytes);
    expect(svc.publishCalls.single.pics.single.type, 'image/png');
    expect(find.byType(ComposeScreen), findsNothing);
  });

  testWidgets('首页入口：未登录点发帖只提示去登录，不打开编辑页', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        wrapWithProviders(
          const HomeScreen(),
          weibo: svc,
          session: FakeSessionService(loggedIn: false),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('home-compose-button')));
      await _settle(tester);
    });
    expect(find.text('登录后可用'), findsOneWidget);
    expect(find.byType(ComposeScreen), findsNothing);
  });

  testWidgets('首页入口：已登录点发帖打开编辑页', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        wrapWithProviders(
          const HomeScreen(),
          weibo: svc,
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('home-compose-button')));
      await _settle(tester);
    });
    expect(find.byType(ComposeScreen), findsOneWidget);
  });
}
