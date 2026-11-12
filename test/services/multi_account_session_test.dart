import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/services/session_service.dart';
import 'package:weiyue/services/visitor_service.dart';

/// 多账号会话单测（真 SessionService + 内存 SharedPreferences，
/// Cookie 全是 FAKE 串）：入表/切换隔离/添加流程/删除/退出只删
/// 当前/重启后恢复。实时会话仍是单份键，账号表是快照互换。
Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<SessionService> _loginAs(
  SessionService s,
  String uid,
  String name,
  String sub,
) async {
  await s.saveHarvest([
    HarvestedCookie(name: 'SUB', value: sub, domain: 'weibo.com'),
    const HarvestedCookie(
      name: 'XSRF-TOKEN',
      value: 'FAKE_XSRF',
      domain: 'weibo.com',
    ),
  ]);
  await s.saveProbe(uid: uid, screenName: name, pcUnlocked: true);
  await _flush();
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('首个账号探活后自动入表，重启后账号表与当前账号都在', () async {
    final s = await _loginAs(SessionService(), '111', '甲号', 'FAKE_SUB_A');
    expect(s.accounts, hasLength(1));
    expect(s.accounts.single.uid, '111');
    expect(s.accounts.single.screenName, '甲号');
    expect(s.activeUid, '111');

    final s2 = SessionService();
    await s2.init();
    expect(s2.accounts, hasLength(1));
    expect(s2.activeUid, '111');
    expect(s2.screenName, '甲号');
    expect(s2.cookieHeaderFor(WbStack.pc), contains('FAKE_SUB_A'));
  });

  test('添加账号：beginAddAccount 清实时会话但保留表，新账号入表成当前', () async {
    final s = await _loginAs(SessionService(), '111', '甲号', 'FAKE_SUB_A');
    await s.beginAddAccount();
    expect(s.isLoggedIn, isFalse);
    expect(s.accounts, hasLength(1));

    await _loginAs(s, '222', '乙号', 'FAKE_SUB_B');
    expect(s.accounts.map((a) => a.uid), ['111', '222']);
    expect(s.activeUid, '222');
    expect(s.cookieHeaderFor(WbStack.pc), contains('FAKE_SUB_B'));
  });

  test('切换隔离：Cookie/昵称整体互换，互不串扰', () async {
    final s = await _loginAs(SessionService(), '111', '甲号', 'FAKE_SUB_A');
    await s.beginAddAccount();
    await _loginAs(s, '222', '乙号', 'FAKE_SUB_B');

    await s.switchAccount('111');
    expect(s.activeUid, '111');
    expect(s.screenName, '甲号');
    final headerA = s.cookieHeaderFor(WbStack.pc)!;
    expect(headerA, contains('FAKE_SUB_A'));
    expect(headerA, isNot(contains('FAKE_SUB_B')));

    await s.switchAccount('222');
    expect(s.activeUid, '222');
    expect(s.screenName, '乙号');
    expect(s.cookieHeaderFor(WbStack.pc), contains('FAKE_SUB_B'));

    // 切到不存在的账号无操作
    await s.switchAccount('999');
    expect(s.activeUid, '222');
  });

  test('删除：删非当前只缩表；删当前等同退出登录', () async {
    final s = await _loginAs(SessionService(), '111', '甲号', 'FAKE_SUB_A');
    await s.beginAddAccount();
    await _loginAs(s, '222', '乙号', 'FAKE_SUB_B');

    await s.removeAccount('111');
    expect(s.accounts.map((a) => a.uid), ['222']);
    expect(s.activeUid, '222');
    expect(s.isLoggedIn, isTrue);

    await s.removeAccount('222');
    expect(s.accounts, isEmpty);
    expect(s.isLoggedIn, isFalse);
  });

  test('退出登录只移除当前账号，其他账号可切回', () async {
    final s = await _loginAs(SessionService(), '111', '甲号', 'FAKE_SUB_A');
    await s.beginAddAccount();
    await _loginAs(s, '222', '乙号', 'FAKE_SUB_B');

    await s.clear();
    expect(s.isLoggedIn, isFalse);
    expect(s.accounts.map((a) => a.uid), ['111']);

    await s.switchAccount('111');
    expect(s.isLoggedIn, isTrue);
    expect(s.screenName, '甲号');
    expect(s.cookieHeaderFor(WbStack.pc), contains('FAKE_SUB_A'));
  });

  test('过期标记随快照走：切走再切回仍是过期态', () async {
    final s = await _loginAs(SessionService(), '111', '甲号', 'FAKE_SUB_A');
    await s.beginAddAccount();
    await _loginAs(s, '222', '乙号', 'FAKE_SUB_B');
    await s.switchAccount('111');
    s.markExpired();
    await _flush();
    expect(s.accounts.firstWhere((a) => a.uid == '111').expired, isTrue);

    await s.switchAccount('222');
    expect(s.expired, isFalse);
    await s.switchAccount('111');
    expect(s.expired, isTrue);
  });
}
