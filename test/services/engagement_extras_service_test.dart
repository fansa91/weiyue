import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 本批新增接口的服务层测试（2026-11-12，路径/参数均为主包
/// pc_index.js 调用点实证，见 WEIBO_API.md 对应小节）：
/// - 我赞过的 getLikeList：游标分页解析；
/// - 评论点赞 updateLike/destroyLike：表单 {object_id, object_type}；
/// - 关注分组 getFollowGroups：allGroups 段解析（全部关注过滤）；
/// - 分组时间线：系统分组/自定义分组的路径与参数分流；
/// - 屏蔽/拉黑 filterUser：表单三开关。
/// Cookie 均为假串；登录态真实行为待用户真机验证。
String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

class _Visitor extends VisitorService {
  static const _id = VisitorIdentity('VSUB', 'VSUBP', 1793000000000);

  @override
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async =>
      _id;

  @override
  Future<VisitorIdentity> refresh(WbStack stack) async => _id;
}

/// 记录请求 + 表单原文的假 adapter。
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

Future<SessionService> _sessionWithCookies() async {
  final s = SessionService();
  await s.saveHarvest(const [
    HarvestedCookie(name: 'SUB', value: 'FAKE_PC_SUB', domain: 'weibo.com'),
    HarvestedCookie(
      name: 'XSRF-TOKEN',
      value: 'FAKE_XSRF',
      domain: 'weibo.com',
    ),
  ]);
  return s;
}

Future<WeiyueService> _svc(_CaptureAdapter adapter) async {
  final session = await _sessionWithCookies();
  return WeiyueService(
    _Visitor(),
    pcDio: _dio(adapter),
    mDio: _dio(adapter),
    session: session,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('我赞过的 getLikeList', () {
    test('路径/参数与响应解析：uid+cursor、list、next_cursor', () async {
      final adapter = _CaptureAdapter(
        (opt) async => ResponseBody.fromString(
          _fixture('like_list.json'),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        ),
      );
      final svc = await _svc(adapter);
      final r = await svc.getLikeList('1641537045');
      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.path, endsWith('/ajax/profile/getLikeList'));
      expect(req.queryParameters['uid'], '1641537045');
      expect(req.queryParameters['cursor'], 0);
      expect(r.items.map((s) => s.id), [
        '5359000000000111',
        '5359000000000112',
      ]);
      expect(r.items.first.text, contains('我赞过的帖子一'));
      expect(r.nextCursor, 987654321);
    });

    test('next_cursor=-1 表示到底，原样回传', () async {
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({
          'ok': 1,
          'data': {'list': [], 'next_cursor': -1},
        }),
      );
      final svc = await _svc(adapter);
      final r = await svc.getLikeList('1641537045', cursor: 987654321);
      expect(r.items, isEmpty);
      expect(r.nextCursor, -1);
      expect(adapter.requests.single.queryParameters['cursor'], 987654321);
    });

    test('uid 为空不发请求直接抛错', () async {
      final adapter = _CaptureAdapter((opt) async => jsonBody({'ok': 1}));
      final svc = await _svc(adapter);
      await expectLater(
        svc.getLikeList(''),
        throwsA(isA<WeiyueException>()),
      );
      expect(adapter.requests, isEmpty);
    });

    test('ok=0 带 msg 时空列表也抛服务端文案', () async {
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({'ok': 0, 'msg': '赞列表不可见（构造）'}),
      );
      final svc = await _svc(adapter);
      await expectLater(
        svc.getLikeList('1641537045'),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('赞列表不可见'),
          ),
        ),
      );
    });
  });

  group('评论点赞 updateLike/destroyLike', () {
    test('点赞：路径与表单 {object_id, object_type: comment}', () async {
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({'ok': 1, 'data': {}}),
      );
      final svc = await _svc(adapter);
      await svc.likeComment('5200000000000001');
      final req = adapter.requests.single;
      expect(req.method, 'POST');
      expect(req.path, endsWith('/ajax/statuses/updateLike'));
      expect(adapter.bodies.single, contains('object_id=5200000000000001'));
      expect(adapter.bodies.single, contains('object_type=comment'));
    });

    test('取消赞：destroyLike 同表单', () async {
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({'ok': 1, 'data': {}}),
      );
      final svc = await _svc(adapter);
      await svc.unlikeComment('5200000000000001');
      expect(
        adapter.requests.single.path,
        endsWith('/ajax/statuses/destroyLike'),
      );
      expect(adapter.bodies.single, contains('object_id=5200000000000001'));
      expect(adapter.bodies.single, contains('object_type=comment'));
    });
  });

  group('关注分组 getFollowGroups', () {
    test('allGroups 段解析：组名+gid，过滤全部关注与频道段', () async {
      final adapter = _CaptureAdapter(
        (opt) async => ResponseBody.fromString(
          _fixture('message_all_groups.json'),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        ),
      );
      final svc = await _svc(adapter);
      final groups = await svc.getFollowGroups();
      // 夹具 group_type==0 三段：默认分组[全部关注, 最新微博]、
      // 我的分组[悄悄关注]、订阅分组[]；全部关注与「关注」频道
      // 同源被过滤，剩两组。
      expect(groups.map((g) => g.title), ['最新微博', '悄悄关注']);
      expect(groups.map((g) => g.gid), [
        '110001641537045',
        '100051641537045',
      ]);
      expect(
        adapter.requests.single.path,
        endsWith('/ajax/feed/allGroups'),
      );
    });
  });

  group('分组时间线 getGroupTimeline', () {
    test('系统分组（11000 前缀）走 friendstimeline 且带 fid/since_id', () async {
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({
          'statuses': [
            {
              'id': '5359000000000211',
              'idstr': '5359000000000211',
              'text': '最新微博分组帖（构造）',
              'user': {'id': 30021, 'screen_name': '分组作者'},
            },
          ],
          'max_id_str': 'mx1',
          'since_id': 'sc1',
        }),
      );
      final svc = await _svc(adapter);
      final r = await svc.getGroupTimeline(
        gid: '110001641537045',
        maxId: 'pm',
        sinceId: 'ps',
      );
      final req = adapter.requests.single;
      expect(req.path, endsWith('/ajax/feed/friendstimeline'));
      expect(req.queryParameters['list_id'], '110001641537045');
      expect(req.queryParameters['fid'], '110001641537045');
      expect(req.queryParameters['since_id'], 'ps');
      expect(req.queryParameters['max_id'], 'pm');
      expect(r.statuses.single.text, contains('最新微博分组帖'));
      expect(r.maxId, 'mx1');
      expect(r.sinceId, 'sc1');
    });

    test('自定义分组走 groupstimeline：fast_refresh=1、无 since_id/fid', () async {
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({'statuses': [], 'max_id_str': ''}),
      );
      final svc = await _svc(adapter);
      await svc.getGroupTimeline(gid: '100051641537045', maxId: 'pm');
      final req = adapter.requests.single;
      expect(req.path, endsWith('/ajax/feed/groupstimeline'));
      expect(req.queryParameters['list_id'], '100051641537045');
      expect(req.queryParameters['fast_refresh'], 1);
      expect(req.queryParameters['max_id'], 'pm');
      expect(req.queryParameters.containsKey('since_id'), isFalse);
      expect(req.queryParameters.containsKey('fid'), isFalse);
    });
  });

  group('屏蔽/拉黑 filterUser', () {
    test('全开：表单 {uid, screen_name, status/interact/follow=1}', () async {
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({'ok': 1, 'data': {}}),
      );
      final svc = await _svc(adapter);
      await svc.filterUser(uid: '424242', screenName: '被屏蔽者');
      final req = adapter.requests.single;
      expect(req.method, 'POST');
      expect(req.path, endsWith('/ajax/statuses/filterUser'));
      final body = adapter.bodies.single;
      expect(body, contains('uid=424242'));
      expect(body, contains('screen_name='));
      expect(body, contains('status=1'));
      expect(body, contains('interact=1'));
      expect(body, contains('follow=1'));
    });

    test('部分关闭：对应开关为 0', () async {
      final adapter = _CaptureAdapter(
        (opt) async => jsonBody({'ok': 1, 'data': {}}),
      );
      final svc = await _svc(adapter);
      await svc.filterUser(uid: '424242', blockFollow: false);
      final body = adapter.bodies.single;
      expect(body, contains('status=1'));
      expect(body, contains('interact=1'));
      expect(body, contains('follow=0'));
    });
  });
}
