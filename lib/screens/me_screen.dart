import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils.dart';
import '../services/visitor_service.dart';
import 'settings_screen.dart';
import 'theme_screen.dart';
import '../widgets/detail_scaffold.dart';

/// 我的：访客状态卡 + 设置/主题入口 + 关于。
class MeScreen extends StatefulWidget {
  const MeScreen({super.key});

  @override
  State<MeScreen> createState() => _MeScreenState();
}

class _MeScreenState extends State<MeScreen> {
  bool _refreshing = false;

  Future<void> _refreshVisitor() async {
    setState(() => _refreshing = true);
    try {
      await context.read<VisitorService>().refreshAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('访客身份已刷新')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('刷新失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visitor = context.watch<VisitorService>();
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('我的'), centerTitle: false),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              // 访客状态卡
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.badge_outlined, color: cs.primary),
                          const SizedBox(width: 8),
                          const Text('访客身份',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                          const Spacer(),
                          FilledButton.tonal(
                            onPressed: _refreshing ? null : _refreshVisitor,
                            child: _refreshing
                                ? const SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Text('刷新访客身份'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _stackRow(context, 'PC 栈 (weibo.com)',
                          visitor.identityOf(WbStack.pc)),
                      const SizedBox(height: 6),
                      _stackRow(context, '移动栈 (m.weibo.cn)',
                          visitor.identityOf(WbStack.m)),
                      const SizedBox(height: 8),
                      Text(
                        '当前为访客模式：可浏览热门、搜索、主页与视频；'
                        '评论仅显示热评，转发列表与关注流需登录（v2 计划）。',
                        style: TextStyle(
                            fontSize: 12.5, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('设置'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      const DetailScaffold(child: SettingsScreen()),
                )),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('主题与外观'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const DetailScaffold(child: ThemeScreen()),
                )),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('关于'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showAbout(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stackRow(
      BuildContext context, String label, VisitorIdentity? identity) {
    final cs = Theme.of(context).colorScheme;
    final has = identity?.isValid ?? false;
    return Row(
      children: [
        Icon(
          has ? Icons.check_circle : Icons.cancel_outlined,
          size: 17,
          color: has ? Colors.green : cs.error,
        ),
        const SizedBox(width: 8),
        Text(label),
        const Spacer(),
        Text(
          has
              ? '已就绪 · ${formatDate(identity!.updatedAt)} 更新'
              : '未获取',
          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关于微阅'),
        content: const Text(
          '微阅 1.0.0（只读版）\n\n'
          '非官方第三方客户端，数据来自 weibo.com / m.weibo.cn 网页端公开接口'
          '（逆向整理见 WEIBO_API.md），以访客身份读取，不提供发博、评论、点赞等写操作。\n\n'
          '本应用仅供学习交流使用，与新浪微博官方无关。',
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
