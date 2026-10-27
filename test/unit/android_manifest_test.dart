import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 回归防护：release 主 Manifest 必须声明网络权限。
/// 模板默认只在 debug/profile Manifest 里有 INTERNET，
/// 主 Manifest 缺失会导致正式 APK 完全无法联网（v0.1/v0.1.1 踩过）。
void main() {
  test('主 AndroidManifest 声明 INTERNET 权限', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      manifest,
      contains('android.permission.INTERNET'),
      reason: '主 Manifest 缺 INTERNET 权限，release 包将无法联网',
    );
  });
}
