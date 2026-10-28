import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../services/session_service.dart';
import '../services/weiyue_service.dart';

/// 清掉 WebView 自身的 Cookie 存储（退出登录时调用，与本地会话一起清）。
Future<void> clearWebViewCookies() async {
  try {
    await CookieManager.instance().deleteAllCookies();
  } catch (_) {
    // 平台不支持/插件异常时静默：本地会话已清，接口层不会再用登录态
  }
}

/// 账号登录页：内嵌官方页面，用户本人在页面内完成登录（账号/短信/扫码
/// 都走官方流程，本应用不接触账号密码），点「完成」后收割各相关域的
/// Cookie 存入本地会话，并探活两栈解锁状态。
///
/// 平台：flutter_inappwebview 覆盖 Android / iOS / macOS / Windows；
/// 其他平台（如 Linux）无实现，页面直接提示不支持。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _mHome = 'https://m.weibo.cn/';
  static const _pcHome = 'https://weibo.com/';

  /// 收割时逐个查询的 URL（CookieManager 按 URL 返回该域可见的 Cookie）。
  static const _harvestUrls = [
    'https://weibo.com/',
    'https://www.weibo.com/',
    'https://m.weibo.cn/',
    'https://weibo.cn/',
    'https://passport.weibo.com/',
    'https://passport.weibo.cn/',
    'https://visitor.passport.weibo.cn/',
    'https://login.sina.com.cn/',
    'https://sina.com.cn/',
  ];

  static bool get _supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  InAppWebViewController? _controller;
  bool _harvesting = false;
  bool _onPcSite = false;

  Future<List<HarvestedCookie>> _harvestCookies() async {
    final manager = CookieManager.instance();
    final byKey = <String, HarvestedCookie>{};
    void add(String name, String value, String domain) {
      if (name.isEmpty || value.isEmpty) return;
      final d = SessionService.normalizeDomain(domain);
      if (d.isEmpty) return;
      byKey['$d|$name'] = HarvestedCookie(name: name, value: value, domain: d);
    }

    // 先试全量（部分平台支持），再逐 URL 补齐（跨平台稳妥路径）。
    try {
      for (final c in await manager.getAllCookies()) {
        add(c.name, '${c.value}', c.domain ?? '');
      }
    } catch (_) {}
    for (final url in _harvestUrls) {
      try {
        final cookies = await manager.getCookies(url: WebUri(url));
        final host = Uri.parse(url).host;
        for (final c in cookies) {
          final d = (c.domain != null && c.domain!.isNotEmpty)
              ? c.domain!
              : host;
          add(c.name, '${c.value}', d);
        }
      } catch (_) {}
    }
    return byKey.values.toList();
  }

  Future<void> _finish() async {
    if (_harvesting) return;
    final session = context.read<SessionService>();
    final svc = context.read<WeiyueService>();
    setState(() => _harvesting = true);
    try {
      final cookies = await _harvestCookies();
      final store = SessionService.buildStore(cookies);
      if (!SessionService.storeHasSub(store)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('尚未检测到登录状态，请先在页面内完成登录再点完成')),
          );
        }
        return;
      }
      await session.saveHarvest(cookies);
      // 探活：拿到当前用户信息（取到才有）+ 两栈是否解锁
      final probe = await svc.probeSession();
      await session.saveProbe(
        uid: probe.user != null ? '${probe.user!.id}' : '',
        screenName: probe.user?.screenName ?? '',
        avatar: probe.user?.avatar ?? '',
        pcUnlocked: probe.pcUnlocked,
        mUnlocked: probe.mUnlocked,
      );
      if (!probe.pcUnlocked && !probe.mUnlocked) {
        // 收割到了 Cookie 但两栈都没认：多半是登录未真正完成或已过期
        session.markExpired();
      }
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _harvesting = false);
    }
  }

  Future<void> _openPcSite() async {
    setState(() => _onPcSite = true);
    await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(_pcHome)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('账号登录'),
        actions: [
          if (_supported && !_onPcSite)
            TextButton(
              onPressed: _harvesting ? null : _openPcSite,
              child: const Text('桌面端登录页'),
            ),
          TextButton(
            onPressed: (_supported && !_harvesting) ? _finish : null,
            child: _harvesting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('完成'),
          ),
        ],
      ),
      body: _supported
          ? Column(
              children: [
                Expanded(
                  child: InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(_mHome)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      thirdPartyCookiesEnabled: true,
                    ),
                    onWebViewCreated: (controller) => _controller = controller,
                  ),
                ),
                const SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 10),
                    child: Text(
                      '请在页面内点「登录」走官方流程（账号 / 短信 / 扫码均可），'
                      '登录成功后点右上角「完成」。若移动端登录后桌面端未解锁，'
                      '可再用「桌面端登录页」补登一次。',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                ),
              ],
            )
          : const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('当前平台暂不支持内置登录页', textAlign: TextAlign.center),
              ),
            ),
    );
  }
}
