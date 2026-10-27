import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/core/emoticons.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/playlist_screen.dart';
import 'package:weiyue/screens/profile_screen.dart';
import 'package:weiyue/screens/search_screen.dart';
import 'package:weiyue/screens/topic_screen.dart';
import 'package:weiyue/widgets/status_card.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

/// 建议 + 搜索都可控的假服务
class _SuggestFakeService extends FakeWeiyueService {
  @override
  Future<SearchSuggest> getSearchSuggest(String q) async => SearchSuggest(
        queries: ['$q联想词', '另一个联想'],
        users: [makeStatus().user!],
      );

  @override
  Future<SearchResult> search(String keyword, {int page = 1}) async =>
      SearchResult(
        statuses: [makeStatus(id: 's1', text: '搜索结果一')],
        users: const [],
      );
}

void main() {
  testWidgets('TopicScreen：标题 #话题# + 话题帖子流', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
          wrapWithProviders(const TopicScreen(topic: '测试话题')));
      await _settle(tester);
      expect(find.text('#测试话题#'), findsOneWidget);
      expect(find.textContaining('话题帖子一', findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('SearchScreen：输入防抖后出建议，点联想词直接搜索',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
          wrapWithProviders(const SearchScreen(), weibo: _SuggestFakeService()));
      await _settle(tester);

      await tester.enterText(find.byType(TextField), '测');
      await _settle(tester); // 等 300ms 防抖 + 拉取
      expect(find.text('测联想词'), findsOneWidget);
      expect(find.text('推荐用户'), findsOneWidget);
      // 推荐用户行即主页作者（makeStatus 的 user）
      expect(find.text('测试博主'), findsWidgets);

      await tester.tap(find.text('测联想词'));
      await _settle(tester);
      expect(find.textContaining('搜索结果一', findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('SearchScreen：清空输入后建议消失、回到历史/提示区',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
          wrapWithProviders(const SearchScreen(), weibo: _SuggestFakeService()));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '测');
      await _settle(tester);
      expect(find.text('测联想词'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await _settle(tester);
      expect(find.text('测联想词'), findsNothing);
      expect(find.text('输入关键词搜索动态与用户'), findsOneWidget);
    });
  });

  testWidgets('ProfileScreen：五页签，精选/文章可切换出内容', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester
          .pumpWidget(wrapWithProviders(const ProfileScreen(uid: '42')));
      await _settle(tester);
      for (final t in ['动态', '视频', '精选', '文章', '相册']) {
        expect(find.text(t), findsWidgets, reason: '页签 $t 应存在');
      }
      await tester.tap(find.text('精选'));
      await _settle(tester);
      expect(find.textContaining('精选帖子一', findRichText: true),
          findsOneWidget);
      await tester.tap(find.text('文章'));
      await _settle(tester);
      expect(find.textContaining('文章帖子一', findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('PlaylistScreen：合集标题 + 单集列表', (tester) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(wrapWithProviders(const PlaylistScreen(
        playlist: WbPlaylist(id: 'p1', name: '测试合集', itemCount: 36),
      )));
      await _settle(tester);
      expect(find.text('测试合集'), findsOneWidget);
      expect(find.textContaining('合集单集一', findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('buildWbTextSpans：表情短码变 WidgetSpan，未知短码保持文本',
      (tester) async {
    Emoticons.install(const {'[泪]': 'https://example.com/lei.png'});
    addTearDown(Emoticons.resetForTest);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    final spans = buildWbTextSpans(ctx, '好难过[泪]哦[不存在的]');
    expect(spans.whereType<WidgetSpan>().length, 1);
    final texts =
        spans.whereType<TextSpan>().map((s) => s.text ?? '').join();
    expect(texts, contains('[不存在的]'));
    expect(texts, isNot(contains('[泪]')));
  });

  testWidgets('WbRichText：映射就绪时正文渲染行内表情图', (tester) async {
    Emoticons.install(const {'[泪]': 'https://example.com/lei.png'});
    addTearDown(Emoticons.resetForTest);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
          wrapWithProviders(const WbRichText('好难过[泪]啊')));
      await _settle(tester);
      expect(find.byType(CachedNetworkImage), findsOneWidget);
    });
  });

  testWidgets('WbRichText：映射未就绪时短码保持原文、无图', (tester) async {
    Emoticons.resetForTest();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
          wrapWithProviders(const WbRichText('好难过[泪]啊')));
      await _settle(tester);
      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(find.textContaining('[泪]', findRichText: true), findsOneWidget);
    });
  });
}
