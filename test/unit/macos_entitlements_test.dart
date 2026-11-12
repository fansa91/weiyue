import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 回归防护：macOS 沙盒授权。App Sandbox 下缺
/// files.user-selected.read-only 时，file_selector/image_picker
/// 弹出的系统文件框选完图也读不到文件（发帖选图在桌面端失效）；
/// 缺 network.client 时沙盒直接禁止一切出站连接（接口与图片
/// 全部加载失败）。两个 entitlements 文件都必须带齐这两项。
void main() {
  for (final name in ['DebugProfile', 'Release']) {
    test('$name.entitlements 带选图读文件与出站网络授权', () {
      final content = File(
        'macos/Runner/$name.entitlements',
      ).readAsStringSync();
      expect(
        content,
        contains('com.apple.security.files.user-selected.read-only'),
        reason: '$name 缺 user-selected 授权，沙盒下选图后读不到文件',
      );
      expect(
        content,
        contains('com.apple.security.network.client'),
        reason: '$name 缺 network.client 授权，沙盒下无法出站联网',
      );
    });
  }
}
