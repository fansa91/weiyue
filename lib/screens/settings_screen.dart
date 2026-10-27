import 'package:flutter/material.dart';

import 'theme_screen.dart';
import '../widgets/detail_scaffold.dart';

/// 设置：外观入口 + 关于。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('外观'),
            subtitle: const Text('主题模式 · 主题色 · 纯黑模式'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const DetailScaffold(child: ThemeScreen()),
            )),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于微阅'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAbout(context),
          ),
          const Divider(height: 1),
          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('访客模式说明'),
            subtitle: Text('本应用以访客身份只读访问平台公开接口，'
                '不收集账号密码；评论仅显示热评，转发列表与关注流需登录。'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关于微阅'),
        content: const Text(
          '微阅 1.0.0（只读版）\n\n'
          '非官方第三方客户端，接口来自 weibo.com / m.weibo.cn 网页端逆向整理'
          '（详见仓库文档 WEIBO_API.md 路径 ~/workspace/rea-probe/targets/weibo/）。\n\n'
          '本应用仅供学习交流使用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
