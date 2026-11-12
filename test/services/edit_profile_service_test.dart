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

/// 编辑资料服务层测试（全走假 adapter，绝不碰真实账号）：
/// getBasicInfo 解析（data 本体 + 顶层地区字典）、updateProfileBasic
/// 逐字段表单、updateProfileExtend 的 {single}，逐字对齐主包
/// 编辑资料页各 use* 钩子的保存调用点。
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

Future<SessionService> _session() async {
  final s = SessionService();
  await s.saveHarvest([
    const HarvestedCookie(name: 'SUB', value: 'FAKE_PC_SUB', domain: 'weibo.com'),
    const HarvestedCookie(
      name: 'XSRF-TOKEN',
      value: 'FAKE_XSRF_TOKEN',
      domain: 'weibo.com',
    ),
  ]);
  await s.saveProbe(uid: '777', screenName: 'FAKE 号', pcUnlocked: true);
  return s;
}

Map<String, String> _formOf(Uint8List body) =>
    Uri.splitQueryString(utf8.decode(body));

/// getBasicInfo 响应（结构派生：字段集出自主包编辑页逐字读取点，
/// 地区字典形态按组件 useArea 的索引方式构造）。
Map<String, dynamic> _basicInfoBody() => {
      'ok': 1,
      'data': {
        'screen_name': '旧昵称',
        'description': '旧简介',
        'gender': 'f',
        'birthday': '1995-03-04',
        'birthday_visible': 0,
        'province': '11',
        'city': '1',
        'single': '1',
      },
      'province': {'11': '北京', '31': '上海'},
      'city': {
        '北京': {'1': '东城区', '2': '西城区'},
        '上海': {'1': '黄浦区'},
      },
    };

Future<(_CaptureAdapter, WeiyueService)> _rig({
  required Object Function(RequestOptions opt) body,
}) async {
  final adapter = _CaptureAdapter((opt) async => jsonBody(body(opt)));
  final svc = WeiyueService(
    _Visitor(),
    pcDio: _dio(adapter),
    session: await _session(),
  );
  return (adapter, svc);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('getBasicInfo：路径 + data 本体与地区字典解析', () async {
    final (adapter, svc) = await _rig(body: (_) => _basicInfoBody());
    final info = await svc.getProfileBasicInfo();
    final opt = adapter.requests.single;
    expect(opt.method, 'GET');
    expect(opt.uri.path, '/ajax/setting/getBasicInfo');
    expect(info.screenName, '旧昵称');
    expect(info.description, '旧简介');
    expect(info.gender, 'f');
    expect(info.birthday, '1995-03-04');
    expect(info.province, '11');
    expect(info.city, '1');
    expect(info.single, '1');
    expect(info.provinceName, '北京');
    expect(info.cityName, '东城区');
    expect(info.cityOptions, {'1': '东城区', '2': '西城区'});
  });

  test('getBasicInfo：ok=0 抛服务端消息', () async {
    final (_, svc) = await _rig(body: (_) => {'ok': 0, 'msg': '参数错误'});
    await expectLater(
      svc.getProfileBasicInfo(),
      throwsA(
        isA<WeiyueException>().having(
          (e) => e.message,
          'message',
          contains('参数错误'),
        ),
      ),
    );
  });

  test('updateProfileBasic：昵称表单 {screen_name} 逐字 + 回 msg', () async {
    final (adapter, svc) = await _rig(
      body: (_) => {'ok': 1, 'msg': '昵称修改成功'},
    );
    final msg = await svc.updateProfileBasic({'screen_name': '新昵称'});
    expect(adapter.requests.single.uri.path, '/ajax/setting/updateProfileBasic');
    expect(_formOf(adapter.byteBodies.single), {'screen_name': '新昵称'});
    expect(msg, '昵称修改成功');
  });

  test('updateProfileBasic：简介表单带 desc_empty（清空时 true）', () async {
    final (adapter, svc) = await _rig(body: (_) => {'ok': 1});
    await svc.updateProfileBasic({'description': '', 'desc_empty': true});
    expect(_formOf(adapter.byteBodies.single), {
      'description': '',
      'desc_empty': 'true',
    });
  });

  test('updateProfileSingle：路径 updateProfileExtend + {single}', () async {
    final (adapter, svc) = await _rig(body: (_) => {'ok': 1});
    await svc.updateProfileSingle('5');
    expect(
      adapter.requests.single.uri.path,
      '/ajax/setting/updateProfileExtend',
    );
    expect(_formOf(adapter.byteBodies.single), {'single': '5'});
  });

  test('情感选项表与主包逐字一致（11 项）', () {
    expect(ProfileBasicInfo.emotionOptions, hasLength(11));
    expect(ProfileBasicInfo.emotionOptions.first.label, '单身');
    expect(ProfileBasicInfo.emotionOptions[4].label, '恋爱中');
    expect(ProfileBasicInfo.emotionOptions.last.value, '0');
  });
}
