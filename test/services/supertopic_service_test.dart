import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 超话线服务层测试（全走假 adapter，绝不碰真实账号）：
/// 路径/表单/成功码逐字对齐主包 chaohua 模块——
/// extend 状态字段、follow 成功码 100000、unfollow 成功码 10000
/// （两码不同是主包原文）、checkin 表单与 title/sub_title 回执、
/// code 100003 登录失效、未登录零请求。
class _Visitor extends VisitorService {
  static const _id = VisitorIdentity('VSUB', 'VSUBP', 1793000000000);

  @override
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async =>
      _id;

  @override
  Future<VisitorIdentity> refresh(WbStack stack) async => _id;

  @override
  VisitorIdentity? identityOf(WbStack stack) => _id;

  @override
  bool hasIdentity(WbStack stack) => true;
}

class _CaptureAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<Uint8List> byteBodies = [];
  final Future<ResponseBody> Function(RequestOptions options) handler;

  _CaptureAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    var bytes = Uint8List(0);
    if (requestStream != null) {
      bytes = await requestStream.fold<Uint8List>(
        Uint8List(0),
        (acc, chunk) => Uint8List.fromList([...acc, ...chunk]),
      );
    }
    byteBodies.add(bytes);
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

Future<SessionService> _session({bool loggedIn = true}) async {
  final s = SessionService();
  if (loggedIn) {
    await s.saveHarvest([
      const HarvestedCookie(name: 'SUB', value: 'FAKE_PC_SUB', domain: 'weibo.com'),
      const HarvestedCookie(
        name: 'XSRF-TOKEN',
        value: 'FAKE_XSRF_TOKEN',
        domain: 'weibo.com',
      ),
    ]);
    await s.saveProbe(uid: '777', screenName: 'FAKE 号', pcUnlocked: true);
  }
  return s;
}

Map<String, String> _formOf(Uint8List body) =>
    Uri.splitQueryString(utf8.decode(body));

const _pageId = '100808abcdef0123';

Future<(_CaptureAdapter, WeiyueService)> _rig({
  required Object Function(RequestOptions opt) body,
  bool loggedIn = true,
}) async {
  final adapter = _CaptureAdapter((opt) async => jsonBody(body(opt)));
  final svc = WeiyueService(
    _Visitor(),
    pcDio: _dio(adapter),
    mDio: _dio(adapter),
    session: await _session(loggedIn: loggedIn),
  );
  return (adapter, svc);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('WbTopicEntry.superPageId', () {
    test('100808 容器 → 整串 page_id；普通话题 → null', () {
      const st = WbTopicEntry(
        title: '某超话',
        scheme:
            'https://m.weibo.cn/p/index?extparam=x&containerid=100808abcdef0123',
      );
      expect(st.superPageId, '100808abcdef0123');
      const topic = WbTopicEntry(
        title: '某话题',
        scheme: 'https://m.weibo.cn/search?containerid=231522type=1',
      );
      expect(topic.superPageId, isNull);
      expect(const WbTopicEntry(title: '无 scheme').superPageId, isNull);
    });
  });

  group('chaohua 三件套（主包逐字）', () {
    test('extend：路径/参数与状态字段解析', () async {
      final (adapter, svc) = await _rig(
        body: (_) => {
          'is_followed': true,
          'follow_btn_text': '已关注',
          'is_checked': false,
          'recommend_topics': [],
        },
      );
      final st = await svc.getSuperTopicState(_pageId);
      final opt = adapter.requests.single;
      expect(opt.method, 'GET');
      expect(opt.uri.path, '/ajax_proxy/chaohua/page/extend');
      expect(opt.uri.queryParameters['page_id'], _pageId);
      expect(opt.uri.queryParameters['show_recommend'], '1');
      expect(st.isFollowed, isTrue);
      expect(st.followBtnText, '已关注');
      expect(st.isChecked, isFalse);
    });

    test('follow：表单只有 page_id，code 100000 成功并回按钮文案', () async {
      final (adapter, svc) = await _rig(
        body: (_) => {'code': 100000, 'follow_btn_text': '已关注'},
      );
      final text = await svc.followSuperTopic(_pageId);
      final opt = adapter.requests.single;
      expect(opt.uri.path, '/ajax_proxy/chaohua/page/follow');
      expect(_formOf(adapter.byteBodies.single), {'page_id': _pageId});
      expect(text, '已关注');
    });

    test('follow 失败码：抛服务端 msg', () async {
      final (_, svc) = await _rig(
        body: (_) => {'code': 100001, 'msg': '关注太频繁'},
      );
      await expectLater(
        svc.followSuperTopic(_pageId),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('关注太频繁'),
          ),
        ),
      );
    });

    test('unfollow：成功码是 10000（与 follow 不同，主包原文）', () async {
      final (adapter, svc) = await _rig(
        body: (_) => {'code': 10000, 'follow_btn_text': '关注'},
      );
      final text = await svc.unfollowSuperTopic(_pageId);
      expect(adapter.requests.single.uri.path, '/ajax_proxy/chaohua/page/unfollow');
      expect(text, '关注');
    });

    test('checkin：表单含 scene_id=pc_checkin，成功回 title/sub_title', () async {
      final (adapter, svc) = await _rig(
        body: (_) => {
          'code': 100000,
          'title': '签到成功',
          'sub_title': '已连续签到 3 天',
        },
      );
      final r = await svc.checkinSuperTopic(_pageId);
      expect(adapter.requests.single.uri.path, '/ajax_proxy/chaohua/page/checkin');
      final form = _formOf(adapter.byteBodies.single);
      expect(form['scene_id'], 'pc_checkin');
      expect(form['page_id'], _pageId);
      expect(form['lang'], 'zh-CN');
      expect(form.containsKey('timezone'), isTrue);
      expect(form.containsKey('plat'), isTrue);
      expect(form.containsKey('ua'), isTrue);
      expect(r.title, '签到成功');
      expect(r.subTitle, '已连续签到 3 天');
    });

    test('code 100003：标记过期并抛登录失效', () async {
      final (_, svc) = await _rig(
        body: (_) => {'code': 100003, 'msg': '请先登录'},
      );
      await expectLater(
        svc.followSuperTopic(_pageId),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('登录态已失效'),
          ),
        ),
      );
      expect(svc.session.expired, isTrue);
    });

    test('未登录：关注/签到都抛「请先登录」且零请求', () async {
      final (adapter, svc) = await _rig(body: (_) => {}, loggedIn: false);
      await expectLater(
        svc.followSuperTopic(_pageId),
        throwsA(isA<WeiyueException>()),
      );
      await expectLater(
        svc.checkinSuperTopic(_pageId),
        throwsA(isA<WeiyueException>()),
      );
      expect(adapter.requests, isEmpty);
    });
  });
}
