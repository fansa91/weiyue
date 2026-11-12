import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 计数版假 Visitor：ensure 直回固定身份，refresh 计数（同 service 测试惯例）。
class _CountingVisitor extends VisitorService {
  int refreshCalls = 0;
  static const _id = VisitorIdentity('VSUB', 'VSUBP', 1793000000000);

  @override
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async =>
      _id;

  @override
  Future<VisitorIdentity> refresh(WbStack stack) async {
    refreshCalls++;
    return _id;
  }
}

Dio _dio(FakeAdapter adapter) {
  final dio = Dio(BaseOptions(
    followRedirects: false,
    validateStatus: (s) => s != null && s < 500,
    responseType: ResponseType.json,
  ));
  dio.httpClientAdapter = adapter;
  return dio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 用指定 fixture 回放一类搜索，并断言请求的 type 值。
  Future<SearchCategoryPage> runCategory(
    SearchCategory cat,
    String fixture,
    int expectType,
  ) async {
    final visitor = _CountingVisitor();
    final body = File('test/fixtures/$fixture').readAsStringSync();
    final adapter = FakeAdapter((opt) async => jsonBody(body));
    final svc = WeiyueService(visitor, mDio: _dio(adapter));
    final page = await svc.searchCategory('新华社', cat);
    final q = adapter.requests.single.queryParameters;
    expect(adapter.requests.single.uri.path, '/api/container/getIndex');
    expect(q['containerid'], contains('100103type=$expectType&'));
    expect(q['containerid'], contains('q=%E6%96%B0%E5%8D%8E%E7%A4%BE'));
    expect(q['page_type'], 'searchall');
    return page;
  }

  test('实时(61)：纯微博卡按返回序解析', () async {
    final page =
        await runCategory(SearchCategory.realtime, 'm_search_realtime.json', 61);
    expect(page.statuses.map((s) => s.id),
        ['5364365324191250', '5364365227983039', '5364365206750645']);
    expect(page.users, isEmpty);
    expect(page.topics, isEmpty);
    expect(page.total, 888);
    expect(page.nextPage, 2);
  });

  test('用户(3)：card_type 10 完整用户对象', () async {
    final page =
        await runCategory(SearchCategory.users, 'm_search_user.json', 3);
    expect(page.users.map((u) => u.screenName), ['新华社', '新华社中国网事']);
    expect(page.users.first.id, greaterThan(0));
    expect(page.statuses, isEmpty);
    expect(page.total, 500);
    expect(page.nextPage, 2);
  });

  test('视频(64)：分组子卡与顶层微博卡映射为可播微博卡，专卡跳过', () async {
    final page =
        await runCategory(SearchCategory.video, 'm_search_video.json', 64);
    expect(page.statuses.map((s) => s.id),
        ['5361509656958619', '5362315908093142']);
    // 两条都被映射为视频帖（video 对象在）；样本裁剪时剥掉了
    // media_info.playback_list，故此处不断言 hasPlayable。
    expect(page.statuses.every((s) => s.video != null), isTrue);
    expect(page.total, 877);
    expect(page.nextPage, 2);
  });

  test('图片(63)：带图微博卡解析', () async {
    final page =
        await runCategory(SearchCategory.pics, 'm_search_pic.json', 63);
    expect(page.statuses.map((s) => s.id),
        ['5361458876778598', '5356733830529783', '5354242702574000']);
    expect(page.total, 912);
    expect(page.nextPage, 2);
  });

  test('话题(38)：card_type 8 条目（标题/简介/统计/封面/scheme）', () async {
    final page =
        await runCategory(SearchCategory.topic, 'm_search_topic.json', 38);
    expect(page.topics.length, 2);
    final first = page.topics.first;
    expect(first.title, '#新华社专访句号无言#');
    expect(first.desc1, '新华社专访句号无言');
    expect(first.desc2, contains('讨论'));
    expect(first.pic, startsWith('https://'));
    expect(first.scheme, contains('231522'));
    expect(page.statuses, isEmpty);
    expect(page.total, 500);
  });

  test('超话(98)：同为 card_type 8 条目，无 page 字段时 nextPage=0', () async {
    final page = await runCategory(
        SearchCategory.supertopic, 'm_search_supertopic.json', 98);
    expect(page.topics.map((t) => t.title), ['新华社皇亭子宿舍', '新华社宿舍']);
    // 第一条 scheme 在样本里被截断（字面以 … 结尾），第二条带完整容器
    expect(page.topics.last.scheme, contains('100808'));
    expect(page.total, 5);
    expect(page.nextPage, 0);
  });

  test('分页参数透传：page=2 原样带入请求', () async {
    final visitor = _CountingVisitor();
    final body =
        File('test/fixtures/m_search_realtime.json').readAsStringSync();
    final adapter = FakeAdapter((opt) async => jsonBody(body));
    final svc = WeiyueService(visitor, mDio: _dio(adapter));
    await svc.searchCategory('新华社', SearchCategory.realtime, page: 2);
    expect(adapter.requests.single.queryParameters['page'], 2);
  });
}
