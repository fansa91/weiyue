import 'package:flutter/foundation.dart';

/// 表情短码→图标 URL 的全局持有者。
///
/// 数据由 WeiyueService.loadEmoticons() 在启动后异步装入（本地缓存优先，
/// 无缓存才拉 747KB 的 statuses/config）。正文渲染 WbRichText 监听
/// [version] 变化，映射就绪后已显示的正文自动刷新为行内表情图；
/// 未就绪时正文保持 [泪] 原文显示。
class Emoticons {
  Emoticons._();

  static final ValueNotifier<int> version = ValueNotifier<int>(0);
  static Map<String, String> _map = const {};

  static bool get isReady => _map.isNotEmpty;

  static String? urlOf(String phrase) => _map[phrase];

  static void install(Map<String, String> map) {
    if (map.isEmpty) return;
    _map = map;
    version.value++;
  }

  /// 仅测试用：清空映射让用例互不干扰。
  static void resetForTest() {
    _map = const {};
    version.value++;
  }
}
