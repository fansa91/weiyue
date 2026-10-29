import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 登录态三故障修复的服务层测试：
/// 1) PC 登录请求带 X-Xsrf-Token 头（缺失是真机 HTTP 400 非 JSON 的根因）；
/// 2) all_fav 解析加宽 + 带错误信息的空响应抛错；
/// 3) 登录诊断记录（探活快照 + 接口失败记录）。
/// Cookie 值均为假的合成串（FAKE_*）；登录态真实行为待用户真机验证。
class _Visitor extends VisitorService {
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
  final dio = Dio(
    BaseOptions(
      followRedirects: false,
      validateStatus: (s) => s != null && s < 500,
      responseType: ResponseType.json,
    ),
  );
  dio.httpClientAdapter = adapter;
  return dio;
}

Future<SessionService> _session({bool withXsrf = false}) async {
  final s = SessionService();
  await s.saveHarvest([
    const HarvestedCookie(
      name: 'SUB',
      value: 'FAKE_PC_SUB',
      domain: 'weibo.com',
    ),
    const HarvestedCookie(
      name: 'SUBP',
      value: 'FAKE_PC_SUBP',
      domain: 'weibo.com',
    ),
    if (withXsrf)
      const HarvestedCookie(
        name: 'XSRF-TOKEN',
        value: 'FAKE_XSRF_TOKEN',
        domain: 'weibo.com',
      ),
    const HarvestedCookie(
      name: 'SUB',
      value: 'FAKE_M_SUB',
      domain: 'm.weibo.cn',
    ),
  ]);
  return s;
}

String? _headerOf(RequestOptions opt, String name) {
  for (final e in opt.headers.entries) {
    if (e.key.toLowerCase() == name) return '${e.value}';
  }
  return null;
}

String _cookieOf(RequestOptions opt) => _headerOf(opt, 'cookie') ?? '';

ResponseBody _html400() => ResponseBody.fromString(
  '<html><body>Bad Request</body></html>',
  400,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
  },
);

const _channel = WbChannel(
  gid: '102803',
  title: '热门',
  containerid: '102803',
);

Map<String, dynamic> _statusJson(String id, String text) => {
  'id': id,
  'text_raw': text,
  'user': {'id': 1, 'screen_name': '某号'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('X-Xsrf-Token 头', () {
    test('PC 登录请求带 XSRF 头（值取自会话 Cookie）', () async {
      final session = await _session(withXsrf: true);
      final adapter = FakeAdapter(
        (opt) async => jsonBody({'ok': 1, 'statuses': [], 'max_id': 0}),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      await svc.getHotTimeline(_channel);
      final opt = adapter.requests.single;
      expect(_cookieOf(opt), contains('SUB=FAKE_PC_SUB'));
      expect(_headerOf(opt, 'x-xsrf-token'), 'FAKE_XSRF_TOKEN');
    });

    test('会话里没有 XSRF-TOKEN 时不带该头', () async {
      final session = await _session();
      final adapter = FakeAdapter(
        (opt) async => jsonBody({'ok': 1, 'statuses': [], 'max_id': 0}),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      await svc.getHotTimeline(_channel);
      expect(_headerOf(adapter.requests.single, 'x-xsrf-token'), isNull);
    });

    test('登录被拒回退访客后，访客请求不带 XSRF 头', () async {
      final session = await _session(withXsrf: true);
      final adapter = FakeAdapter((opt) async {
        if (_cookieOf(opt).contains('FAKE_PC_SUB')) {
          return jsonBody({'ok': -100, 'msg': 'need login'});
        }
        return jsonBody({'ok': 1, 'statuses': [], 'max_id': 0});
      });
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      await svc.getHotTimeline(_channel);
      expect(adapter.requests.length, 2);
      expect(_headerOf(adapter.requests[0], 'x-xsrf-token'), 'FAKE_XSRF_TOKEN');
      expect(_cookieOf(adapter.requests[1]), contains('SUB=VSUB'));
      expect(_headerOf(adapter.requests[1], 'x-xsrf-token'), isNull);
    });

    test('纯访客请求永不带 XSRF 头', () async {
      final adapter = FakeAdapter(
        (opt) async => jsonBody({'ok': 1, 'statuses': [], 'max_id': 0}),
      );
      final svc = WeiyueService(_Visitor(), pcDio: _dio(adapter));

      await svc.getHotTimeline(_channel);
      expect(_headerOf(adapter.requests.single, 'x-xsrf-token'), isNull);
    });

    test('m 栈登录请求不带 XSRF 头（只 PC 栈带）', () async {
      final session = await _session(withXsrf: true);
      final mAdapter = FakeAdapter(
        (opt) async => jsonBody({'ok': 1, 'data': {'data': []}}),
      );
      final svc = WeiyueService(
        _Visitor(),
        mDio: _dio(mAdapter),
        session: session,
      );

      await svc.getAttitudes('123');
      final opt = mAdapter.requests.single;
      expect(_cookieOf(opt), contains('SUB=FAKE_M_SUB'));
      expect(_headerOf(opt, 'x-xsrf-token'), isNull);
    });
  });

  group('getFavorites 解析加宽与错误可见', () {
    Future<WeiyueService> svcReturning(Object body) async {
      final session = await _session();
      final adapter = FakeAdapter((opt) async => jsonBody(body));
      return WeiyueService(_Visitor(), pcDio: _dio(adapter), session: session);
    }

    test('data 直接为数组', () async {
      final svc = await svcReturning({
        'ok': 1,
        'data': [_statusJson('51', '数组形态收藏一')],
      });
      final r = await svc.getFavorites();
      expect(r.items.single.text, '数组形态收藏一');
    });

    test('data.fav_list + fav 子对象解包', () async {
      final svc = await svcReturning({
        'ok': 1,
        'data': {
          'total_number': 1,
          'fav_list': [
            {'fav': _statusJson('52', 'fav_list 收藏一')},
          ],
        },
      });
      final r = await svc.getFavorites();
      expect(r.items.single.text, 'fav_list 收藏一');
      expect(r.total, 1);
    });

    test('data.statuses 形态 + mblog 子对象解包', () async {
      final svc = await svcReturning({
        'ok': 1,
        'data': {
          'statuses': [
            {'mblog': _statusJson('53', 'statuses 收藏一')},
          ],
        },
      });
      final r = await svc.getFavorites();
      expect(r.items.single.text, 'statuses 收藏一');
    });

    test('顶层 favorites 形态', () async {
      final svc = await svcReturning({
        'ok': 1,
        'favorites': [_statusJson('54', '顶层 favorites 收藏一')],
      });
      final r = await svc.getFavorites();
      expect(r.items.single.text, '顶层 favorites 收藏一');
    });

    test('ok=0 带 msg 的空响应 → 抛出该消息（不再静默空列表）', () async {
      final svc = await svcReturning({'ok': 0, 'msg': 'FAKE 收藏接口错误'});
      await expectLater(
        svc.getFavorites(),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('FAKE 收藏接口错误'),
          ),
        ),
      );
    });

    test('data 内带 msg 的空响应 → 抛出该消息', () async {
      final svc = await svcReturning({
        'ok': 1,
        'data': {'list': [], 'msg': 'FAKE 数据层错误'},
      });
      await expectLater(
        svc.getFavorites(),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('FAKE 数据层错误'),
          ),
        ),
      );
    });

    test('真空收藏（无错误信息）→ 空列表不抛错', () async {
      final svc = await svcReturning({
        'ok': 1,
        'data': {'list': [], 'total_number': 0},
      });
      final r = await svc.getFavorites();
      expect(r.items, isEmpty);
      expect(r.total, 0);
    });
  });

  group('登录诊断记录', () {
    test('hasXsrfToken：passport 域的同名 Cookie 不算', () async {
      final s = SessionService();
      await s.saveHarvest(const [
        HarvestedCookie(
          name: 'XSRF-TOKEN',
          value: 'FAKE_PASSPORT_XSRF',
          domain: 'passport.weibo.com',
        ),
      ]);
      expect(s.hasXsrfToken, isFalse);
      await s.saveHarvest(const [
        HarvestedCookie(
          name: 'XSRF-TOKEN',
          value: 'FAKE_XSRF_TOKEN',
          domain: 'weibo.com',
        ),
      ]);
      expect(s.hasXsrfToken, isTrue);
      expect(s.xsrfToken(), 'FAKE_XSRF_TOKEN');
    });

    test('recordProbeResult / recordLoginFailure：快照、去重、上限 5 条', () async {
      final s = await _session(withXsrf: true);
      s.recordProbeResult(pcUnlocked: false, mUnlocked: true, hasUid: false);
      final diag = s.lastProbeDiagnostic;
      expect(diag, isNotNull);
      expect(diag!.pcUnlocked, isFalse);
      expect(diag.mUnlocked, isTrue);
      expect(diag.hasUid, isFalse);
      expect(diag.hasXsrf, isTrue);
      expect(diag.timeMs, greaterThan(0));

      s.recordLoginFailure('/ajax/friendships/friends', '接口返回非 JSON（HTTP 400）');
      s.recordLoginFailure('/ajax/friendships/friends', '接口返回非 JSON（HTTP 400）');
      expect(s.recentLoginFailures.length, 1);
      for (var i = 0; i < 7; i++) {
        s.recordLoginFailure('/ajax/test/$i', '错误 $i');
      }
      expect(s.recentLoginFailures.length, 5);
      expect(s.recentLoginFailures.first.endpoint, '/ajax/test/6');
    });

    test('诊断可持久化读回，退出登录后清除', () async {
      final s = await _session(withXsrf: true);
      s.recordProbeResult(pcUnlocked: true, mUnlocked: false, hasUid: true);
      s.recordLoginFailure('/ajax/favorites/all_fav', 'FAKE 错误');
      // _persistDiag 是异步落盘，给它几个微任务回合
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final restored = SessionService();
      await restored.init();
      expect(restored.lastProbeDiagnostic?.pcUnlocked, isTrue);
      expect(restored.lastProbeDiagnostic?.hasUid, isTrue);
      expect(
        restored.recentLoginFailures.single.endpoint,
        '/ajax/favorites/all_fav',
      );

      await restored.clear();
      expect(restored.lastProbeDiagnostic, isNull);
      expect(restored.recentLoginFailures, isEmpty);
    });

    test('probeSession 全 400 非 JSON：写入失败记录与探活快照（真机故障复现）', () async {
      final session = await _session(withXsrf: true);
      final pcAdapter = FakeAdapter((opt) async => _html400());
      final mAdapter = FakeAdapter(
        (opt) async => jsonBody({'ok': -100, 'msg': 'blocked'}),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(pcAdapter),
        mDio: _dio(mAdapter),
        session: session,
      );

      final probe = await svc.probeSession();
      expect(probe.pcUnlocked, isFalse);
      expect(probe.mUnlocked, isFalse);

      final diag = session.lastProbeDiagnostic;
      expect(diag, isNotNull);
      expect(diag!.pcUnlocked, isFalse);
      expect(diag.hasUid, isFalse);
      expect(diag.hasXsrf, isTrue);

      final basic = session.recentLoginFailures.where(
        (f) => f.endpoint == '/ajax/setting/getBasicInfo',
      );
      expect(basic, isNotEmpty);
      expect(basic.first.message, contains('接口返回非 JSON（HTTP 400）'));
      expect(
        session.recentLoginFailures.map((f) => f.endpoint),
        contains('/ajax/feed/friendstimeline'),
      );
    });

    test('getMyFollowing 失败写入诊断（400 非 JSON）', () async {
      final session = await _session();
      final adapter = FakeAdapter((opt) async => _html400());
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      await expectLater(
        svc.getMyFollowing('777'),
        throwsA(isA<WeiyueException>()),
      );
      expect(
        session.recentLoginFailures.first.endpoint,
        '/ajax/friendships/friends',
      );
      expect(
        session.recentLoginFailures.first.message,
        contains('接口返回非 JSON（HTTP 400）'),
      );
    });

    test('getMyProfile 失败写入诊断', () async {
      final session = await _session();
      final adapter = FakeAdapter((opt) async => _html400());
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      await expectLater(svc.getMyProfile('777'), throwsA(isA<WeiyueException>()));
      expect(session.recentLoginFailures.first.endpoint, '/ajax/profile/info');
    });
  });
}
