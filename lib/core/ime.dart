import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_ime/flutter_ime.dart' as flutter_ime;

/// 桌面端系统输入法（IME）缓解。
///
/// 背景：Windows 发布包里，进过视频播放页（media_kit 的 mpv 原生窗口）后，
/// 回到搜索框可能无法用系统输入法打中文——怀疑是 mpv 的原生子窗口把
/// IME 上下文从 Flutter 主窗口分离了，焦点回到文本框时 IME 没有重新关联。
///
/// flutter_ime 的 enableIME() 在 Windows 上通过系统 API 把 IME 上下文
/// 重新关联回应用窗口（ImmAssociateContext），正对症；macOS 等其他
/// 平台该库为 no-op。这里再用 Platform.isWindows 显式守卫，
/// 非 Windows 直接跳过（本项目发布目标不含 Web）。
///
/// 注意：这是缓解手段而非已验证修复——本机无 Windows 桌面 IME 环境
/// 可复现，效果（尤其拼音候选窗是否恢复）待用户真机验证。
/// 调用失败也绝不能影响正常业务流程，故吞掉异常。
Future<void> ensureImeAttached() async {
  if (kIsWeb || !Platform.isWindows) return;
  try {
    await flutter_ime.enableIME();
  } catch (_) {
    // 缓解失败静默处理
  }
}
