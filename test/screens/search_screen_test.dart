import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/search_screen.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

class _SearchFakeService extends FakeWeiyueService {
  @override
  Future<SearchResult> search(String keyword, {int page = 1}) async =>
      SearchResult(
        statuses: [makeStatus(id: 's1', text: '搜索结果一')],
        users: const [],
      );
}

void main() {
  testWidgets('搜索历史：提交后写入并持久化，重进可见，单条可删，清空消失',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await mockNetworkImagesFor(() async {
      final fake = _SearchFakeService();

      // 首次进入：无历史，只显示输入提示
      await tester
          .pumpWidget(wrapWithProviders(const SearchScreen(), weibo: fake));
      await _settle(tester);
      expect(find.text('搜索历史'), findsNothing);
      expect(find.text('输入关键词搜索动态与用户'), findsOneWidget);

      // 输入并提交搜索
      await tester.enterText(find.byType(TextField), '测试词');
      await tester.tap(find.text('搜索'));
      await _settle(tester);
      expect(find.textContaining('搜索结果一', findRichText: true),
          findsOneWidget);

      // 已写入持久化（最新在前）
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('weiyue_search_history'), ['测试词']);

      // 重进页面：先卸载旧页面（同类型无 key 直接 pumpWidget 会复用旧 State，
      // 不是真正的重进），再挂新页面，历史词条应可见
      await tester.pumpWidget(const SizedBox());
      await tester
          .pumpWidget(wrapWithProviders(const SearchScreen(), weibo: fake));
      await _settle(tester);
      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.text('测试词'), findsOneWidget);
      await tester.tap(find.text('测试词'));
      await _settle(tester);
      expect(find.textContaining('搜索结果一', findRichText: true),
          findsOneWidget);

      // 再搜一个词：历史变为两条，新词在前
      await tester.enterText(find.byType(TextField), '第二词');
      await tester.tap(find.text('搜索'));
      await _settle(tester);
      expect(prefs.getStringList('weiyue_search_history'), ['第二词', '测试词']);

      // 重进：单条删除（点词条上的关闭图标删第一条）
      await tester.pumpWidget(const SizedBox());
      await tester
          .pumpWidget(wrapWithProviders(const SearchScreen(), weibo: fake));
      await _settle(tester);
      expect(find.text('第二词'), findsOneWidget);
      expect(find.text('测试词'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close).first);
      await _settle(tester);
      expect(find.text('第二词'), findsNothing);
      expect(find.text('测试词'), findsOneWidget);
      expect(prefs.getStringList('weiyue_search_history'), ['测试词']);

      // 清空：整段历史消失且持久化被移除
      await tester.tap(find.text('清空'));
      await _settle(tester);
      expect(find.text('搜索历史'), findsNothing);
      expect(find.text('测试词'), findsNothing);
      expect(prefs.getStringList('weiyue_search_history'), isNull);
    });
  });
}
