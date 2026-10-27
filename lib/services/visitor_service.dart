import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 两栈访客身份（Sina Visitor System）。
///
/// 流程（见 WEIBO_API.md「访客系统」节）：
/// 1. POST {passport}/visitor/genvisitor，form cb=gen_callback&fp=<指纹JSON>，
///    正则从 JSONP 里取 tid；
/// 2. GET {passport}/visitor/visitor?entry=miniblog&a=incarnate&t={tid}&w=2&c=095
///    &gc=&cb=cross_domain&from=weibo&_rand=<随机>，正则取 sub/subp。
/// PC 栈 passport=passport.weibo.com，m 栈 passport=visitor.passport.weibo.cn，
/// 两栈各存一对 SUB/SUBP 到 SharedPreferences。
enum WbStack { pc, m }

class VisitorIdentity {
  final String sub;
  final String subp;
  final int updatedAt; // ms epoch
  const VisitorIdentity(this.sub, this.subp, this.updatedAt);
  bool get isValid => sub.isNotEmpty && subp.isNotEmpty;
  String get cookie => 'SUB=$sub; SUBP=$subp';
}

class VisitorService extends ChangeNotifier {
  static const pcPassport = 'https://passport.weibo.com';
  static const mPassport = 'https://visitor.passport.weibo.cn';

  static const pcUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
  static const mUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

  final Dio _dio;

  /// [dio] 可注入（测试用假 adapter）；默认关跟随重定向、纯文本响应。
  VisitorService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 25),
              followRedirects: false,
              validateStatus: (s) => s != null && s < 400,
              responseType: ResponseType.plain,
            ));

  /// genvisitor 的 JSONP 里提取 tid；异常响应返回 null。
  static String? extractTid(String body) =>
      RegExp(r'"tid"\s*:\s*"([^"]+)"').firstMatch(body)?.group(1);

  /// incarnate 的 JSONP 里提取 sub；异常响应返回 null。
  static String? extractSub(String body) =>
      RegExp(r'"sub"\s*:\s*"([^"]+)"').firstMatch(body)?.group(1);

  /// incarnate 的 JSONP 里提取 subp；异常响应返回 null。
  static String? extractSubp(String body) =>
      RegExp(r'"subp"\s*:\s*"([^"]+)"').firstMatch(body)?.group(1);

  final Map<WbStack, VisitorIdentity?> _cache = {WbStack.pc: null, WbStack.m: null};
  final Map<WbStack, Future<VisitorIdentity>> _inflight = {};
  bool _loaded = false;

  String uaOf(WbStack stack) => stack == WbStack.pc ? pcUa : mUa;
  String passportOf(WbStack stack) =>
      stack == WbStack.pc ? pcPassport : mPassport;

  VisitorIdentity? identityOf(WbStack stack) => _cache[stack];
  bool hasIdentity(WbStack stack) => _cache[stack]?.isValid ?? false;

  String _key(WbStack stack, String part) => 'visitor_${stack.name}_$part';

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    for (final stack in WbStack.values) {
      final sub = prefs.getString(_key(stack, 'sub')) ?? '';
      final subp = prefs.getString(_key(stack, 'subp')) ?? '';
      final ts = prefs.getInt(_key(stack, 'ts')) ?? 0;
      if (sub.isNotEmpty) _cache[stack] = VisitorIdentity(sub, subp, ts);
    }
  }

  /// 取访客身份：有缓存直接用；没有（或 force）走 genvisitor→incarnate 换新的。
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async {
    await _load();
    final cached = _cache[stack];
    if (!force && cached != null && cached.isValid) return cached;
    final running = _inflight[stack];
    if (running != null) return running;
    final fut = _fetch(stack);
    _inflight[stack] = fut;
    try {
      return await fut;
    } finally {
      _inflight.remove(stack);
    }
  }

  Future<VisitorIdentity> refresh(WbStack stack) => ensure(stack, force: true);

  Future<void> refreshAll() async {
    await Future.wait([refresh(WbStack.pc), refresh(WbStack.m)]);
    notifyListeners();
  }

  Future<VisitorIdentity> _fetch(WbStack stack) async {
    final passport = passportOf(stack);
    final ua = uaOf(stack);
    // 1) genvisitor 取 tid
    final fp = {
      'os': stack == WbStack.pc ? '1' : '2',
      'browser': stack == WbStack.pc ? 'Chrome130.0.0.0' : 'Safari17.0',
      'fonts': '0',
      'plugins': '',
      'aid': '',
      'device': '',
      'from': 'weibo',
      'ua': ua,
      'webdriver': false,
      'visited': true,
      'version': '0.0.7',
    };
    final form = 'cb=gen_callback&fp=${Uri.encodeComponent(jsonEncode(fp))}';
    final genResp = await _dio.post<String>(
      '$passport/visitor/genvisitor',
      data: form,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {
          'User-Agent': ua,
          'Referer':
              stack == WbStack.pc ? 'https://weibo.com/' : 'https://m.weibo.cn/',
        },
      ),
    );
    final tid = extractTid(genResp.data ?? '');
    if (tid == null) {
      throw StateError('genvisitor 未返回 tid: ${genResp.data}');
    }

    // 2) incarnate 换 SUB/SUBP
    final rand = Random().nextDouble().toString();
    final incUrl = '$passport/visitor/visitor?entry=miniblog&a=incarnate'
        '&t=${Uri.encodeComponent(tid)}&w=2&c=095&gc=&cb=cross_domain'
        '&from=weibo&_rand=$rand';
    final incResp = await _dio.get<String>(
      incUrl,
      options: Options(headers: {
        'User-Agent': ua,
        'Referer':
            stack == WbStack.pc ? 'https://weibo.com/' : 'https://m.weibo.cn/',
      }),
    );
    final body = incResp.data ?? '';
    final sub = extractSub(body);
    final subp = extractSubp(body);
    if (sub == null || subp == null) {
      throw StateError('incarnate 未返回 sub/subp: $body');
    }
    final identity =
        VisitorIdentity(sub, subp, DateTime.now().millisecondsSinceEpoch);
    _cache[stack] = identity;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(stack, 'sub'), sub);
    await prefs.setString(_key(stack, 'subp'), subp);
    await prefs.setInt(_key(stack, 'ts'), identity.updatedAt);
    notifyListeners();
    return identity;
  }
}
