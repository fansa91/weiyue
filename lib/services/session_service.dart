import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'visitor_service.dart';

/// 一条从 WebView 收割到的 Cookie（与 WebView 插件解耦的纯数据，便于单测）。
class HarvestedCookie {
  final String name;
  final String value;

  /// 归一化后的域名（小写、无开头点），如 `weibo.com`、`passport.weibo.com`。
  final String domain;

  const HarvestedCookie({
    required this.name,
    required this.value,
    required this.domain,
  });
}

/// 登录会话：WebView 官方登录后收割的 Cookie 整表、当前用户信息与两栈探活结果。
///
/// 安全约束（硬性）：
/// - 登录由用户本人在 WebView 里完成，本类不接触账号密码；
/// - Cookie 只存本机 SharedPreferences，不进仓库/fixture；
/// - 本类任何路径都不打印、不记录 Cookie 值。
class SessionService extends ChangeNotifier {
  static const _keyCookies = 'weiyue_session_cookies_v1';
  static const _keyUser = 'weiyue_session_user_v1';
  static const _keyProbe = 'weiyue_session_probe_v1';
  static const _keyExpired = 'weiyue_session_expired_v1';

  /// domain -> {name: value}
  Map<String, Map<String, String>> _cookies = {};
  String _uid = '';
  String _screenName = '';
  String _avatar = '';
  bool? _pcUnlocked;
  bool? _mUnlocked;
  bool _expired = false;
  bool _loaded = false;

  /// 是否存有登录会话（任一域下有非空 SUB 即算）。
  bool get isLoggedIn =>
      _cookies.values.any((m) => (m['SUB'] ?? '').isNotEmpty);

  /// 登录态被服务端明确拒绝过（探活失败或请求中收到未登录信号）。
  bool get expired => _expired;

  bool? get pcUnlocked => _pcUnlocked;
  bool? get mUnlocked => _mUnlocked;

  String get uid => _uid;
  String get screenName => _screenName;
  String get avatar => _avatar;

  static String normalizeDomain(String raw) {
    var d = raw.trim().toLowerCase();
    if (d.startsWith('.')) d = d.substring(1);
    return d;
  }

  /// 把收割列表整理成 domain -> {name: value} 存储表（同名后到覆盖）。
  static Map<String, Map<String, String>> buildStore(
    List<HarvestedCookie> cookies,
  ) {
    final store = <String, Map<String, String>>{};
    for (final c in cookies) {
      final domain = normalizeDomain(c.domain);
      if (domain.isEmpty || c.name.isEmpty || c.value.isEmpty) continue;
      (store[domain] ??= {})[c.name] = c.value;
    }
    return store;
  }

  static bool storeHasSub(Map<String, Map<String, String>> store) =>
      store.values.any((m) => (m['SUB'] ?? '').isNotEmpty);

  /// passport 域的 Cookie 不外发给业务接口（只留存，不组装进请求头）。
  static bool _isPassportDomain(String domain) =>
      domain == 'passport.weibo.com' ||
      domain.endsWith('.passport.weibo.com') ||
      domain == 'passport.weibo.cn' ||
      domain.endsWith('.passport.weibo.cn');

  static bool _domainMatches(String cookieDomain, String suffix) =>
      cookieDomain == suffix || cookieDomain.endsWith('.$suffix');

  /// 按栈组装 Cookie 头：PC 栈只用 weibo.com 域、m 栈只用 weibo.cn 域，
  /// passport 域一律排除。无可用 Cookie 返回 null。
  String? cookieHeaderFor(WbStack stack) {
    final suffix = stack == WbStack.pc ? 'weibo.com' : 'weibo.cn';
    final pairs = <String>[];
    var hasSub = false;
    for (final entry in _cookies.entries) {
      if (_isPassportDomain(entry.key)) continue;
      if (!_domainMatches(entry.key, suffix)) continue;
      for (final kv in entry.value.entries) {
        pairs.add('${kv.key}=${kv.value}');
        if (kv.key == 'SUB' && kv.value.isNotEmpty) hasSub = true;
      }
    }
    if (pairs.isEmpty || !hasSub) return null;
    return pairs.join('; ');
  }

  /// 该栈是否有可用的登录 Cookie（有 SUB 才算，请求层据此决定走登录态）。
  bool hasUsableCookie(WbStack stack) => cookieHeaderFor(stack) != null;

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyCookies);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _cookies = decoded.map((k, v) {
            final inner = v is Map
                ? v.map((ik, iv) => MapEntry('$ik', '$iv'))
                : <String, String>{};
            return MapEntry(normalizeDomain('$k'), inner);
          });
        }
      } catch (_) {
        _cookies = {};
      }
    }
    final userRaw = prefs.getString(_keyUser);
    if (userRaw != null && userRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(userRaw);
        if (decoded is Map) {
          _uid = '${decoded['uid'] ?? ''}';
          _screenName = '${decoded['screen_name'] ?? ''}';
          _avatar = '${decoded['avatar'] ?? ''}';
        }
      } catch (_) {}
    }
    final probeRaw = prefs.getString(_keyProbe);
    if (probeRaw != null && probeRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(probeRaw);
        if (decoded is Map) {
          _pcUnlocked = decoded['pc'] is bool ? decoded['pc'] as bool : null;
          _mUnlocked = decoded['m'] is bool ? decoded['m'] as bool : null;
        }
      } catch (_) {}
    }
    _expired = prefs.getBool(_keyExpired) ?? false;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCookies, jsonEncode(_cookies));
    await prefs.setString(
      _keyUser,
      jsonEncode({'uid': _uid, 'screen_name': _screenName, 'avatar': _avatar}),
    );
    await prefs.setString(
      _keyProbe,
      jsonEncode({'pc': _pcUnlocked, 'm': _mUnlocked}),
    );
    await prefs.setBool(_keyExpired, _expired);
  }

  /// 保存一次收割结果（与已有表合并，同 domain+name 覆盖）。
  Future<void> saveHarvest(List<HarvestedCookie> cookies) async {
    await init();
    final incoming = buildStore(cookies);
    for (final entry in incoming.entries) {
      (_cookies[entry.key] ??= {}).addAll(entry.value);
    }
    await _persist();
    notifyListeners();
  }

  /// 保存探活结果（用户信息 + 两栈是否解锁）。任一栈解锁即清除过期标记。
  Future<void> saveProbe({
    String uid = '',
    String screenName = '',
    String avatar = '',
    bool? pcUnlocked,
    bool? mUnlocked,
  }) async {
    await init();
    if (uid.isNotEmpty) _uid = uid;
    if (screenName.isNotEmpty) _screenName = screenName;
    if (avatar.isNotEmpty) _avatar = avatar;
    if (pcUnlocked != null) _pcUnlocked = pcUnlocked;
    if (mUnlocked != null) _mUnlocked = mUnlocked;
    if ((pcUnlocked ?? false) || (mUnlocked ?? false)) _expired = false;
    await _persist();
    notifyListeners();
  }

  /// 标记登录已过期（服务端明确未登录信号时由请求层调用）。
  /// 只改标记不删 Cookie：当前请求由请求层回退访客态完成，
  /// 账号区据此提示重新登录。
  void markExpired() {
    if (!isLoggedIn || _expired) return;
    _expired = true;
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_keyExpired, true),
    );
    notifyListeners();
  }

  /// 退出登录：清掉全部本地会话数据，回到访客态。
  Future<void> clear() async {
    _cookies = {};
    _uid = '';
    _screenName = '';
    _avatar = '';
    _pcUnlocked = null;
    _mUnlocked = null;
    _expired = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCookies);
    await prefs.remove(_keyUser);
    await prefs.remove(_keyProbe);
    await prefs.remove(_keyExpired);
    notifyListeners();
  }
}
