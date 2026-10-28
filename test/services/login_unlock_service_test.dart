import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 登录态只读解锁的服务层测试。
/// fixture 均按 WEIBO_API.md 记载的响应结构构造（非真实抓取），
/// Cookie 值均为假的合成串（FAKE_*）；登录态真实行为待用户真机验证。
class CountingVisitor extends VisitorService {
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

Future<SessionService> _sessionWithCookies() async {
  final s = SessionService();
  await s.saveHarvest(const [
    HarvestedCookie(name: 'SUB', value: 'FAKE_PC_SUB', domain: 'weibo.com'),
    HarvestedCookie(name: 'SUBP', value: 'FAKE_PC_SUBP', domain: 'weibo.com'),
    HarvestedCookie(name: 'SUB', value: 'FAKE_M_SUB', domain: 'm.weibo.cn'),
    HarvestedCookie(name: 'SUBP', value: 'FAKE_M_SUBP', domain: 'weibo.cn'),
  ]);
  return s;
}

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

String _cookieOf(RequestOptions opt) => opt.headers.entries
    .firstWhere((e) => e.key.toLowerCase() == 'cookie')
    .value
    .toString();

const _channel = WbChannel(
  gid: '1028034188',
  title: '社会',
  containerid: '102803_ctg1_4188_-_ctg1_4188',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('登录态优先：请求带会话 Cookie 而非访客 Cookie', () async {
    final visitor = CountingVisitor();
    final session = await _sessionWithCookies();
    final adapter = FakeAdapter(
      (opt) async => jsonBody({
        'ok': 1,
        'statuses': [
          {
            'id': '31',
            'text_raw': '登录态热门',
            'user': {'id': 1, 'screen_name': '某号'},
          },
        ],
        'max_id': 1,
      }),
    );
    final svc = WeiyueService(visitor, pcDio: _dio(adapter), session: session);

    final page = await svc.getHotTimeline(_channel);
    expect(page.statuses.single.text, '登录态热门');
    final cookie = _cookieOf(adapter.requests.single);
    expect(cookie, contains('SUB=FAKE_PC_SUB'));
    expect(cookie, isNot(contains('VSUB')));
  });

  test('登录态被拒（ok:-100）：标记过期并回退访客完成请求', () async {
    final visitor = CountingVisitor();
    final session = await _sessionWithCookies();
    final adapter = FakeAdapter((opt) async {
      if (_cookieOf(opt).contains('FAKE_PC_SUB')) {
        return jsonBody({'ok': -100, 'msg': 'need login'});
      }
      return jsonBody({
        'ok': 1,
        'statuses': [
          {
            'id': '32',
            'text_raw': '访客兜底成功',
            'user': {'id': 2, 'screen_name': '兜底号'},
          },
        ],
        'max_id': 1,
      });
    });
    final svc = WeiyueService(visitor, pcDio: _dio(adapter), session: session);

    final page = await svc.getHotTimeline(_channel);
    expect(page.statuses.single.text, '访客兜底成功');
    expect(adapter.requests.length, 2);
    expect(_cookieOf(adapter.requests[1]), contains('SUB=VSUB'));
    expect(session.expired, isTrue);
    // 回退直接用已有访客身份，不必先刷新
    expect(visitor.refreshCalls, 0);
  });

  test('关注流：friendstimeline 参数与 data.list 解析（构造 fixture）', () async {
    final visitor = CountingVisitor();
    final session = await _sessionWithCookies();
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('friends_timeline.json')),
    );
    final svc = WeiyueService(visitor, pcDio: _dio(adapter), session: session);

    final page = await svc.getFriendsTimeline();
    expect(adapter.requests.single.uri.path, '/ajax/feed/friendstimeline');
    final q = adapter.requests.single.queryParameters;
    expect(q['list_id'], 10001);
    expect(q['since_id'], '0');
    expect(page.statuses.length, 2);
    expect(page.statuses.first.text, contains('关注流第一条'));
    expect(page.statuses.first.user?.screenName, '关注博主甲');
    expect(page.sinceId, '5359000000000002');
  });

  test('转发列表：repostTimeline 解析（构造 fixture）', () async {
    final visitor = CountingVisitor();
    final session = await _sessionWithCookies();
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('repost_timeline.json')),
    );
    final svc = WeiyueService(visitor, pcDio: _dio(adapter), session: session);

    final r = await svc.getReposts('5358256479801810');
    expect(adapter.requests.single.uri.path, '/ajax/statuses/repostTimeline');
    expect(adapter.requests.single.queryParameters['id'], '5358256479801810');
    expect(r.items.length, 2);
    expect(r.total, 2);
    expect(r.maxPage, 1);
    expect(r.items.first.retweeted?.text, contains('被转发的原帖'));
  });

  test('我的收藏：all_fav 解包 status 子对象 + 平铺条目（构造 fixture）', () async {
    final visitor = CountingVisitor();
    final session = await _sessionWithCookies();
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('favorites_all_fav.json')),
    );
    final svc = WeiyueService(visitor, pcDio: _dio(adapter), session: session);

    final r = await svc.getFavorites();
    expect(adapter.requests.single.uri.path, '/ajax/favorites/all_fav');
    expect(r.items.length, 2);
    expect(r.items[0].text, contains('status 子对象解包'));
    expect(r.items[1].text, contains('平铺条目'));
    expect(r.total, 2);
  });

  test('评论：内嵌楼中楼解析 + max_id 游标回传（构造 fixture）', () async {
    final visitor = CountingVisitor();
    final session = await _sessionWithCookies();
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('comments_with_replies.json')),
    );
    final svc = WeiyueService(visitor, pcDio: _dio(adapter), session: session);

    final r = await svc.getComments('5358256479801810', authorUid: '42');
    expect(r.comments.length, 2);
    expect(r.comments.first.replies.length, 2);
    expect(r.comments.first.replies.first.text, '楼中楼回复一');
    expect(r.comments.last.replies, isEmpty);
    expect(r.total, 3);
    expect(r.maxId, 424242);

    await svc.getComments('5358256479801810', authorUid: '42', maxId: r.maxId);
    expect(adapter.requests.last.queryParameters['max_id'], 424242);
  });

  group('probeSession', () {
    test('getBasicInfo 拿到用户 + m 探活通过 → 两栈解锁', () async {
      final visitor = CountingVisitor();
      final session = await _sessionWithCookies();
      final pcAdapter = FakeAdapter((opt) async {
        expect(opt.uri.path, '/ajax/setting/getBasicInfo');
        return jsonBody(_fixture('current_user.json'));
      });
      final mAdapter = FakeAdapter(
        (opt) async => jsonBody({'ok': 1, 'data': []}),
      );
      final svc = WeiyueService(
        visitor,
        pcDio: _dio(pcAdapter),
        mDio: _dio(mAdapter),
        session: session,
      );

      final probe = await svc.probeSession();
      expect(probe.user?.screenName, '构造测试用户');
      expect(probe.user?.id, 777);
      expect(probe.pcUnlocked, isTrue);
      expect(probe.mUnlocked, isTrue);
    });

    test('无当前用户时用 friendstimeline 不被挡兜底判 PC 解锁；m 回 -100 未解锁', () async {
      final visitor = CountingVisitor();
      final session = await _sessionWithCookies();
      final pcAdapter = FakeAdapter((opt) async {
        switch (opt.uri.path) {
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
        visitor,
        pcDio: _dio(pcAdapter),
        mDio: _dio(mAdapter),
        session: session,
      );

      final probe = await svc.probeSession();
      expect(probe.user, isNull);
      expect(probe.pcUnlocked, isTrue);
      expect(probe.mUnlocked, isFalse);
    });

    test('两栈全被挡 → 均未解锁（探活不回退访客）', () async {
      final visitor = CountingVisitor();
      final session = await _sessionWithCookies();
      final blocked = FakeAdapter(
        (opt) async => jsonBody({'ok': -100, 'msg': 'blocked'}),
      );
      final svc = WeiyueService(
        visitor,
        pcDio: _dio(blocked),
        mDio: _dio(blocked),
        session: session,
      );

      final probe = await svc.probeSession();
      expect(probe.pcUnlocked, isFalse);
      expect(probe.mUnlocked, isFalse);
      // sessionOnly 不触发访客刷新重试
      expect(visitor.refreshCalls, 0);
    });
  });
}
