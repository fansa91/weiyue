import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';

/// 会话存储/组装逻辑单测。所有 Cookie 值都是假的合成串（FAKE_*），
/// 与任何真实账号无关；真实 Cookie 只存在用户设备本地、从不进测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  HarvestedCookie c(String name, String value, String domain) =>
      HarvestedCookie(name: name, value: value, domain: domain);

  test('buildStore：域名归一化（去点/小写）、空值丢弃、同名覆盖', () {
    final store = SessionService.buildStore([
      c('SUB', 'FAKE_A', '.Weibo.COM'),
      c('SUBP', 'FAKE_B', 'weibo.com'),
      c('SUB', 'FAKE_C', 'weibo.com'), // 后到覆盖
      c('', 'FAKE_X', 'weibo.com'),
      c('EMPTY', '', 'weibo.com'),
      c('X', 'FAKE_Y', ''),
    ]);
    expect(store.keys, ['weibo.com']);
    expect(store['weibo.com'], {'SUB': 'FAKE_C', 'SUBP': 'FAKE_B'});
  });

  test('storeHasSub：任一域有非空 SUB 才算', () {
    expect(SessionService.storeHasSub({}), isFalse);
    expect(
      SessionService.storeHasSub({
        'weibo.cn': {'SUBP': 'FAKE_B'},
      }),
      isFalse,
    );
    expect(
      SessionService.storeHasSub({
        'weibo.cn': {'SUB': 'FAKE_A'},
      }),
      isTrue,
    );
  });

  test('cookieHeaderFor：按栈选域，passport 域不外发', () async {
    final s = SessionService();
    await s.saveHarvest([
      c('SUB', 'FAKE_PC_SUB', 'weibo.com'),
      c('SUBP', 'FAKE_PC_SUBP', 'weibo.com'),
      c('ALF', 'FAKE_ALF', 'www.weibo.com'),
      c('SRF', 'FAKE_PASSPORT', 'passport.weibo.com'),
      c('SUB', 'FAKE_M_SUB', 'm.weibo.cn'),
      c('SUBP', 'FAKE_M_SUBP', 'weibo.cn'),
      c('SRF', 'FAKE_PASSPORT_CN', 'passport.weibo.cn'),
      c('SINACID', 'FAKE_SINA', 'login.sina.com.cn'),
    ]);
    final pc = s.cookieHeaderFor(WbStack.pc)!;
    expect(pc, contains('SUB=FAKE_PC_SUB'));
    expect(pc, contains('SUBP=FAKE_PC_SUBP'));
    expect(pc, contains('ALF=FAKE_ALF'));
    expect(pc, isNot(contains('PASSPORT')));
    expect(pc, isNot(contains('FAKE_M_SUB')));
    expect(pc, isNot(contains('SINACID')));

    final m = s.cookieHeaderFor(WbStack.m)!;
    expect(m, contains('SUB=FAKE_M_SUB'));
    expect(m, contains('SUBP=FAKE_M_SUBP'));
    expect(m, isNot(contains('PASSPORT')));
    expect(m, isNot(contains('FAKE_PC_SUB')));
    expect(s.hasUsableCookie(WbStack.pc), isTrue);
    expect(s.hasUsableCookie(WbStack.m), isTrue);
  });

  test('cookieHeaderFor：该栈无 SUB 返回 null（回退访客）', () async {
    final s = SessionService();
    await s.saveHarvest([c('SUB', 'FAKE_ONLY_PC', 'weibo.com')]);
    expect(s.cookieHeaderFor(WbStack.m), isNull);
    expect(s.hasUsableCookie(WbStack.m), isFalse);
    expect(s.hasUsableCookie(WbStack.pc), isTrue);
  });

  test('持久化往返：新实例 init 后恢复会话与探活结果', () async {
    final s1 = SessionService();
    await s1.saveHarvest([c('SUB', 'FAKE_PERSIST', 'weibo.com')]);
    await s1.saveProbe(
      uid: '777',
      screenName: '构造用户',
      avatar: 'https://example.com/me.jpg',
      pcUnlocked: true,
      mUnlocked: false,
    );
    expect(s1.isLoggedIn, isTrue);
    expect(s1.expired, isFalse);

    final s2 = SessionService();
    await s2.init();
    expect(s2.isLoggedIn, isTrue);
    expect(s2.uid, '777');
    expect(s2.screenName, '构造用户');
    expect(s2.pcUnlocked, isTrue);
    expect(s2.mUnlocked, isFalse);
    expect(s2.cookieHeaderFor(WbStack.pc), contains('SUB=FAKE_PERSIST'));

    await s2.clear();
    final s3 = SessionService();
    await s3.init();
    expect(s3.isLoggedIn, isFalse);
    expect(s3.pcUnlocked, isNull);
  });

  test('markExpired：置位并持久化；saveProbe 解锁后清除', () async {
    final s = SessionService();
    await s.saveHarvest([c('SUB', 'FAKE_EXP', 'weibo.com')]);
    s.markExpired();
    expect(s.expired, isTrue);
    await pumpEventQueue();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('weiyue_session_expired_v1'), isTrue);

    await s.saveProbe(pcUnlocked: true);
    expect(s.expired, isFalse);
  });
}
