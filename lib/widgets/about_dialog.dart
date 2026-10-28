import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 「关于微阅」对话框：应用说明 + 版本行。
///
/// 版本号不在代码里硬编码：CI 构建时由 git tag 解析出 --build-name
/// 注入（见 .github/workflows），运行时经 package_info_plus 读回的
/// [PackageInfo.version] 即 tag 版本（如 0.1.5）；本地开发构建读到
/// 的是 pubspec 的 version，属正常。构建号（--build-number，CI 的
/// run number）以小字附在版本之后。
class WeiyueAboutDialog extends StatelessWidget {
  /// 注入点（测试用）：替换 PackageInfo 的获取方式。
  final Future<PackageInfo> Function()? infoLoader;

  const WeiyueAboutDialog({super.key, this.infoLoader});

  Future<PackageInfo> _load() =>
      infoLoader?.call() ?? PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('关于微阅'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '微阅（只读版）\n\n'
            '非官方第三方客户端，数据来自 weibo.com / m.weibo.cn 网页端公开接口'
            '（逆向整理见 WEIBO_API.md），以访客身份或用户本人登录态读取，'
            '不提供发博、评论、点赞等写操作。\n\n'
            '本应用仅供学习交流使用，与平台官方无关。',
          ),
          const SizedBox(height: 16),
          FutureBuilder<PackageInfo>(
            future: _load(),
            builder: (context, snapshot) {
              final info = snapshot.data;
              if (info == null || info.version.isEmpty) {
                // 读取中或读取失败：不占位显示假版本号。
                return const SizedBox.shrink();
              }
              return Text.rich(
                TextSpan(
                  text: '版本 ${info.version}',
                  children: [
                    if (info.buildNumber.isNotEmpty)
                      TextSpan(
                        text: '（构建 ${info.buildNumber}）',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                style: const TextStyle(fontSize: 13.5),
              );
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}
