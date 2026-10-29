import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/session_service.dart';

/// 本人完整资料的会话持久化单测：只存解析后的字段（WbUser.toJson），
/// 不存原始接口 JSON；重启（新 SessionService 实例 init）后可读回。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const me = WbUser(
    id: 777,
    screenName: '构造测试本人',
    avatar: 'https://example.com/me_large.jpg',
    verified: true,
    verifiedType: 0,
    verifiedReason: '构造认证说明',
    description: '这是构造的本人简介',
    followersCount: 123456,
    followersCountStr: '12.3万',
    friendsCount: 321,
    statusesCount: 4567,
    location: '上海',
    gender: 'f',
    birthday: '1990-01-02 摩羯座',
    coverImage: 'https://example.com/cover.jpg',
    coverImagePhone: 'https://example.com/cover_phone.jpg',
  );

  test('saveProfile 持久化：新实例 init 后资料字段全量读回', () async {
    final s = SessionService();
    await s.saveProfile(me);
    expect(s.profile?.screenName, '构造测试本人');
    // saveProfile 同步探活三字段
    expect(s.uid, '777');
    expect(s.screenName, '构造测试本人');
    expect(s.avatar, 'https://example.com/me_large.jpg');

    final s2 = SessionService();
    await s2.init();
    final p = s2.profile;
    expect(p, isNotNull);
    expect(p!.id, 777);
    expect(p.screenName, '构造测试本人');
    expect(p.avatar, 'https://example.com/me_large.jpg');
    expect(p.verified, isTrue);
    expect(p.verifiedReason, '构造认证说明');
    expect(p.description, '这是构造的本人简介');
    expect(p.followersCount, 123456);
    expect(p.friendsCount, 321);
    expect(p.statusesCount, 4567);
    expect(p.location, '上海');
    expect(p.gender, 'f');
    expect(p.birthday, '1990-01-02 摩羯座');
    expect(p.bestCover, 'https://example.com/cover_phone.jpg');
  });

  test('clear 后资料一并清除', () async {
    final s = SessionService();
    await s.saveProfile(me);
    expect(s.profile, isNotNull);
    await s.clear();
    expect(s.profile, isNull);

    final s2 = SessionService();
    await s2.init();
    expect(s2.profile, isNull);
  });

  test('WbUser toJson/fromJson 往返不丢字段', () {
    final back = WbUser.fromJson(me.toJson());
    expect(back.id, me.id);
    expect(back.screenName, me.screenName);
    expect(back.avatar, me.avatar);
    expect(back.verifiedType, me.verifiedType);
    expect(back.followersCountStr, me.followersCountStr);
    expect(back.gender, me.gender);
    expect(back.birthday, me.birthday);
    expect(back.coverImage, me.coverImage);
    expect(back.coverImagePhone, me.coverImagePhone);
  });
}
