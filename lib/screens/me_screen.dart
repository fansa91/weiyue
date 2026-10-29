import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils.dart';
import '../models/models.dart';
import '../services/session_service.dart';
import '../services/visitor_service.dart';
import '../services/weiyue_service.dart';
import '../widgets/network_image.dart';
import 'favorites_screen.dart';
import 'following_screen.dart';
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
  bool _profileLoading = false;
  bool _probing = false;

  /// 已自动补拉过资料的 uid（失败后不反复自动重试，靠手动刷新入口）。
  String _autoProfileUid = '';

  /// 已登录但 uid 为空时已自动探活过一次（防重复触发；
  /// 退出登录或拿到 uid 后重置，之后靠诊断面板「重新检测」手动重试）。
  bool _autoProbedWithoutUid = false;

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
    ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  /// 修复登录态：复用登录页但初始直接打开桌面端站点——passport 会话
  /// 还在时会自动跨域登录，用户点「完成」即重新收割 + 探活。
  Future<void> _openRepairLogin() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginScreen(startOnPcSite: true)),
    );
  }

  /// 重新检测：重跑探活并把结论存回会话（探活内部同时写诊断快照）。
  /// [silent]=true 为页面自动触发：不弹提示，结果看诊断面板即可。
  Future<void> _reprobe({bool silent = false}) async {
    if (_probing) return;
    setState(() => _probing = true);
    final session = context.read<SessionService>();
    try {
      final probe = await context.read<WeiyueService>().probeSession();
      await session.saveProbe(
        uid: probe.user != null ? '${probe.user!.id}' : '',
        screenName: probe.user?.screenName ?? '',
        avatar: probe.user?.avatar ?? '',
        pcUnlocked: probe.pcUnlocked,
        mUnlocked: probe.mUnlocked,
      );
      if (!probe.pcUnlocked && !probe.mUnlocked) {
        session.markExpired();
      }
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '检测完成：桌面端${probe.pcUnlocked ? '已解锁' : '未解锁'}，'
              '移动端${probe.mUnlocked ? '已解锁' : '未解锁'}',
            ),
          ),
        );
      }
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('检测失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _probing = false);
    }
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

  /// 本人 uid：探活字段优先，资料里的 id 兜底。
  String _myUid(SessionService session) {
    if (session.uid.isNotEmpty) return session.uid;
    final p = session.profile;
    return (p != null && p.id > 0) ? '${p.id}' : '';
  }

  /// 已登录但资料未补拉（或换了账号）时，帧后自动拉一次。
  /// 只调度不直接 setState，实际加载在 [_loadProfile]。
  /// 例外：有登录 Cookie 却没拿到 uid 时（v0.1.8 真机实证），先自动
  /// 跑一遍探活——探活主路径会从桌面首页内嵌配置提取 uid 并补全资料；
  /// 只自动跑一次，不反复打扰。
  void _maybeAutoLoadProfile(SessionService session) {
    if (!session.isLoggedIn) {
      _autoProfileUid = '';
      _autoProbedWithoutUid = false;
      return;
    }
    final uid = _myUid(session);
    if (uid.isEmpty) {
      if (!_autoProbedWithoutUid && !_probing) {
        _autoProbedWithoutUid = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _reprobe(silent: true);
        });
      }
      return;
    }
    _autoProbedWithoutUid = false;
    if (_profileLoading) return;
    final p = session.profile;
    if (p != null && '${p.id}' == uid) return;
    if (_autoProfileUid == uid) return;
    _autoProfileUid = uid;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadProfile();
    });
  }

  /// 拉本人完整资料并存会话；自动补拉失败静默（保持简版展示），
  /// 手动刷新失败给提示。
  Future<void> _loadProfile({bool manual = false}) async {
    if (_profileLoading) return;
    final session = context.read<SessionService>();
    final uid = _myUid(session);
    if (uid.isEmpty) return;
    setState(() => _profileLoading = true);
    try {
      final user = await context.read<WeiyueService>().getMyProfile(uid);
      await session.saveProfile(user);
      if (manual && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('资料已更新')));
      }
    } catch (e) {
      if (manual && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('资料刷新失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _profileLoading = false);
    }
  }

  void _openFollowing(String uid, {int total = 0}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScaffold(
          child: FollowingScreen(uid: uid, initialTotal: total),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visitor = context.watch<VisitorService>();
    final session = context.watch<SessionService>();
    final cs = Theme.of(context).colorScheme;
    _maybeAutoLoadProfile(session);
    final myUid = _myUid(session);
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
                MaterialPageRoute(
                  builder: (_) =>
                      const DetailScaffold(child: FavoritesScreen()),
                ),
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.people_outline),
              title: const Text('我的关注'),
              trailing: const Icon(Icons.chevron_right),
              onTap: myUid.isEmpty
                  ? null
                  : () => _openFollowing(
                      myUid,
                      total: session.profile?.friendsCount ?? 0,
                    ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.build_outlined),
              title: const Text('修复登录态'),
              subtitle: const Text('桌面端未解锁时，重新跨域登录并收割'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openRepairLogin,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _buildDiagnostics(context, session),
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
              MaterialPageRoute(
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
              MaterialPageRoute(
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
    final profile = session.profile;
    if (profile != null) {
      return _buildProfileCard(context, session, profile);
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
            ..._sessionStatusRows(context, session),
          ],
        ),
      ),
    );
  }

  /// 两栈解锁状态行 + 过期提示行（简版/资料头两个账号卡共用）。
  List<Widget> _sessionStatusRows(
    BuildContext context,
    SessionService session,
  ) {
    final cs = Theme.of(context).colorScheme;
    return [
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
    ];
  }

  /// 资料头（已补拉到本人完整资料时）：封面 + 大头像 + 昵称/认证
  /// + 认证说明/简介/所在地 + 关注/粉丝/动态三项计数（关注可点进关注列表）
  /// + 刷新资料按钮；下方接两栈状态行。资料未拉到时用简版卡（见上）。
  Widget _buildProfileCard(
    BuildContext context,
    SessionService session,
    WbUser profile,
  ) {
    final cs = Theme.of(context).colorScheme;
    final myUid = _myUid(session);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (profile.bestCover.isNotEmpty)
            SizedBox(
              height: 92,
              width: double.infinity,
              child: NetImage(url: profile.bestCover, fit: BoxFit.cover),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundImage: profile.avatar.isNotEmpty
                          ? NetworkImage(profile.avatar)
                          : null,
                      child: profile.avatar.isEmpty
                          ? const Icon(Icons.person, size: 30)
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  profile.screenName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (profile.verified) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.verified,
                                  size: 17,
                                  color: profile.verifiedType == 3
                                      ? const Color(0xFFF5A623)
                                      : cs.primary,
                                ),
                              ],
                            ],
                          ),
                          if (profile.verifiedReason.isNotEmpty)
                            Text(
                              profile.verifiedReason,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          if (profile.description.isNotEmpty)
                            Text(
                              profile.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          if (profile.location.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  Icons.location_on_outlined,
                                  size: 14,
                                  color: cs.onSurfaceVariant,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  profile.location,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新资料',
                      onPressed: _profileLoading
                          ? null
                          : () => _loadProfile(manual: true),
                      icon: _profileLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 20),
                    ),
                    TextButton(onPressed: _logout, child: const Text('退出登录')),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _stat(
                      context,
                      '关注',
                      profile.friendsCount,
                      onTap: myUid.isEmpty
                          ? null
                          : () => _openFollowing(
                              myUid,
                              total: profile.friendsCount,
                            ),
                    ),
                    _stat(context, '粉丝', profile.followersCount),
                    _stat(context, '动态', profile.statusesCount),
                  ],
                ),
                const SizedBox(height: 10),
                ..._sessionStatusRows(context, session),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 资料头计数：数值（紧凑格式化）在上、标签在下；有关注页入口时可点。
  Widget _stat(
    BuildContext context,
    String label,
    int value, {
    VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatPlayCount(value),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 28),
      child: onTap == null
          ? body
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: body,
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

  String _fmtDiagTime(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.month}-${dt.day} ${two(dt.hour)}:${two(dt.minute)}';
  }

  /// 登录诊断（已登录区）：最近一次探活快照（时间/两栈解锁/uid 有无/
  /// XSRF 有无）+ 最近登录类接口失败记录 + 重新检测按钮。
  /// 只展示布尔与错误消息，绝不含 Cookie/令牌值——用户截图即可作实证。
  Widget _buildDiagnostics(BuildContext context, SessionService session) {
    final cs = Theme.of(context).colorScheme;
    final diag = session.lastProbeDiagnostic;
    final failures = session.recentLoginFailures;
    String unlockText(bool? v) => switch (v) {
      true => '已解锁',
      false => '未解锁',
      null => '未检测',
    };
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
    return ExpansionTile(
      leading: const Icon(Icons.fact_check_outlined),
      title: const Text('登录诊断'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        if (diag == null)
          row('最近检测', '尚未检测')
        else ...[
          row('最近检测', _fmtDiagTime(diag.timeMs)),
          row('桌面端接口', unlockText(diag.pcUnlocked)),
          row('移动端接口', unlockText(diag.mUnlocked)),
          row('用户 ID', diag.hasUid ? '已获取' : '未获取'),
          row('XSRF 令牌', diag.hasXsrf ? '有' : '无'),
        ],
        row('当前令牌', session.hasXsrfToken ? '有' : '无'),
        const SizedBox(height: 6),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '最近失败记录',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        if (failures.isEmpty)
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('暂无失败记录', style: TextStyle(fontSize: 13)),
          )
        else
          for (final f in failures)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${f.endpoint}：${f.message}'
                  '（${_fmtDiagTime(f.timeMs)}）',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: _probing ? null : _reprobe,
            child: _probing
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('重新检测'),
          ),
        ),
      ],
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(context: context, builder: (_) => const WeiyueAboutDialog());
  }
}
