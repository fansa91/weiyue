import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 私信（WebIM 子系统）服务层测试。
/// 依据：WEIBO_API.md「私信」小节——网页版聊天应用 bundle
/// （rea-probe raw/chat_app.js）调用点逐字实证的路径/参数/字段
/// （contacts 的 special_source 与参数集、conversation 的参数集
/// 与 direct_messages 首元最新序、new.json 的 tocontact 最小
/// 表单、set_unread_count 的 {type:2,...} 表单），失败信封
/// {error, error_code} 与 21301 鉴权错误为访客探针真实捕获
/// （rea-probe samples/pc_chat_visitor_errors.json）。
/// fixture 按结构样本（rea-probe samples/pc_chat_structure.json，
/// bundle 字段整理）构造，值全为假数据，Cookie 均为 FAKE_*；
/// 登录态真实返回未经真机实测，待用户真机验证。
class CountingVisitor extends VisitorService {
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

Future<SessionService> _sessionWithCookies() async {
  final s = SessionService();
  await s.saveHarvest(const [
    HarvestedCookie(name: 'SUB', value: 'FAKE_PC_SUB', domain: 'weibo.com'),
    HarvestedCookie(name: 'SUBP', value: 'FAKE_PC_SUBP', domain: 'weibo.com'),
    HarvestedCookie(name: 'XSRF-TOKEN', value: 'FAKE_XSRF', domain: 'weibo.com'),
  ]);
  return s;
}

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

String? _header(RequestOptions req, String name) {
  for (final e in req.headers.entries) {
    if (e.key.toLowerCase() == name) return '${e.value}';
  }
  return null;
}

Future<WeiyueService> _svc(FakeAdapter adapter, {SessionService? session}) =>
    _sessionWithCookies().then(
      (s) => WeiyueService(
        CountingVisitor(),
        pcDio: _dio(adapter),
        session: session ?? s,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('会话列表：路径/参数逐字 + 解析 + type3 虚拟条目过滤 + 未关注人合并', () async {
    final adapter = FakeAdapter((opt) async {
      if (opt.uri.path.endsWith('/public/contacts.json')) {
        return jsonBody(_fixture('dm_public_contacts.json'));
      }
      return jsonBody(_fixture('dm_contacts.json'));
    });
    final svc = await _svc(adapter);

    final r = await svc.getDmConversations();
    expect(adapter.requests.length, 2);
    final req = adapter.requests.first;
    expect(req.uri.host, 'api.weibo.com');
    expect(req.uri.path, '/webim/2/direct_messages/contacts.json');
    expect(req.uri.queryParameters['special_source'], '3');
    expect(req.queryParameters['add_virtual_user'], '3,4');
    expect(req.queryParameters['refresh_user_count'], 1);
    expect(req.queryParameters['need_back'], '0,0');
    expect(req.queryParameters['count'], 50);
    expect(req.queryParameters['is_include_folder'], 1);
    expect(_header(req, 'cookie'), contains('FAKE_PC_SUB'));
    // WebIM 不带 XSRF（chat bundle axios 直发，无此头，硬带反而未证）
    expect(_header(req, 'x-xsrf-token'), isNull);

    // fixture 3 条里 type==3 的虚拟条目被过滤
    expect(r.chats.length, 2);
    final first = r.chats.first;
    expect(first.user.screenName, '私信测试博主');
    expect(first.lastText, '最新的一条');
    expect(first.unreadCount, 2);
    expect(first.isPublic, isFalse);
    expect(first.lastTime, isNotNull);

    expect(r.strangers.length, 1);
    expect(r.strangers.single.isPublic, isTrue);
    expect(r.strangers.single.user.screenName, '未关注的陌生人');
    expect(
      adapter.requests[1].uri.path,
      '/webim/2/direct_messages/public/contacts.json',
    );
  });

  test('历史消息：参数逐字 + 服务端最新序翻转为升序 + hasMore 粗判', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('dm_conversation.json')),
    );
    final svc = await _svc(adapter);

    final page = await svc.getDmHistory('1641537791', count: 20);
    final req = adapter.requests.single;
    expect(req.uri.path, '/webim/2/direct_messages/conversation.json');
    expect(req.queryParameters['convert_emoji'], 1);
    expect(req.queryParameters['count'], 20);
    expect(req.queryParameters['max_id'], 0);
    expect(req.queryParameters['uid'], '1641537791');
    expect(req.queryParameters['is_include_group'], 0);
    expect(req.queryParameters['from_contacts'], 1);

    expect(page.messages.length, 25);
    expect(page.messages.first.text, '历史消息 1');
    expect(page.messages.last.text, '历史消息 25');
    expect(page.messages.first.senderId, 1641537791);
    expect(page.hasMore, isTrue); // 25 条原始返回 >= count 20

    await svc.getDmHistory('1641537791', maxId: 5300000000000106);
    expect(adapter.requests.last.queryParameters['max_id'], 5300000000000106);
  });

  test('历史消息：未关注人会话走 public/conversation', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('dm_conversation.json')),
    );
    final svc = await _svc(adapter);
    await svc.getDmHistory('2000000001', isPublic: true);
    expect(
      adapter.requests.single.uri.path,
      '/webim/2/direct_messages/public/conversation.json',
    );
  });

  test('发送文本：new.json 表单为 tocontact 最小集 + 回执解析', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('dm_send_ok.json')),
    );
    final svc = await _svc(adapter);

    final sent = await svc.sendDm('1641537791', '你好，这是一条私信');
    final req = adapter.requests.single;
    expect(req.method, 'POST');
    expect(req.uri.path, '/webim/2/direct_messages/new.json');
    expect(req.contentType, contains('application/x-www-form-urlencoded'));
    final form = req.data as Map;
    expect(form['text'], '你好，这是一条私信');
    expect(form['uid'], '1641537791');
    expect(form['extensions'], '{"clientid":""}');
    expect(form['is_encoded'], '0');
    expect(form['decodetime'], '1');

    expect(sent.id, 5300000000000126);
    expect(sent.text, '你好，这是一条私信');
    expect(sent.recipientId, 1641537791);
    expect(sent.createdAt, isNotNull);
  });

  test('标记已读：set_unread_count 表单 {type:2, uid, is_include_group:0}', () async {
    final adapter = FakeAdapter((opt) async => jsonBody({}));
    final svc = await _svc(adapter);

    await svc.markDmRead('1641537791');
    var req = adapter.requests.single;
    expect(req.uri.path, '/webim/2/direct_messages/set_unread_count.json');
    final form = req.data as Map;
    expect(form['type'], '2');
    expect(form['uid'], '1641537791');
    expect(form['is_include_group'], '0');

    await svc.markDmRead('2000000001', isPublic: true);
    req = adapter.requests.last;
    expect(
      req.uri.path,
      '/webim/2/direct_messages/public/set_unread_count.json',
    );
  });

  test('鉴权错误信封（访客探针原文）：21301 → 标记过期并抛登录失效', () async {
    final adapter = FakeAdapter(
      (opt) async =>
          jsonBody({'error': 'auth by Null spi!', 'error_code': 21301}),
    );
    final session = await _sessionWithCookies();
    final svc = await _svc(adapter, session: session);

    await expectLater(
      svc.getDmConversations(),
      throwsA(
        isA<WeiyueException>().having(
          (e) => e.message,
          'message',
          '登录态已失效，请重新登录',
        ),
      ),
    );
    expect(session.expired, isTrue);
  });

  test('业务错误信封：error 文案原样抛 + 记登录诊断', () async {
    final adapter = FakeAdapter(
      (opt) async =>
          jsonBody({'error': '对方设置了私信权限', 'error_code': 100001}),
    );
    final session = await _sessionWithCookies();
    final svc = await _svc(adapter, session: session);

    await expectLater(
      svc.sendDm('1641537791', '你好'),
      throwsA(
        isA<WeiyueException>().having(
          (e) => e.message,
          'message',
          '对方设置了私信权限',
        ),
      ),
    );
    expect(
      session.recentLoginFailures.any(
        (f) => f.endpoint.contains('direct_messages/new.json'),
      ),
      isTrue,
    );
  });

  test('未登录：直接抛请先登录且零请求发出', () async {
    final adapter = FakeAdapter((opt) async => jsonBody({}));
    final svc = WeiyueService(
      CountingVisitor(),
      pcDio: _dio(adapter),
      session: SessionService(),
    );
    await expectLater(
      svc.getDmConversations(),
      throwsA(
        isA<WeiyueException>().having((e) => e.message, 'message', '请先登录'),
      ),
    );
    expect(adapter.requests, isEmpty);
  });
}
