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

/// 发帖线服务层测试（全走假 adapter，绝不碰真实账号）：
/// - publishStatus：路径与表单逐字对齐主包发布器 toolbarPublish 的
///   组装（{content, pic_id, visible, share_id, media, vote}），
///   pic_id 有图时为 handlePic 的 JSON 串（type+pid 两键）；
/// - uploadPicture：picupload upload.php 分支形态（主包
///   uploadWithFile$3 在发布器图片组件以分流标志 1 调用）——
///   查询参数、原始字节请求体、application/octet-stream、
///   显式不带 X-Xsrf-Token / X-Requested-With（网页端为上传另起
///   实例删掉的两个头）、成功取 pic.pid、errno 错误表文案；
/// - CRC32 用公开已知向量（"123456789" → 0xCBF43926）校验。
class _Visitor extends VisitorService {
  static const _id = VisitorIdentity('VSUB', 'VSUBP', 1793000000000);

  @override
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async =>
      _id;

  @override
  Future<VisitorIdentity> refresh(WbStack stack) async => _id;
}

/// 记录请求 + 原始请求字节的假 adapter。
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

String? _headerOf(RequestOptions opt, String name) {
  for (final e in opt.headers.entries) {
    if (e.key.toLowerCase() == name) return '${e.value}';
  }
  return null;
}

Map<String, String> _formOf(Uint8List body) =>
    Uri.splitQueryString(utf8.decode(body));

/// 已知向量：ASCII "123456789" 的字节。
final _knownBytes = Uint8List.fromList('123456789'.codeUnits);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('crc32OfBytes 已知向量', () {
    test('"123456789" → 0xCBF43926（3421780262）', () {
      expect(WeiyueService.crc32OfBytes(_knownBytes), 3421780262);
    });

    test('空字节 → 0', () {
      expect(WeiyueService.crc32OfBytes(const []), 0);
    });
  });

  group('publishStatus 发帖表单（主包发布器组装）', () {
    Future<(_CaptureAdapter, WeiyueService)> rig({
      Object body = const {'ok': 1},
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

    test('纯文字：路径 + 六字段逐字（pic_id/media/vote/share_id 空串）', () async {
      final (adapter, svc) = await rig();
      await svc.publishStatus('第一条动态');
      final opt = adapter.requests.single;
      expect(opt.method, 'POST');
      expect(opt.uri.host, 'weibo.com');
      expect(opt.uri.path, '/ajax/statuses/update');
      expect(_headerOf(opt, 'x-xsrf-token'), 'FAKE_XSRF_TOKEN');
      expect(_headerOf(opt, 'referer'), 'https://weibo.com/');
      expect(_formOf(adapter.byteBodies.single), {
        'content': '第一条动态',
        'pic_id': '',
        'visible': '0',
        'share_id': '',
        'media': '',
        'vote': '',
      });
    });

    test('带图：pic_id 为 handlePic 的 JSON 串（type+pid 两键、顺序同主包）', () async {
      final (adapter, svc) = await rig();
      await svc.publishStatus(
        '带图动态',
        pics: [
          (pid: 'pidAAA', type: 'image/jpeg'),
          (pid: 'pidBBB', type: 'image/png'),
        ],
      );
      final form = _formOf(adapter.byteBodies.single);
      expect(
        form['pic_id'],
        '[{"type":"image/jpeg","pid":"pidAAA"},'
        '{"type":"image/png","pid":"pidBBB"}]',
      );
      expect(form['content'], '带图动态');
    });

    test('未登录：抛「请先登录」，adapter 零请求', () async {
      final (adapter, svc) = await rig(loggedIn: false);
      await expectLater(
        svc.publishStatus('x'),
        throwsA(
          isA<WeiyueException>().having((e) => e.message, 'message', '请先登录'),
        ),
      );
      expect(adapter.requests, isEmpty);
    });

    test('服务端 ok=0 带 msg：原样抛出', () async {
      final (_, svc) = await rig(body: {'ok': 0, 'msg': 'FAKE 内容含敏感词'});
      await expectLater(
        svc.publishStatus('x'),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            'FAKE 内容含敏感词',
          ),
        ),
      );
    });
  });

  group('uploadPicture 上传形态（upload.php 分支实证）', () {
    Future<(_CaptureAdapter, WeiyueService)> rig({
      required Future<ResponseBody> Function(RequestOptions) handler,
      bool loggedIn = true,
    }) async {
      final adapter = _CaptureAdapter(handler);
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: await _session(loggedIn: loggedIn),
      );
      return (adapter, svc);
    }

    test('成功：请求形态逐项 + 返回 pic.pid', () async {
      final (adapter, svc) = await rig(
        handler: (opt) async => jsonBody({
          'ret': true,
          'pic': {'pid': 'FAKE_PID_X'},
        }),
      );
      final pid = await svc.uploadPicture(_knownBytes);
      expect(pid, 'FAKE_PID_X');

      final opt = adapter.requests.single;
      expect(opt.method, 'POST');
      expect(opt.uri.host, 'picupload.weibo.com');
      expect(opt.uri.path, '/interface/upload.php');
      final q = opt.uri.queryParameters;
      expect(q['file_source'], '1');
      // cs/raw_md5 用 "123456789" 的公开已知校验值
      expect(q['cs'], '3421780262');
      expect(q['ent'], 'miniblog');
      expect(q['appid'], '339644097');
      expect(q['uid'], '777');
      expect(q['raw_md5'], '25f9e794323b453885f5181f1b624d0b');
      expect(q['ori'], '1');
      expect(q['pri'], '0');
      expect(q['file_size'], '9');
      expect(int.tryParse(q['request_id'] ?? ''), isNotNull);
      // 水印参数无从得知（页面配置），不带
      expect(q.containsKey('mpos'), isFalse);
      expect(q.containsKey('nick'), isFalse);

      // 请求体是原始字节、octet-stream；不带 XSRF 与 X-Requested-With
      expect(adapter.byteBodies.single, _knownBytes);
      expect(
        _headerOf(opt, 'content-type'),
        startsWith('application/octet-stream'),
      );
      expect(_headerOf(opt, 'x-xsrf-token'), isNull);
      expect(_headerOf(opt, 'x-requested-with'), isNull);
      expect(_headerOf(opt, 'cookie'), contains('SUB=FAKE_PC_SUB'));
    });

    test('ret=false errno=-1：抛主包错误表文案', () async {
      final (_, svc) = await rig(
        handler: (opt) async => jsonBody({'ret': false, 'errno': -1}),
      );
      await expectLater(
        svc.uploadPicture(_knownBytes),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            '上传图片失败：没有登录（-1）',
          ),
        ),
      );
    });

    test('ret=false errno=9：上传MIME类型不支持', () async {
      final (_, svc) = await rig(
        handler: (opt) async => jsonBody({'ret': false, 'errno': 9}),
      );
      await expectLater(
        svc.uploadPicture(_knownBytes),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            '上传图片失败：上传MIME类型不支持（9）',
          ),
        ),
      );
    });

    test('响应无 pic.pid：抛未返回图片 id', () async {
      final (_, svc) = await rig(
        handler: (opt) async => jsonBody({'ret': true, 'pic': {}}),
      );
      await expectLater(
        svc.uploadPicture(_knownBytes),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('未返回图片 id'),
          ),
        ),
      );
    });

    test('非 JSON 响应（HTML）：抛带正文指纹的错误', () async {
      final (_, svc) = await rig(
        handler: (opt) async => ResponseBody.fromString(
          '<html><head><title>FAKE页</title></head></html>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        ),
      );
      await expectLater(
        svc.uploadPicture(_knownBytes),
        throwsA(
          isA<WeiyueException>().having(
            (e) => e.message,
            'message',
            contains('接口返回非 JSON'),
          ),
        ),
      );
    });

    test('未登录：抛「请先登录」，adapter 零请求', () async {
      final (adapter, svc) = await rig(
        handler: (opt) async => jsonBody({
          'ret': true,
          'pic': {'pid': 'x'},
        }),
        loggedIn: false,
      );
      await expectLater(
        svc.uploadPicture(_knownBytes),
        throwsA(
          isA<WeiyueException>().having((e) => e.message, 'message', '请先登录'),
        ),
      );
      expect(adapter.requests, isEmpty);
    });
  });
}
