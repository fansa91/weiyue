import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weibo/services/visitor_service.dart';

import '../helpers/fakes.dart';

const _genBody =
    'gen_callback({"retcode":20000000,"msg":"succ","data":{"tid":"TID1234567890abcdef","new_tid":false}})';
const _incBody =
    'cross_domain({"retcode":20000000,"data":{"sub":"SUBVALUE123","subp":"SUBPVALUE456"}})';

Dio _visitorDio(FakeAdapter adapter) {
  final dio = Dio(BaseOptions(
    followRedirects: false,
    validateStatus: (s) => s != null && s < 400,
    responseType: ResponseType.plain,
  ));
  dio.httpClientAdapter = adapter;
  return dio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ensure: genvisitor→incarnate 顺序/URL 正确，SUB 存入 SharedPreferences',
      () async {
    SharedPreferences.setMockInitialValues({});
    final adapter = FakeAdapter((opt) async {
      if (opt.uri.path.contains('genvisitor')) return jsonBody(_genBody);
      if (opt.uri.path.contains('/visitor/visitor')) return jsonBody(_incBody);
      throw StateError('未知请求 ${opt.uri}');
    });
    final svc = VisitorService(dio: _visitorDio(adapter));

    final id = await svc.ensure(WbStack.pc);

    expect(id.sub, 'SUBVALUE123');
    expect(id.subp, 'SUBPVALUE456');
    // 两次请求、顺序正确
    expect(adapter.requests.length, 2);
    final gen = adapter.requests[0];
    expect(gen.uri.host, 'passport.weibo.com');
    expect(gen.uri.path, '/visitor/genvisitor');
    expect(gen.method, 'POST');
    expect('${gen.data}', contains('cb=gen_callback'));
    expect('${gen.data}', contains('fp=')); // 指纹 JSON 在 form 里
    final inc = adapter.requests[1];
    expect(inc.uri.path, '/visitor/visitor');
    expect(inc.uri.queryParameters['a'], 'incarnate');
    expect(inc.uri.queryParameters['t'], 'TID1234567890abcdef');
    // 已落盘
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('visitor_pc_sub'), 'SUBVALUE123');
    expect(prefs.getString('visitor_pc_subp'), 'SUBPVALUE456');
    expect(prefs.getInt('visitor_pc_ts'), isNotNull);
    // 身份字段可拼出 Cookie（WeiboService 实际拼接方式）
    expect('SUB=${id.sub}; SUBP=${id.subp}',
        'SUB=SUBVALUE123; SUBP=SUBPVALUE456');
  });

  test('ensure: 已有未过期 SUB 时不发请求', () async {
    SharedPreferences.setMockInitialValues({
      'visitor_m_sub': 'CACHEDSUB',
      'visitor_m_subp': 'CACHEDSUBP',
      'visitor_m_ts': DateTime.now().millisecondsSinceEpoch,
    });
    final adapter = FakeAdapter((opt) async {
      throw StateError('不应发请求: ${opt.uri}');
    });
    final svc = VisitorService(dio: _visitorDio(adapter));

    final id = await svc.ensure(WbStack.m);
    expect(id.sub, 'CACHEDSUB');
    expect(adapter.requests, isEmpty);
  });

  test('m 栈走 visitor.passport.weibo.cn', () async {
    SharedPreferences.setMockInitialValues({});
    final adapter = FakeAdapter((opt) async {
      if (opt.uri.path.contains('genvisitor')) return jsonBody(_genBody);
      return jsonBody(_incBody);
    });
    final svc = VisitorService(dio: _visitorDio(adapter));
    await svc.ensure(WbStack.m);
    expect(adapter.requests[0].uri.host, 'visitor.passport.weibo.cn');
    expect(
      adapter.requests[0].headers.values
          .any((v) => '$v'.contains('Mobile')),
      isTrue,
      reason: 'm 栈 UA 应为移动端',
    );
  });

  test('genvisitor 异常响应抛错', () async {
    SharedPreferences.setMockInitialValues({});
    final adapter = FakeAdapter((opt) async => jsonBody('{"error":1}'));
    final svc = VisitorService(dio: _visitorDio(adapter));
    await expectLater(svc.ensure(WbStack.pc), throwsStateError);
  });
}
