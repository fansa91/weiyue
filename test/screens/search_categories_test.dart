import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/search_screen.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// 分类可控假服务：记录每类请求次数；实时第一页给足条目可滚动，
/// 第 2 页抛非 JSON 异常（模拟访客态翻页 302 跳登录）。
class _CategoryFakeService extends FakeWeiyueService {
  final Map<SearchCategory, int> calls = {};

  @override
  Future<SearchCategoryPage> searchCategory(
    String keyword,
    SearchCategory category, {
    int page = 1,
  }) async {
    calls[category] = (calls[category] ?? 0) + 1;
    switch (category) {
      case SearchCategory.all:
        return SearchCategoryPage(
          statuses: [makeStatus(id: 'a1', text: '综合结果一')],
          nextPage: 2,
        );
      case SearchCategory.realtime:
        if (page > 1) {
          throw const WeiyueException('接口返回非 JSON（HTTP 200，网页标题：登录）');
        }
        return SearchCategoryPage(
          statuses: [
            for (var i = 1; i <= 20; i++)
              makeStatus(id: 'r$i', text: '实时结果第$i条'),
          ],
          total: 100,
          nextPage: 2,
        );
      case SearchCategory.users:
        return SearchCategoryPage(
          users: [makeStatus(id: 'x', authorName: '搜索用户甲').user!],
        );
      case SearchCategory.topic:
        return const SearchCategoryPage(
          topics: [
            WbTopicEntry(
              title: '#测试话题#',
              desc1: '测试话题',
              desc2: '10讨论 100阅读',
            ),
          ],
        );
      default:
        return const SearchCategoryPage();
    }
  }
}

Future<void> _search(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), '关键词');
  await tester.tap(find.text('搜索'));
  await _settle(tester);
}

void main() {
  testWidgets('分类各自请求：切分类各拉一次，切回不重拉', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await mockNetworkImagesFor(() async {
      final fake = _CategoryFakeService();
      await tester
          .pumpWidget(wrapWithProviders(const SearchScreen(), weibo: fake));
      await _settle(tester);

      await _search(tester);
      expect(find.textContaining('综合结果一', findRichText: true),
          findsOneWidget);
      expect(fake.calls[SearchCategory.all], 1);
      // 7 个分类 chips 都在
      for (final label in ['综合', '实时', '用户', '视频', '图片', '话题', '超话']) {
        expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
      }

      // 切实时：单独请求一次
      await tester.tap(find.widgetWithText(ChoiceChip, '实时'));
      await _settle(tester);
      expect(find.textContaining('实时结果第1条', findRichText: true),
          findsOneWidget);
      expect(fake.calls[SearchCategory.realtime], 1);

      // 切用户：单独请求一次
      await tester.tap(find.widgetWithText(ChoiceChip, '用户'));
      await _settle(tester);
      expect(find.text('搜索用户甲'), findsOneWidget);
      expect(fake.calls[SearchCategory.users], 1);

      // 切回综合与实时：不重拉，原内容还在
      await tester.tap(find.widgetWithText(ChoiceChip, '综合'));
      await _settle(tester);
      expect(find.textContaining('综合结果一', findRichText: true),
          findsOneWidget);
      expect(fake.calls[SearchCategory.all], 1);

      await tester.tap(find.widgetWithText(ChoiceChip, '实时'));
      await _settle(tester);
      expect(find.textContaining('实时结果第1条', findRichText: true),
          findsOneWidget);
      expect(fake.calls[SearchCategory.realtime], 1);
    });
  });

  testWidgets('专属分类翻页失败静默到底：不报错、不清列表', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await mockNetworkImagesFor(() async {
      final fake = _CategoryFakeService();
      await tester
          .pumpWidget(wrapWithProviders(const SearchScreen(), weibo: fake));
      await _settle(tester);
      await _search(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, '实时'));
      await _settle(tester);
      expect(fake.calls[SearchCategory.realtime], 1);

      // 连续上滑滚到底触发翻页 → 第 2 页抛错 → 静默结束
      for (var i = 0; i < 8; i++) {
        await tester.fling(
            find.byType(IndexedStack), const Offset(0, -600), 2000);
        await tester.pump(const Duration(milliseconds: 250));
      }
      await _settle(tester);
      expect(fake.calls[SearchCategory.realtime], 2);
      // 列表仍在、无错误 UI
      expect(find.textContaining('实时结果第20条', findRichText: true),
          findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(find.textContaining('非 JSON'), findsNothing);
    });
  });

  testWidgets('话题行渲染并点击进话题页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await mockNetworkImagesFor(() async {
      final fake = _CategoryFakeService();
      await tester
          .pumpWidget(wrapWithProviders(const SearchScreen(), weibo: fake));
      await _settle(tester);
      await _search(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, '话题'));
      await _settle(tester);
      expect(fake.calls[SearchCategory.topic], 1);
      expect(find.text('#测试话题#'), findsOneWidget);
      expect(find.text('10讨论 100阅读'), findsOneWidget);

      // 点话题行 → 进话题页（默认假服务的话题流）
      await tester.tap(find.text('#测试话题#'));
      await _settle(tester);
      expect(find.textContaining('话题帖子一', findRichText: true),
          findsOneWidget);
    });
  });
}
