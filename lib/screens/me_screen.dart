import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/nav.dart';
import '../core/utils.dart';
import '../services/session_service.dart';
import '../services/visitor_service.dart';
import 'favorites_screen.dart';
import 'login_screen.dart';
import 'settings_screen.dart';
import 'theme_screen.dart';
import '../widgets/about_dialog.dart';
import '../widgets/detail_scaffold.dart';

/// 我的：账号区（登录/已登录信息/退出）+ 访客状态卡 + 我的收藏入口
/// + 设置/主题入口 + 关于。
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('访客身份已刷新')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('刷新失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _openLogin() async {
    await Navigator.of(
      context,
    ).push(appPageRoute(builder: (_) => const LoginScreen()));
  }

  Future<void> _logout() async {
    await context.read<SessionService>().clear();
    await clearWebViewCookies();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已退出登录，回到访客模式')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visitor = context.watch<VisitorService>();
    final session = context.watch<SessionService>();
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('我的'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _buildAccountCard(context, session),
          const SizedBox(height: 12),
          if (session.isLoggedIn) ...[
            ListTile(
              leading: const Icon(Icons.bookmark_outline),
              title: const Text('我的收藏'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                appPageRoute(
                  builder: (_) =>
                      const DetailScaffold(child: FavoritesScreen()),
                ),
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
          ],
          // 访客状态卡（登录后作为回退身份保留）
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
                      const Text(
                        '访客身份',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      FilledButton.tonal(
                        onPressed: _refreshing ? null : _refreshVisitor,
                        child: _refreshing
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('刷新访客身份'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _stackRow(
                    context,
                    'PC 栈 (weibo.com)',
                    visitor.identityOf(WbStack.pc),
                  ),
                  const SizedBox(height: 6),
                  _stackRow(
                    context,
                    '移动栈 (m.weibo.cn)',
                    visitor.identityOf(WbStack.m),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    session.isLoggedIn
                        ? '已登录：优先使用登录身份读取，登录失效时自动回退访客身份。'
                        : '当前为访客模式：可浏览热门、搜索、主页与视频；'
                              '评论仅显示热评，转发列表、关注流与收藏登录后可见。',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 访客模式说明（原设置页文案移至此处）
          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('访客模式说明'),
            subtitle: Text(
              '未登录时以访客身份只读访问平台公开接口：评论仅显示热评，'
              '转发列表、关注流与收藏需登录后查看。登录在本应用内嵌的'
              '官方页面完成，应用不收集账号密码；本应用不提供发帖、'
              '评论、点赞等写操作。',
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('设置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              appPageRoute(
                builder: (_) => const DetailScaffold(child: SettingsScreen()),
              ),
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题与外观'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              appPageRoute(
                builder: (_) => const DetailScaffold(child: ThemeScreen()),
              ),
            ),
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
    );
  }

  /// 账号区：未登录显示登录入口；已登录显示头像/昵称（取到才有）
  /// + 两栈解锁状态 + 过期提示 + 退出按钮。
  Widget _buildAccountCard(BuildContext context, SessionService session) {
    final cs = Theme.of(context).colorScheme;
    if (!session.isLoggedIn) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.account_circle_outlined, color: cs.primary),
                  const SizedBox(width: 8),
                  const Text(
                    '账号',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _openLogin,
                    child: const Text('账号登录'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '登录后可查看全部评论、转发列表、关注流与我的收藏。'
                '登录在内嵌的官方页面完成，本应用不接触你的账号密码。',
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    final name = session.screenName;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundImage: session.avatar.isNotEmpty
                      ? NetworkImage(session.avatar)
                      : null,
                  child: session.avatar.isEmpty
                      ? const Icon(Icons.person, size: 22)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isNotEmpty ? name : '已登录账号',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (session.uid.isNotEmpty)
                        Text(
                          'ID ${session.uid}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                TextButton(onPressed: _logout, child: const Text('退出登录')),
              ],
            ),
            const SizedBox(height: 10),
            _unlockRow(context, '桌面端接口', session.pcUnlocked),
            const SizedBox(height: 6),
            _unlockRow(context, '移动端接口', session.mUnlocked),
            if (session.expired) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.warning_amber, size: 17, color: cs.error),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text('登录已过期，请重新登录', style: TextStyle(fontSize: 13)),
                  ),
                  FilledButton.tonal(
                    onPressed: _openLogin,
                    child: const Text('重新登录'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _unlockRow(BuildContext context, String label, bool? unlocked) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color, text) = switch (unlocked) {
      true => (Icons.check_circle, Colors.green, '已解锁'),
      false => (Icons.cancel_outlined, cs.error, '未解锁'),
      null => (Icons.help_outline, cs.onSurfaceVariant, '未确认'),
    };
    return Row(
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 8),
        Text(label),
        const Spacer(),
        Text(
          text,
          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _stackRow(
    BuildContext context,
    String label,
    VisitorIdentity? identity,
  ) {
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
          has ? '已就绪 · ${formatDate(identity!.updatedAt)} 更新' : '未获取',
          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(context: context, builder: (_) => const WeiyueAboutDialog());
  }
}
