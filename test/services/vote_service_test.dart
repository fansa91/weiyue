import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 投票线测试（全走假 adapter，绝不碰真实账号）：
/// - 模型：card_info.vote_object 结构解析（字段集出自主包 FeedVote
///   组件实证，fixture 为结构派生件，见 vote_status.json 的 _note）；
/// - setVote：路径与表单 {id, vote_items: 逗号拼接, ext: "4"} 逐字
///   对齐主包组件 setVote；回执 vote_object 整替 + error_msg 透传；
/// - cancelVote：表单只有 {id}，对齐组件 cancelVote；
/// - 未登录：_post 守卫直接抛「请先登录」，不发请求。
class _Visitor extends VisitorService {
  static const _id = VisitorIdentity('VSUB', 'VSUBP', 1793000000000);

  @override
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async =>
      _id;

  @override
  Future<VisitorIdentity> refresh(WbStack stack) async => _id;
}

/// 记录请求 + 请求体字节的假 adapter。
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

/// 投票后回执（结构派生：ok + vote_object，parted=1、选项带 selected）。
Map<String, dynamic> _votedReceipt() => {
      'ok': 1,
      'vote_object': {
        'id': 88001,
        'is_multi_select': 0,
        'state': 1,
        'parted': 1,
        'part_info': 129,
        'minimum': 1,
        'maximum': 1,
        'vote_list': [
          {'id': 11, 'content': '火锅', 'part_num': 71, 'part_ratio': 0.55, 'selected': 1},
          {'id': 12, 'content': '烧烤', 'part_num': 58, 'part_ratio': 0.45, 'selected': 0},
        ],
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('模型解析（card_info.vote_object）', () {
    test('fixture 投票帖：字段逐项对齐主包定义', () async {
      final raw = await File(
        'test/fixtures/vote_status.json',
      ).readAsString();
      final status = WbStatus.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
      final vote = status.vote;
      expect(vote, isNotNull);
      expect(vote!.id, 88001);
      expect(vote.multiSelect, isFalse);
      expect(vote.voted, isFalse);
      expect(vote.ended, isFalse);
      expect(vote.partInfo, 128);
      expect(vote.minimum, 1);
      expect(vote.maximum, 1);
      expect(vote.userNick, '投票博主');
      expect(vote.expireAt, isNotNull);
      expect(vote.items, hasLength(2));
      expect(vote.items.first.content, '火锅');
      expect(vote.items.first.partNum, 70);
      expect(vote.items.first.partRatio, closeTo(0.5469, 0.001));
      expect(vote.items.first.selected, isFalse);
    });

    test('普通帖子 vote 为 null；空 vote_object 也不误报', () {
      final plain = WbStatus.fromJson({
        'idstr': '42',
        'text_raw': '无投票',
        'card_info': {'vote_object': <String, dynamic>{}},
      });
      expect(plain.vote, isNull);
    });
  });

  group('setVote / cancelVote（主包 FeedVote 逐字表单）', () {
    Future<(_CaptureAdapter, WeiyueService)> rig({
      required Object body,
      bool loggedIn = true,
    }) async {
      final adapter = _CaptureAdapter((opt) async => jsonBody(body));
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: await _session(loggedIn: loggedIn),
      );
      return (adapter, svc);
    }

    test('单选：路径 + 表单 {id, vote_items: "11", ext: "4"}', () async {
      final (adapter, svc) = await rig(body: _votedReceipt());
      final r = await svc.setVote(88001, [11]);
      final opt = adapter.requests.single;
      expect(opt.method, 'POST');
      expect(opt.uri.path, '/ajax/statuses/setVote');
      expect(_formOf(adapter.byteBodies.single), {
        'id': '88001',
        'vote_items': '11',
        'ext': '4',
      });
      expect(r.vote, isNotNull);
      expect(r.vote!.voted, isTrue);
      expect(r.vote!.items.first.selected, isTrue);
      expect(r.vote!.items.first.partNum, 71);
      expect(r.errorMsg, isNull);
    });

    test('多选：vote_items 为逗号拼接（数组 toString 语义）', () async {
      final (adapter, svc) = await rig(body: _votedReceipt());
      await svc.setVote(88001, [11, 12]);
      expect(
        _formOf(adapter.byteBodies.single)['vote_items'],
        '11,12',
      );
    });

    test('回执 error_msg 透传（vote_object 仍生效）', () async {
      final body = _votedReceipt();
      (body['vote_object'] as Map<String, dynamic>)['error_msg'] = '投票太频繁';
      final (_, svc) = await rig(body: body);
      final r = await svc.setVote(88001, [11]);
      expect(r.errorMsg, '投票太频繁');
      expect(r.vote, isNotNull);
    });

    test('撤回：cancelVote 表单只有 {id}', () async {
      final receipt = _votedReceipt();
      (receipt['vote_object'] as Map<String, dynamic>)['parted'] = 0;
      final (adapter, svc) = await rig(body: receipt);
      final r = await svc.cancelVote(88001);
      final opt = adapter.requests.single;
      expect(opt.uri.path, '/ajax/statuses/cancelVote');
      expect(_formOf(adapter.byteBodies.single), {'id': '88001'});
      expect(r.vote!.voted, isFalse);
    });

    test('未登录：抛「请先登录」且零请求', () async {
      final (adapter, svc) = await rig(body: _votedReceipt(), loggedIn: false);
      await expectLater(
        svc.setVote(88001, [11]),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('请先登录'),
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });
  });
}
