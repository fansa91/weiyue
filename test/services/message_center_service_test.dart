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
/// unreadHint 自 2026-11-10 修复起必带 group_ids（主包调用点实证，
/// 缺参回 HTTP 200 网页 HTML）：分组经 allGroups 关注分组段取
/// （message_all_groups.json 按样本 pc_allGroups 结构构造）。
/// 非 JSON 报错带正文指纹（bodyFingerprint）也在本文件覆盖。
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
      if (opt.uri.path.endsWith('allGroups')) {
        return jsonBody(_fixture('message_all_groups.json'));
      }
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
      if (opt.uri.path.endsWith('allGroups')) {
        return jsonBody(_fixture('message_all_groups.json'));
      }
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

  test('未读汇总：unreadHint 带 group_ids（关注分组 gid、频道不混入），分组只拉一次', () async {
    final adapter = FakeAdapter((opt) async {
      if (opt.uri.path.endsWith('allGroups')) {
        return jsonBody(_fixture('message_all_groups.json'));
      }
      if (opt.uri.path.endsWith('unreadHint')) {
        return jsonBody(_fixture('message_unread_hint.json'));
      }
      return jsonBody(_fixture('message_summary.json'));
    });
    final svc = await _svc(adapter);

    final u = await svc.getMessageSummary();
    // 带参后解析结果与分类键用例一致，不回退
    expect(u.total, 11);

    // 请求先后：allGroups → unreadHint → summary
    expect(adapter.requests.map((r) => r.uri.path).toList(), [
      '/ajax/feed/allGroups',
      '/ajax/message/unreadHint',
      '/ajax/message/summary',
    ]);
    // group_ids 只含关注分组段（group_type=0）的 gid，频道段
    // （group_type=1 / type=8888）的 102803 等不混入
    expect(
      adapter.requests[1].queryParameters['group_ids'],
      '100011641537045,110001641537045,100051641537045',
    );

    // 第二次汇总：分组走会话缓存，不再拉 allGroups
    await svc.getMessageSummary();
    final allGroupsCalls = adapter.requests
        .where((r) => r.uri.path.endsWith('allGroups'))
        .length;
    expect(allGroupsCalls, 1);
  });

  test('未读汇总：allGroups 拉取失败时跳过 unreadHint、不记失败，summary 照常', () async {
    final session = await _sessionWithCookies();
    final adapter = FakeAdapter((opt) async {
      if (opt.uri.path.endsWith('allGroups')) {
        return jsonBody('<html><body>Bad Request</body></html>', status: 400);
      }
      if (opt.uri.path.endsWith('unreadHint')) {
        return jsonBody(_fixture('message_unread_hint.json'));
      }
      return jsonBody(_fixture('message_summary.json'));
    });
    final svc = await _svc(adapter, session: session);

    final u = await svc.getMessageSummary();
    // summary 只有互动量形态：分类全零；unreadHint 根本没被调用
    expect(u.total, 0);
    expect(adapter.requests.map((r) => r.uri.path).toList(), [
      '/ajax/feed/allGroups',
      '/ajax/message/summary',
    ]);
    // 跳过 unreadHint 不记失败，分组拉取失败也不记
    expect(session.recentLoginFailures, isEmpty);
  });

  test('非 JSON（200 HTML）：异常消息带正文指纹（网页标题）', () async {
    // 真实错误页是 text/html：dio 不预解码、正文以 String 到达 _get，
    // 才能走指纹路径（jsonBody 的 application/json 头会让 dio 先在
    // 解码层抛错，与真机不符，故此处直接构造 text/html 响应）。
    final adapter = FakeAdapter(
      (opt) async => ResponseBody.fromString(
        '<html><head><title>安全验证</title></head><body>verify</body></html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      ),
    );
    final svc = await _svc(adapter);

    await expectLater(
      svc.getMessageFeed(),
      throwsA(
        isA<WeiyueException>().having(
          (e) => e.message,
          'message',
          contains('接口返回非 JSON（HTTP 200，网页标题：安全验证）'),
        ),
      ),
    );
  });

  group('bodyFingerprint 正文指纹（纯函数）', () {
    test('带 title 的 HTML：取标题文本', () {
      expect(
        WeiyueService.bodyFingerprint(
          '<html><head><title>微博 - 随时随地发现新鲜事</title></head>'
          '<body>x</body></html>',
        ),
        '网页标题：微博 - 随时随地发现新鲜事',
      );
    });

    test('title 清洗空白/控制字符并截断 40 字', () {
      final fp = WeiyueService.bodyFingerprint(
        '<title>  ${'长' * 50}\n\t标题 </title>',
      );
      expect(fp, '网页标题：${'长' * 40}');
    });

    test('无 title：命中登录关键词', () {
      expect(
        WeiyueService.bodyFingerprint(
          '<html><body>请先登录再操作</body></html>',
        ),
        '关键词：登录',
      );
    });

    test('无 title：验证关键词优先于安全', () {
      expect(
        WeiyueService.bodyFingerprint(
          '<html><body>安全验证：请完成验证</body></html>',
        ),
        '关键词：验证',
      );
    });

    test('无线索 HTML 回 HTML，空正文回空正文', () {
      expect(
        WeiyueService.bodyFingerprint('<html><body>Bad Request</body></html>'),
        'HTML',
      );
      expect(WeiyueService.bodyFingerprint('   '), '空正文');
    });
  });
}
