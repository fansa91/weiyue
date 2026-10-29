import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 登录资料补全 + 我的关注列表的服务层测试。
/// fixture（my_profile_info / my_profile_detail / following_friends）
/// 均按 WEIBO_API.md 记载的响应结构构造（非真实抓取），Cookie 值
/// 均为假的合成串（FAKE_*）；登录态真实行为待用户真机验证。
class _Visitor extends VisitorService {
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
  ]);
  return s;
}

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('getMyProfile', () {
    test('info 全字段解析 + detail 合并 gender/birthday（构造 fixture）', () async {
      final session = await _sessionWithCookies();
      final adapter = FakeAdapter((opt) async {
        switch (opt.uri.path) {
          case '/ajax/profile/info':
            expect(opt.queryParameters['uid'], '777');
            return jsonBody(_fixture('my_profile_info.json'));
          case '/ajax/profile/detail':
            return jsonBody(_fixture('my_profile_detail.json'));
          default:
            return jsonBody({'ok': 1});
        }
      });
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      final user = await svc.getMyProfile('777');
      expect(user.id, 777);
      expect(user.screenName, '构造测试本人');
      // avatar_large 优先于 profile_image_url
      expect(user.avatar, 'https://example.com/me_large.jpg');
      expect(user.verified, isTrue);
      expect(user.verifiedReason, '构造认证说明');
      expect(user.description, '这是构造的本人简介');
      expect(user.followersCount, 123456);
      expect(user.followersCountStr, '12.3万');
      expect(user.followersDisplay, '12.3万');
      expect(user.friendsCount, 321);
      expect(user.statusesCount, 4567);
      expect(user.location, '上海');
      expect(user.coverImage, 'https://example.com/cover.jpg');
      expect(user.coverImagePhone, 'https://example.com/cover_phone.jpg');
      expect(user.bestCover, 'https://example.com/cover_phone.jpg');
      // detail 合并进来的扩展字段
      expect(user.gender, 'f');
      expect(user.birthday, '1990-01-02 摩羯座');
    });

    test('detail 拉取失败（HTTP 500）时主资料照常返回', () async {
      final session = await _sessionWithCookies();
      final adapter = FakeAdapter((opt) async {
        if (opt.uri.path == '/ajax/profile/info') {
          return jsonBody(_fixture('my_profile_info.json'));
        }
        return jsonBody({'ok': 0}, status: 500);
      });
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      final user = await svc.getMyProfile('777');
      expect(user.screenName, '构造测试本人');
      expect(user.followersCount, 123456);
      expect(user.gender, '');
      expect(user.birthday, '');
    });
  });

  group('getMyFollowing', () {
    test('data.users + data.total_number 解析（构造 fixture）', () async {
      final session = await _sessionWithCookies();
      final adapter = FakeAdapter(
        (opt) async => jsonBody(_fixture('following_friends.json')),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      final r = await svc.getMyFollowing('777');
      expect(adapter.requests.single.uri.path, '/ajax/friendships/friends');
      final q = adapter.requests.single.queryParameters;
      expect(q['uid'], '777');
      expect(q['relate'], 'follows');
      expect(q['page'], 1);
      expect(q['count'], 20);
      expect(r.total, 3);
      expect(r.users.length, 3);
      expect(r.users[0].screenName, '关注博主甲');
      expect(r.users[0].description, '甲的简介');
      expect(r.users[0].followersCount, 2048);
      expect(r.users[1].verified, isTrue);
      expect(r.users[1].avatar, 'https://example.com/b_large.jpg');
      expect(r.users[2].followersCountStr, '10万');
    });

    test('顶层 users/total_number 形态也兼容', () async {
      final session = await _sessionWithCookies();
      final adapter = FakeAdapter(
        (opt) async => jsonBody({
          'ok': 1,
          'total_number': 1,
          'users': [
            {'id': 6001, 'screen_name': '顶层形态博主'},
          ],
        }),
      );
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      final r = await svc.getMyFollowing('777', page: 2);
      expect(adapter.requests.single.queryParameters['page'], 2);
      expect(r.total, 1);
      expect(r.users.single.screenName, '顶层形态博主');
    });

    test('访客形态空对象 {} → 空列表、总数 0，不崩', () async {
      final session = await _sessionWithCookies();
      final adapter = FakeAdapter((opt) async => jsonBody(<String, dynamic>{}));
      final svc = WeiyueService(
        _Visitor(),
        pcDio: _dio(adapter),
        session: session,
      );

      final r = await svc.getMyFollowing('777');
      expect(r.users, isEmpty);
      expect(r.total, 0);
    });
  });

  test('probeSession 末尾自动补拉资料并存入会话', () async {
    final session = await _sessionWithCookies();
    final pcAdapter = FakeAdapter((opt) async {
      switch (opt.uri.path) {
        case '/ajax/setting/getBasicInfo':
          return jsonBody(_fixture('current_user.json'));
        case '/ajax/profile/info':
          return jsonBody(_fixture('my_profile_info.json'));
        case '/ajax/profile/detail':
          return jsonBody(_fixture('my_profile_detail.json'));
        default:
          return jsonBody({'ok': 1});
      }
    });
    final mAdapter = FakeAdapter(
      (opt) async => jsonBody({'ok': 1, 'data': []}),
    );
    final svc = WeiyueService(
      _Visitor(),
      pcDio: _dio(pcAdapter),
      mDio: _dio(mAdapter),
      session: session,
    );

    final probe = await svc.probeSession();
    expect(probe.pcUnlocked, isTrue);
    // 探活补拉：会话里已有完整资料（含 detail 合并字段）
    final profile = session.profile;
    expect(profile, isNotNull);
    expect(profile!.screenName, '构造测试本人');
    expect(profile.followersCount, 123456);
    expect(profile.gender, 'f');
    // saveProfile 同步了探活字段
    expect(session.screenName, '构造测试本人');
    expect(session.avatar, 'https://example.com/me_large.jpg');
  });
}
