import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_ime/flutter_ime.dart' as flutter_ime;

/// 桌面端系统输入法（IME）缓解，第二轮。
///
/// ## 第一轮为什么没生效（2026-10-27 查 flutter_ime 3.0.0 源码结论）
///
/// pubspec.lock 锁定的就是 pub.dev 最新版 3.0.0（纯 Dart FFI，无原生
/// 插件），没有可升级的修复版。其 Windows `enableIME()` 的全部实现是
/// 对解析出的 FLUTTERVIEW 子窗口调一次
/// `ImmAssociateContextEx(hwnd, NULL, IACE_DEFAULT)`——即「恢复默认
/// IME 上下文关联」，语义上只是**撤销一次 disableIME() 的分离**。
/// 而本应用从未调用过 disableIME()，上下文从未被这个库分离过，
/// 所以第一轮三处调用很可能本来就无事可恢复。另两个源码级限制：
/// - 窗口解析失败（只能找到前台窗口且属于别的进程）时它**静默拒绝**
///   执行（怕误伤别的程序），3.0.0 起失败也不再抛异常，Dart 侧
///   完全无从知道调用到底做没做事；
/// - 这是 IMM32 层面的关联；微软拼音等现代输入法走 TSF，
///   其激活状态不保证被 IMM 重新关联带动——这是本路线最根本的
///   可靠性疑点，候选窗不弹可能压根不在这一层。
///
/// ## 第二轮的组合（Dart 侧能做的最有把握的几件）
///
/// 1. 时机后移 + 全局化：[installImeGuards] 用 FocusManager 全局监听
///    「任意控件获得焦点」，在焦点真正落定后的下一帧再重新关联，
///    不再只靠三个手写调用点；窗口重新获得前台（resumed）时同样补一次。
/// 2. 延迟补刀：[ensureImeAttachedSettled] 在 post-frame 之外再延迟
///    ~350ms 补一次，覆盖 media_kit 的 mpv 原生子窗口销毁晚于
///    路由 pop 的竞态（第一轮在播放器 dispose 里立即调用，多半
///    赶在 mpv 窗口还没拆完的时候）。
/// 3. 焦点重启：[handleImeFocusGain] 在搜索框获焦时（带 3 秒冷却防
///    循环）做一次 unfocus→下一帧 requestFocus，强制 Flutter 引擎
///    拆掉重建 TextInput 连接——这是 Dart 侧唯一能促使 TSF 重新
///    激活到 Flutter 视图的动作，比单纯 IMM 重新关联更对症。
///
/// 仍然声明：以上是缓解组合而非已验证修复——本机无 Windows 环境
/// 可复现，效果待用户真机验证。若仍不生效，下一层就得动 Windows
/// runner 原生代码（在 WM_SETFOCUS 时处理 TSF 重新激活），
/// 不在本轮范围。
bool get _imePlatform => !kIsWeb && Platform.isWindows;

/// 单次重新关联：把默认 IME 上下文关联回应用窗口。
/// 失败静默（见文件头说明），绝不影响业务流程。
Future<void> ensureImeAttached() async {
  if (!_imePlatform) return;
  try {
    await flutter_ime.enableIME();
  } catch (_) {
    // 缓解失败静默处理
  }
}

/// 落定版重新关联：下一帧先调一次，再延迟 ~350ms 补一次，
/// 覆盖原生窗口拆建/焦点迁移未完成的竞态窗口。
Future<void> ensureImeAttachedSettled() async {
  if (!_imePlatform) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => ensureImeAttached());
  await Future<void>.delayed(const Duration(milliseconds: 350));
  await ensureImeAttached();
}

bool _guardsInstalled = false;

/// 安装全局 IME 守卫（幂等）：任意控件获焦后、窗口回到前台后，
/// 都在下一帧重新关联 IME。main() 启动时调用一次。
void installImeGuards() {
  if (_guardsInstalled || !_imePlatform) return;
  _guardsInstalled = true;
  FocusManager.instance.addListener(() {
    if (FocusManager.instance.primaryFocus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ensureImeAttached());
    }
  });
  WidgetsBinding.instance.addObserver(_ImeLifecycleObserver());
}

class _ImeLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ensureImeAttached());
    }
  }
}

/// 焦点重启的冷却记录（按 FocusNode 标识），防止 unfocus→requestFocus
/// 触发的再次获焦又重启一遍，形成循环。
final _lastRefocusAt = <int, DateTime>{};

/// 输入控件获焦时的组合处理（搜索框用）：先落定版重新关联，
/// 再（3 秒冷却内只做一次）重启焦点，强制引擎重建 TextInput
/// 连接、促使 TSF 重新激活。重启只动焦点不动内容，游标会回到
/// 文本末尾，可接受。
void handleImeFocusGain(FocusNode node) {
  if (!_imePlatform) return;
  unawaited(ensureImeAttachedSettled());
  if (!node.hasFocus) return;
  final key = identityHashCode(node);
  final now = DateTime.now();
  final last = _lastRefocusAt[key];
  if (last != null && now.difference(last) < const Duration(seconds: 3)) {
    return;
  }
  _lastRefocusAt[key] = now;
  node.unfocus();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // 节点可能已随页面销毁/切换，从树上消失时不再抢焦点
    if (node.context != null) node.requestFocus();
    ensureImeAttached();
  });
}
