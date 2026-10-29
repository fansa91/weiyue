import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 消息中心服务层测试。
/// fixture 依据：WEIBO_API.md「登录与写接口」节静态确认的 message 族
/// 路径 + PC 网页端主包（rea-probe raw/pc_index.js）消息页组件实证的
/// 信封（data[<类型键>] + next_cursor/nextId 双游标）、页签参数
/// （msgList?type=all、filter_by_author）与条目字段（msgList 的
/// uuidTmp/create_time/userInfo/tips/msg_type/msgInfo、评论的
/// reply_comment/status、赞的 comment/status）。全部为按此结构构造
/// 的假数据（非真实抓取），Cookie 均为 FAKE_* 合成串；
/// 登录态真实返回结构待用户真机验证。
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
    HarvestedCookie(name: 'SUB', value: 'FAKE_M_SUB', domain: 'm.weibo.cn'),
    HarvestedCookie(name: 'SUBP', value: 'FAKE_M_SUBP', domain: 'weibo.cn'),
  ]);
  return s;
}

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

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

  test('全部消息：msgList?type=all 参数 + 三类条目解析 + 坏条目过滤', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('message_msglist.json')),
    );
    final svc = await _svc(adapter);

    final page = await svc.getMessageFeed();
    final req = adapter.requests.single;
    expect(req.uri.path, '/ajax/message/msgList');
    expect(req.queryParameters['type'], 'all');
    expect(req.queryParameters['max_id'], 0);

    // 4 条里 1 条全空被过滤
    expect(page.items.length, 3);
    final cmt = page.items[0];
    expect(cmt.kind, MessageFeedKind.comment);
    expect(cmt.actor?.screenName, '互动用户甲');
    expect(cmt.actionText, '评论了你的微博');
    expect(cmt.text, '混合流评论正文一');
    expect(cmt.status?.id, '5359000000000101');

    final like = page.items[1];
    expect(like.kind, MessageFeedKind.like);
    expect(like.commentText, '被赞的评论正文');
    expect(like.status?.id, '5359000000000102');

    final status = page.items[2];
    expect(status.kind, MessageFeedKind.status);
    expect(status.status?.id, '5359000000000103');
    expect(status.text, '提及你的微博正文');

    expect(page.maxId, '555001');
    expect(page.sinceId, '555002');
    expect(page.hasMore, isTrue);
  });

  test('全部消息第二页：游标透传 + list 型以 nextId==0 判到底', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('message_msglist_page2.json')),
    );
    final svc = await _svc(adapter);

    final page = await svc.getMessageFeed(maxId: '555001', sinceId: '555002');
    final q = adapter.requests.single.queryParameters;
    expect(q['max_id'], '555001');
    expect(q['sinceId'], '555002');
    expect(page.items.single.kind, MessageFeedKind.like);
    expect(page.items.single.status?.id, '5359000000000109');
    // next_cursor 仍非 0，但 list 型按 nextId==0 终止（主包实证）
    expect(page.hasMore, isFalse);
  });

  test('@我的微博：statuses 解析 + filter_by_author 参数', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('message_mentions.json')),
    );
    final svc = await _svc(adapter);

    final page = await svc.getMentions(onlyFollowed: true);
    final req = adapter.requests.single;
    expect(req.uri.path, '/ajax/statuses/mentions');
    expect(req.queryParameters['filter_by_author'], 1);
    expect(page.items.single.id, '5359000000000201');
    expect(page.items.single.text, contains('@登录测试号'));
    expect(page.hasMore, isTrue);
  });

  test('@我的评论：comments/mentions 解析出评论与所属微博', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('message_mention_comments.json')),
    );
    final svc = await _svc(adapter);

    final page = await svc.getMentionComments();
    expect(adapter.requests.single.uri.path, '/ajax/comments/mentions');
    final item = page.items.single;
    expect(item.comment.text, '这条评论@了你');
    expect(item.comment.user?.screenName, '互动用户乙');
    expect(item.status?.id, '5359000000000202');
    expect(page.hasMore, isFalse);
  });

  test('收到的评论：cmt 的 reply_comment/status 解包 + next_cursor 判续页', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('message_cmt.json')),
    );
    final svc = await _svc(adapter);

    final page = await svc.getCommentsToMe();
    expect(adapter.requests.single.uri.path, '/ajax/message/cmt');
    expect(page.items.length, 2);
    final reply = page.items[0];
    expect(reply.comment.text, contains('回复你'));
    expect(reply.comment.likeCount, 5);
    expect(reply.replyTo?.text, '我先前的评论原文');
    expect(reply.status?.id, '5359000000000301');
    expect(page.items[1].replyTo, isNull);
    expect(page.maxId, '999');
    expect(page.hasMore, isTrue);
  });

  test('我发出的评论：myCmt 解析', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('message_my_cmt.json')),
    );
    final svc = await _svc(adapter);

    final page = await svc.getMyComments();
    expect(adapter.requests.single.uri.path, '/ajax/message/myCmt');
    expect(page.items.single.comment.text, '我发出的评论正文');
    expect(page.items.single.status?.id, '5359000000000401');
    expect(page.hasMore, isFalse);
  });

  test('收到的赞：attitudes 的微博赞/评论赞两形态', () async {
    final adapter = FakeAdapter(
      (opt) async => jsonBody(_fixture('message_attitudes.json')),
    );
    final svc = await _svc(adapter);

    final page = await svc.getLikesToMe();
    expect(adapter.requests.single.uri.path, '/ajax/message/attitudes');
    expect(page.items.length, 2);
    final statusLike = page.items[0];
    expect(statusLike.user?.screenName, '互动用户甲');
    expect(statusLike.commentText, isEmpty);
    expect(statusLike.status?.id, '5359000000000501');
    final commentLike = page.items[1];
    expect(commentLike.commentText, '被赞的评论正文二');
    expect(commentLike.status?.id, '5359000000000501');
    expect(page.hasMore, isFalse);
  });

  test('未读汇总：unreadHint 分类键解析，groups 的 gid 不计入分类', () async {
    final adapter = FakeAdapter((opt) async {
      if (opt.uri.path.endsWith('unreadHint')) {
        return jsonBody(_fixture('message_unread_hint.json'));
      }
      return jsonBody(_fixture('message_summary.json'));
    });
    final svc = await _svc(adapter);

    final u = await svc.getMessageSummary();
    expect(u.mentionStatuses, 3);
    expect(u.mentionComments, 1);
    expect(u.mentions, 4);
    expect(u.commentsToMe, 2);
    expect(u.likesToMe, 5);
    // 无 messages 总数键：total 退回分类求和（不含 groups 的 gid 计数 4）
    expect(u.total, 11);
  });

  test('未读汇总：只有 summary 的互动量形态时分类全零、不抛错', () async {
    final adapter = FakeAdapter((opt) async {
      if (opt.uri.path.endsWith('unreadHint')) return jsonBody({'ok': 1});
      return jsonBody(_fixture('message_summary.json'));
    });
    final svc = await _svc(adapter);

    final u = await svc.getMessageSummary();
    expect(u.total, 0);
    expect(u.mentions, 0);
    expect(u.commentsToMe, 0);
    expect(u.likesToMe, 0);
  });

  test('列表失败（400 非 JSON）：抛错并记入登录诊断', () async {
    final session = await _sessionWithCookies();
    final adapter = FakeAdapter(
      (opt) async => jsonBody('<html>Bad Request</html>', status: 400),
    );
    final svc = await _svc(adapter, session: session);

    await expectLater(
      svc.getMessageFeed(),
      throwsA(isA<WeiyueException>()),
    );
    expect(
      session.recentLoginFailures.map((f) => f.endpoint),
      contains('/ajax/message/msgList'),
    );
  });
}
