import 'dart:async';
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
/// 点「完成」收割前会先让 WebView 访问一次桌面端站点：移动端登录态
/// 不会自动给 weibo.com 域种 Cookie（域隔离），passport 会话需经这次
/// 访问 SSO 跨域登录并种下 PC 域 Cookie（含 XSRF-TOKEN），否则桌面端
/// 接口整栈不可用（真机实证）。
///
/// [startOnPcSite]=true 为「修复登录态」模式：初始直接打开桌面端站点，
/// passport 会话还在时会自动跨域登录，用户点「完成」即可重新收割探活。
///
/// 平台：flutter_inappwebview 覆盖 Android / iOS / macOS / Windows；
/// 其他平台（如 Linux）无实现，页面直接提示不支持。
class LoginScreen extends StatefulWidget {
  final bool startOnPcSite;

  const LoginScreen({super.key, this.startOnPcSite = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _mHome = 'https://m.weibo.cn/';
  static const _pcHome = 'https://weibo.com/';

  /// 移动端登录直达入口（官方 SSO 登录页）；首页加载异常时可切到这里。
  static const _directLogin = 'https://passport.weibo.com/sso/signin?entry=wapsso';

  /// 常规移动端浏览器 UA，避免站点对 WebView 默认 UA 返回异常页面。
  static const _mobileUa =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

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

  /// 收割前等桌面端站点加载结束的信号（超时/出错也放行继续收割）。
  Completer<void>? _pcVisitWaiter;

  @override
  void initState() {
    super.initState();
    _onPcSite = widget.startOnPcSite;
  }

  /// 首屏加载进度（0-100）；页面加载出错时展示错误面板而非白屏。
  int _progress = 0;
  String? _loadError;

  Future<void> _load(String url) async {
    setState(() {
      _loadError = null;
      _progress = 0;
    });
    await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

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

  /// 收割前先访问一次桌面端站点并等它加载结束（超时 15 秒也继续）：
  /// passport 会话借这次访问 SSO 跨域登录到 weibo.com 并种下该域
  /// Cookie，之后的收割才能拿到完整的 PC 域登录态。
  Future<void> _visitPcHome() async {
    final controller = _controller;
    if (controller == null) return;
    final waiter = Completer<void>();
    _pcVisitWaiter = waiter;
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(_pcHome)));
      await waiter.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
    } catch (_) {
      // 加载异常不挡收割：探活会给出真实结论
    } finally {
      if (identical(_pcVisitWaiter, waiter)) _pcVisitWaiter = null;
    }
  }

  void _completePcVisit() {
    final waiter = _pcVisitWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<void> _finish() async {
    if (_harvesting) return;
    final session = context.read<SessionService>();
    final svc = context.read<WeiyueService>();
    setState(() => _harvesting = true);
    try {
      // 先跨域一跳种下 weibo.com 域 Cookie，再收割（顺序不能反）
      await _visitPcHome();
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
    await _load(_pcHome);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.startOnPcSite ? '修复登录态' : '账号登录'),
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
                if (_progress > 0 && _progress < 100)
                  LinearProgressIndicator(value: _progress / 100),
                Expanded(
                  child: Stack(
                    children: [
                      InAppWebView(
                        initialUrlRequest: URLRequest(
                          url: WebUri(
                            widget.startOnPcSite ? _pcHome : _mHome,
                          ),
                        ),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          domStorageEnabled: true,
                          thirdPartyCookiesEnabled: true,
                          supportMultipleWindows: true,
                          javaScriptCanOpenWindowsAutomatically: true,
                          userAgent: _mobileUa,
                          // 登录链常有 http 跳转/混合内容，放宽避免整页被拦
                          mixedContentMode:
                              MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
                        ),
                        onWebViewCreated: (controller) =>
                            _controller = controller,
                        onLoadStart: (_, _) {
                          if (mounted) setState(() => _loadError = null);
                        },
                        onLoadStop: (_, _) => _completePcVisit(),
                        onProgressChanged: (_, progress) {
                          if (mounted) setState(() => _progress = progress);
                        },
                        onReceivedError: (_, request, error) {
                          if (!(request.isForMainFrame ?? false)) return;
                          _completePcVisit();
                          if (mounted) {
                            setState(() {
                              _loadError =
                                  '页面加载失败：${error.description}'
                                  '（${request.url}）';
                            });
                          }
                        },
                        onReceivedHttpError: (_, request, response) {
                          if (!(request.isForMainFrame ?? false)) return;
                          final code = response.statusCode ?? 0;
                          if (code >= 400 && mounted) {
                            setState(() {
                              _loadError =
                                  '页面加载失败：服务器返回 $code'
                                  '（${request.url}）';
                            });
                          }
                        },
                      ),
                      if (_loadError != null)
                        LoginLoadErrorView(
                          message: _loadError!,
                          onRetry: () => _controller?.reload(),
                          onDirectLogin: () => _load(_directLogin),
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                    child: Text(
                      widget.startOnPcSite
                          ? '正在修复桌面端登录态：页面打开后若已自动登录，'
                                '直接点右上角「完成」重新保存即可；若显示未登录，'
                                '先在页面内完成登录再点「完成」。'
                          : '请在页面内点「登录」走官方流程（账号 / 短信 / 扫码均可），'
                                '登录成功后点右上角「完成」——完成时应用会先打开一次'
                                '桌面端站点完成跨域登录，再保存登录状态。',
                      style: const TextStyle(fontSize: 12.5),
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

/// 登录页加载失败时盖在 WebView 上的面板：给出失败原因（便于回传诊断）
/// 与两个恢复动作——重新加载、换官方 SSO 直达登录页。
class LoginLoadErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDirectLogin;

  const LoginLoadErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onDirectLogin,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 40, color: cs.error),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重新加载'),
                ),
                OutlinedButton.icon(
                  onPressed: onDirectLogin,
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('换直达登录页'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
