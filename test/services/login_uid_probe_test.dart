import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 登录态第二轮修复的服务层测试（依据 v0.1.8 真机诊断实证）：
/// 1) 本人 uid 改走桌面首页内嵌配置提取（无参/空参接口必 400 的总闸）；
/// 2) getMyProfile/getMyFollowing 空 uid 本地拦截，不发空参请求；
/// 3) XSRF-TOKEN 收割分桶键与查找键的真实组合覆盖。
/// Cookie/令牌均为假的合成串（FAKE_*）；登录态真实行为待用户真机验证。
class _Visitor extends VisitorService {
  static const _id = VisitorIdentity('VSUB', 'VSUBP', 1793000000000);

  @override
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async =>
      _id;

  @override
  Future<VisitorIdentity> refresh(WbStack stack) async => _id;
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

Future<SessionService> _session() async {
  final s = SessionService();
  await s.saveHarvest(const [
    HarvestedCookie(name: 'SUB', value: 'FAKE_PC_SUB', domain: 'weibo.com'),
    HarvestedCookie(name: 'SUBP', value: 'FAKE_PC_SUBP', domain: 'weibo.com'),
    HarvestedCookie(name: 'SUB', value: 'FAKE_M_SUB', domain: 'm.weibo.cn'),
  ]);
  return s;
}

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

ResponseBody _html(String body, {Map<String, List<String>> extra = const {}}) {
  return ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      ...extra,
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('extractSelfUidFromHomepage', () {
    test(r"$CONFIG['uid']='…' 赋值式优先于页面后部的他人 uid", () {
      final html = '''
<html><head><script>
var \$CONFIG = {};
\$CONFIG['islogin'] = '1';
\$CONFIG['uid'] = '123456';
\$CONFIG['nick'] = '本人';
</script></head>
<body><script>var feed = {"uid":"999999","text":"别人的帖子"};</script></body></html>
''';
      expect(WeiyueService.extractSelfUidFromHomepage(html), '123456');
    });

    test(r'"uid":"…" 键值式（$CONFIG 对象内），段外干扰不影响', () {
      final html = '''
<html><head><script>var other = {"uid":"111111"};</script>
<script>window.\$CONFIG = {"uid":"654321","nick":"本人","islogin":1};</script>
</head><body></body></html>
''';
      expect(WeiyueService.extractSelfUidFromHomepage(html), '654321');
    });

    test('无 \$CONFIG 时退到全文第一个 "uid" 键（无引号数值形态）', () {
      final html =
          '<html><body><script>var s = {"uid":246810};</script></body></html>';
      expect(WeiyueService.extractSelfUidFromHomepage(html), '246810');
    });

    test('未登录首页（uid 为空串）→ null', () {
      final html = '''
<script>var \$CONFIG = {};
\$CONFIG['uid'] = '';
\$CONFIG['islogin'] = '0';</script>
''';
      expect(WeiyueService.extractSelfUidFromHomepage(html), isNull);
    });

    test('完全没有 uid → null 不崩', () {
      expect(
        WeiyueService.extractSelfUidFromHomepage(
          '<html><body>hi</body></html>',
        ),
        isNull,
      );
      expect(WeiyueService.extractSelfUidFromHomepage(''), isNull);
    });
  });

  group('probeSession 首页主路径', () {
    test('提取 uid → profile/info?uid= 拿到用户，两栈解锁，快照与 XSRF 落盘', () async {
      final session = await _session();
      final homeHtml = '''
<html><head><script>
var \$CONFIG = {};
\$CONFIG['uid'] = '777777';
</script></head><body></body></html>
''';
      final pcAdapter = FakeAdapter((opt) async {
        switch (opt.uri.path) {
          case '/':
            return _html(
              homeHtml,
              extra: {
                'set-cookie': [
                  'XSRF-TOKEN=FAKE_XSRF_FROM_HOME; Path=/; Domain=.weibo.com',
                ],
              },
            );
          case '/ajax/profile/info':
            return jsonBody(_fixture('my_profile_info.json'));
          case '/ajax/profile/detail':
            return jsonBody(_fixture('my_profile_detail.json'));
          default:
            return jsonBody({'ok': 1});
        }
      });
      final mAdapter = FakeAdapter(
        (opt) async => jsonBody({'ok': 1, 'data': []}),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(pcAdapter),
        mDio: _dio(mAdapter),
        session: session,
      );

      final startedAt = DateTime.now().millisecondsSinceEpoch;
      final probe = await svc.probeSession();

      expect(probe.user?.id, 777);
      expect(probe.user?.screenName, '构造测试本人');
      expect(probe.pcUnlocked, isTrue);
      expect(probe.mUnlocked, isTrue);

      // 请求序列：首页在最前，其后紧跟带 uid 的 profile/info；
      // 主路径成功后不再走 getBasicInfo 兜底
      final paths = pcAdapter.requests.map((r) => r.uri.path).toList();
      expect(paths.first, '/');
      expect(paths[1], '/ajax/profile/info');
      expect(pcAdapter.requests[1].queryParameters['uid'], '777777');
      expect(paths, isNot(contains('/ajax/setting/getBasicInfo')));

      // 首页 Set-Cookie 的 XSRF-TOKEN 已存入会话（页面响应下发的那份）
      expect(session.xsrfToken(), 'FAKE_XSRF_FROM_HOME');
      expect(session.hasXsrfToken, isTrue);

      // 完整资料已补拉存入会话
      expect(session.profile?.id, 777);
      expect(session.profile?.screenName, '构造测试本人');

      // 诊断快照：本次探活刚写、uid/xsrf 均有
      final diag = session.lastProbeDiagnostic;
      expect(diag, isNotNull);
      expect(diag!.timeMs, greaterThanOrEqualTo(startedAt));
      expect(diag.hasUid, isTrue);
      expect(diag.hasXsrf, isTrue);
      expect(diag.pcUnlocked, isTrue);
    });

    test('首页抓取异常时兜底链照常跑，快照仍刷新（finally）', () async {
      final session = await _session();
      final pcAdapter = FakeAdapter((opt) async {
        switch (opt.uri.path) {
          case '/':
            throw StateError('FAKE 首页抓取爆炸');
          case '/ajax/setting/getBasicInfo':
            return jsonBody({'ok': 1, 'data': {}});
          case '/ajax/profile/info':
            return jsonBody({'ok': -100, 'msg': 'need login'});
          case '/ajax/feed/friendstimeline':
            return jsonBody(_fixture('friends_timeline.json'));
          default:
            return jsonBody({'ok': 1});
        }
      });
      final mAdapter = FakeAdapter(
        (opt) async => jsonBody({'ok': -100, 'msg': 'blocked'}),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(pcAdapter),
        mDio: _dio(mAdapter),
        session: session,
      );

      final startedAt = DateTime.now().millisecondsSinceEpoch;
      final probe = await svc.probeSession();
      expect(probe.user, isNull);
      expect(probe.pcUnlocked, isTrue); // friendstimeline 兜底
      expect(probe.mUnlocked, isFalse);

      final diag = session.lastProbeDiagnostic;
      expect(diag, isNotNull);
      expect(diag!.timeMs, greaterThanOrEqualTo(startedAt));
      expect(diag.pcUnlocked, isTrue);
      // 首页失败留有记录，便于下次截图定位
      expect(
        session.recentLoginFailures.map((f) => f.endpoint),
        contains('weibo.com 首页'),
      );
    });
  });

  group('空 uid 防护', () {
    test('getMyProfile(\'\') 抛可读异常且不发任何请求', () async {
      final session = await _session();
      final adapter = FakeAdapter((opt) async => jsonBody({'ok': 1}));
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      await expectLater(
        svc.getMyProfile(''),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('缺少用户 ID'),
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
      // 本地拦截不记服务端失败记录
      expect(session.recentLoginFailures, isEmpty);
    });

    test('getMyFollowing(\' \') 同样拦截（空白也算空）', () async {
      final session = await _session();
      final adapter = FakeAdapter((opt) async => jsonBody({'ok': 1}));
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      await expectLater(
        svc.getMyFollowing('  '),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('缺少用户 ID'),
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
      expect(session.recentLoginFailures, isEmpty);
    });
  });

  group('XSRF 分桶键排查（收割存入键 vs xsrfToken 查找键）', () {
    // 收割侧：LoginScreen 用 CookieManager 返回的 domain（常带前导点）
    // 经 SessionService.normalizeDomain 归一化后存入；
    // 查找侧：xsrfToken() 跳过 passport 域、按 weibo.com 后缀匹配分桶。
    // 以下组合逐个验证两边口径一致。
    test('前导点域名 .weibo.com（CookieManager 原始形态）可查到', () async {
      final s = SessionService();
      await s.saveHarvest(const [
        HarvestedCookie(name: 'SUB', value: 'FAKE_SUB', domain: '.weibo.com'),
        HarvestedCookie(
          name: 'XSRF-TOKEN',
          value: 'FAKE_XSRF_DOTTED',
          domain: '.weibo.com',
        ),
      ]);
      expect(s.xsrfToken(), 'FAKE_XSRF_DOTTED');
    });

    test('www.weibo.com 子域分桶可查到', () async {
      final s = SessionService();
      await s.saveHarvest(const [
        HarvestedCookie(name: 'SUB', value: 'FAKE_SUB', domain: 'weibo.com'),
        HarvestedCookie(
          name: 'XSRF-TOKEN',
          value: 'FAKE_XSRF_WWW',
          domain: 'www.weibo.com',
        ),
      ]);
      expect(s.xsrfToken(), 'FAKE_XSRF_WWW');
    });

    test('api.weibo.com 子域分桶可查到，大写域名也归一化', () async {
      final s = SessionService();
      await s.saveHarvest(const [
        HarvestedCookie(name: 'SUB', value: 'FAKE_SUB', domain: 'WEIBO.COM'),
        HarvestedCookie(
          name: 'XSRF-TOKEN',
          value: 'FAKE_XSRF_API',
          domain: 'API.Weibo.com',
        ),
      ]);
      expect(s.xsrfToken(), 'FAKE_XSRF_API');
    });

    test('只在 passport 域与 sina 域时查不到（排除口径不变）', () async {
      final s = SessionService();
      await s.saveHarvest(const [
        HarvestedCookie(name: 'SUB', value: 'FAKE_SUB', domain: 'weibo.com'),
        HarvestedCookie(
          name: 'XSRF-TOKEN',
          value: 'FAKE_XSRF_PASSPORT',
          domain: 'passport.weibo.com',
        ),
        HarvestedCookie(
          name: 'XSRF-TOKEN',
          value: 'FAKE_XSRF_SINA',
          domain: 'sina.com.cn',
        ),
      ]);
      expect(s.hasXsrfToken, isFalse);
      expect(s.xsrfToken(), isNull);
    });
  });
}
