import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 互动写操作（_post 通道）的服务层测试：
/// - 写请求只许登录态：无会话/无 XSRF 令牌都在本地拦截，一个请求都不发；
/// - PC 栈 POST 带 X-Xsrf-Token 头 + 表单编码 + 登录 Cookie；
/// - 五个动作的路径与表单参数组装（路径依据 WEIBO_API.md 写接口清单）；
/// - 服务端报错（ok=0 的 msg、error 字段、400 非 JSON）原样抛给 UI，
///   并记入登录诊断。
/// Cookie/令牌均为假的合成串（FAKE_*）；登录态真实行为待用户真机验证。
class _Visitor extends VisitorService {
  static const _id = VisitorIdentity('VSUB', 'VSUBP', 1793000000000);

  @override
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async =>
      _id;

  @override
  Future<VisitorIdentity> refresh(WbStack stack) async => _id;
}

/// 记录请求 + 请求体（表单编码后的原文）的假 adapter。
class _CaptureAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<String> bodies = [];
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _CaptureAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    var body = '';
    if (requestStream != null) {
      final bytes = await requestStream.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      body = utf8.decode(bytes);
    }
    bodies.add(body);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

Dio _dio(_CaptureAdapter adapter) {
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

Future<SessionService> _session({bool withXsrf = true}) async {
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
  ]);
  return s;
}

String? _headerOf(RequestOptions opt, String name) {
  for (final e in opt.headers.entries) {
    if (e.key.toLowerCase() == name) return '${e.value}';
  }
  return null;
}

Map<String, String> _formOf(String body) => Uri.splitQueryString(body);

ResponseBody _html400() => ResponseBody.fromString(
  '<html><body>Bad Request</body></html>',
  400,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('_post 登录态拦截（不发请求）', () {
    test('无登录会话：抛「请先登录」，adapter 零请求', () async {
      final adapter = _CaptureAdapter((opt) async => jsonBody({'ok': 1}));
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: SessionService(),
      );
      await expectLater(
        svc.likeStatus('1001'),
        throwsA(
          isA<WeiyueException>().having((e) => e.message, 'message', '请先登录'),
        ),
      );
      expect(adapter.requests, isEmpty);
    });

    test('有会话无 XSRF 令牌：抛令牌提示，adapter 零请求', () async {
      final adapter = _CaptureAdapter((opt) async => jsonBody({'ok': 1}));
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: await _session(withXsrf: false),
      );
      await expectLater(
        svc.followUser('42'),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('XSRF'),
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });
  });

  group('_post 请求形态', () {
    test('setLike：POST + 表单编码 + XSRF 头 + 登录 Cookie', () async {
      final adapter = _CaptureAdapter((opt) async => jsonBody({'ok': 1}));
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: await _session(),
      );
      await svc.likeStatus('1001');
      final opt = adapter.requests.single;
      expect(opt.method, 'POST');
      expect(opt.uri.path, '/ajax/statuses/setLike');
      expect(
        _headerOf(opt, 'content-type'),
        startsWith('application/x-www-form-urlencoded'),
      );
      expect(_headerOf(opt, 'x-xsrf-token'), 'FAKE_XSRF_TOKEN');
      expect(_headerOf(opt, 'cookie'), contains('SUB=FAKE_PC_SUB'));
      expect(_headerOf(opt, 'referer'), 'https://weibo.com/detail/1001');
      expect(_formOf(adapter.bodies.single), {'id': '1001'});
    });

    test('无 ok 字段的 200 JSON 也算成功（宽容判据）', () async {
      final adapter = _CaptureAdapter((opt) async => jsonBody({'id': 'x'}));
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: await _session(),
      );
      await svc.likeStatus('1001'); // 不抛即通过
      expect(adapter.requests, hasLength(1));
    });
  });

  group('五个动作的路径与参数', () {
    Future<(_CaptureAdapter, WeiyueService)> rig({
      Object body = const {'ok': 1},
    }) async {
      final adapter = _CaptureAdapter((opt) async => jsonBody(body));
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: await _session(),
      );
      return (adapter, svc);
    }

    test('取消点赞 cancelLike', () async {
      final (adapter, svc) = await rig();
      await svc.unlikeStatus('1001');
      expect(adapter.requests.single.uri.path, '/ajax/statuses/cancelLike');
      expect(_formOf(adapter.bodies.single), {'id': '1001'});
    });

    test('发评论 comments/create，顶层评论对象可解析', () async {
      final (adapter, svc) = await rig(
        body: {
          'ok': 1,
          'id': 'c900',
          'text': '评论正文',
          'user': {'id': 7, 'screen_name': '评论者'},
        },
      );
      final created = await svc.createComment('1001', '评论正文');
      expect(adapter.requests.single.uri.path, '/ajax/comments/create');
      expect(_formOf(adapter.bodies.single), {
        'id': '1001',
        'comment': '评论正文',
      });
      expect(created?.id, 'c900');
      expect(created?.text, '评论正文');
    });

    test('发评论：data 包裹形态也可解析', () async {
      final (_, svc) = await rig(
        body: {
          'ok': 1,
          'data': {'id': 'c901', 'text': 'data 里的评论'},
        },
      );
      final created = await svc.createComment('1001', 'data 里的评论');
      expect(created?.id, 'c901');
    });

    test('发评论：响应不带评论对象时返回 null（调用方刷新列表为准）', () async {
      final (_, svc) = await rig();
      expect(await svc.createComment('1001', 'x'), isNull);
    });

    test('回复评论 comments/reply 带 cid+id+comment', () async {
      final (adapter, svc) = await rig();
      await svc.replyComment(statusId: '1001', commentId: 'c55', text: '回复你');
      expect(adapter.requests.single.uri.path, '/ajax/comments/reply');
      expect(_formOf(adapter.bodies.single), {
        'cid': 'c55',
        'id': '1001',
        'comment': '回复你',
      });
    });

    test('转发 statuses/repost 带 id+comment（可空语）', () async {
      final (adapter, svc) = await rig();
      await svc.repostStatus('1001', comment: '转一个');
      expect(adapter.requests.single.uri.path, '/ajax/statuses/repost');
      expect(_formOf(adapter.bodies.single), {
        'id': '1001',
        'comment': '转一个',
      });
      await svc.repostStatus('1001');
      expect(_formOf(adapter.bodies.last), {'id': '1001', 'comment': ''});
    });

    test('收藏 favorites/create（推测路径，收敛单点）', () async {
      final (adapter, svc) = await rig();
      await svc.createFavorite('1001');
      expect(adapter.requests.single.uri.path, '/ajax/favorites/create');
      expect(_formOf(adapter.bodies.single), {'id': '1001'});
    });

    test('取消收藏 statuses/destoryFavorites（文档原文拼写）', () async {
      final (adapter, svc) = await rig();
      await svc.destroyFavorite('1001');
      expect(
        adapter.requests.single.uri.path,
        '/ajax/statuses/destoryFavorites',
      );
      expect(_formOf(adapter.bodies.single), {'id': '1001'});
    });

    test('关注 friendships/create 同发 friend_id 与 uid', () async {
      final (adapter, svc) = await rig();
      await svc.followUser('42');
      expect(adapter.requests.single.uri.path, '/ajax/friendships/create');
      expect(_formOf(adapter.bodies.single), {'friend_id': '42', 'uid': '42'});
      expect(
        _headerOf(adapter.requests.single, 'referer'),
        'https://weibo.com/u/42',
      );
    });

    test('取关 friendships/destory（文档原文拼写）', () async {
      final (adapter, svc) = await rig();
      await svc.unfollowUser('42');
      expect(adapter.requests.single.uri.path, '/ajax/friendships/destory');
      expect(_formOf(adapter.bodies.single), {'friend_id': '42', 'uid': '42'});
    });
  });

  group('服务端报错解析与诊断记录', () {
    test('ok=0 带 msg：抛该 msg 并记入诊断', () async {
      final session = await _session();
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({'ok': 0, 'msg': 'FAKE 不能重复点赞'}),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );
      await expectLater(
        svc.likeStatus('1001'),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            'FAKE 不能重复点赞',
          ),
        ),
      );
      expect(
        session.recentLoginFailures.first.endpoint,
        '/ajax/statuses/setLike',
      );
      expect(session.recentLoginFailures.first.message, 'FAKE 不能重复点赞');
    });

    test('error 字段形态：抛 error 文案', () async {
      final adapter = _CaptureAdapter(
        (opt) async =>
            jsonBody({'error': 'FAKE 操作过于频繁', 'error_code': 100001}),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: await _session(),
      );
      await expectLater(
        svc.createComment('1001', 'x'),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('FAKE 操作过于频繁'),
          ),
        ),
      );
    });

    test('400 非 JSON：抛「接口返回非 JSON（HTTP 400）」', () async {
      final adapter = _CaptureAdapter((opt) async => _html400());
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: await _session(),
      );
      await expectLater(
        svc.repostStatus('1001'),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            '接口返回非 JSON（HTTP 400）',
          ),
        ),
      );
    });

    test('ok=-100 未登录信号：标记过期并抛重新登录提示', () async {
      final session = await _session();
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({'ok': -100, 'msg': 'need login'}),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );
      await expectLater(
        svc.likeStatus('1001'),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('重新登录'),
          ),
        ),
      );
      expect(session.expired, isTrue);
    });
  });
}
