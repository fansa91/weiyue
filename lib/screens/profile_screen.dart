import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils.dart';
import '../models/models.dart';
import '../services/session_service.dart';
import '../services/settings_service.dart';
import '../services/weiyue_service.dart';
import '../widgets/detail_scaffold.dart';
import '../widgets/interactions.dart';
import '../widgets/long_image_viewer.dart';
import '../widgets/network_image.dart';
import '../widgets/responsive_status_list.dart';
import 'playlist_screen.dart';

/// 用户主页：PC profile/info 头 + 五页签
/// （动态 m 107603 / 视频 m 231567 / 精选 m 230283+getItem / 文章 m 231912 /
/// 相册 albumlist→m 容器，旧 getImageWall+show 兜底）。
class ProfileScreen extends StatefulWidget {
  final String uid;
  const ProfileScreen({super.key, required this.uid});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 5, vsync: this);
  WbUser? _user;
  String? _error;
  List<WbPlaylist> _playlists = const [];

  /// 前四个分页页签（动态/视频/精选/文章）的状态键：分页续拉改由
  /// 外层滚动通知按当前页签分发（见 _onTabBodyScroll），不再靠各
  /// 页签自有 ScrollController 的监听。
  final _tabKeys = List.generate(4, (_) => GlobalKey<_PagedStatusesState>());

  /// 关注态：初始取 user.following，点击乐观切换、失败回滚。
  bool _following = false;
  bool _followBusy = false;

  /// 已屏蔽/拉黑（本页内经 filterUser 成功后置位）：关注按钮让位
  /// 给「已拉黑」禁用态；解除屏蔽走网页端设置页，App 内不做。
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final svc = context.read<WeiyueService>();
    try {
      final user = await svc.getProfileInfo(widget.uid);
      if (mounted) {
        setState(() {
          _user = user;
          _following = user.following;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    try {
      final playlists = await svc.getVideoTab(widget.uid);
      if (mounted) setState(() => _playlists = playlists);
    } catch (_) {}
  }

  /// 页签内层列表接近底部（剩余不足 500px，与旧自有控制器监听的
  /// 阈值一致）时，给当前页签续拉一页；相册页签不分页，忽略。
  /// _PagedStatuses.loadMore 内部有防重入与到底标记，滚动通知
  /// 连发不会重复请求。
  bool _onTabBodyScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification && n.metrics.extentAfter < 500) {
      final i = _tabController.index;
      if (i < _tabKeys.length) _tabKeys[i].currentState?.loadMore();
    }
    return false;
  }

  /// 关注/取关切换：乐观翻转本地状态，失败回滚并弹服务端消息；
  /// 取关不加确认框（任务约定）。未登录只提示，不发请求。
  Future<void> _toggleFollow() async {
    if (_followBusy) return;
    final user = _user;
    if (user == null) return;
    if (!ensureLoggedIn(context)) return;
    final prev = _following;
    setState(() {
      _following = !prev;
      _followBusy = true;
    });
    try {
      final svc = context.read<WeiyueService>();
      if (!prev) {
        await svc.followUser('${user.id}');
      } else {
        await svc.unfollowUser('${user.id}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _following = prev);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  /// 屏蔽/拉黑确认框（主包同名对话框口径）：三个范围开关默认全开，
  /// 「设置对@昵称 的屏蔽范围，全选即为拉黑用户」；确认走
  /// filterUser，成功后本地置已拉黑态并清关注态（主包成功后同置
  /// block=true），提示「已拉黑」（全开）或「已屏蔽」。
  Future<void> _showBlockDialog(WbUser user) async {
    var blockStatuses = true;
    var blockInteract = true;
    var blockFollow = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('屏蔽用户'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('设置对 @${user.screenName} 的屏蔽范围，全选即为拉黑用户'),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: blockStatuses,
                onChanged: (v) =>
                    setDialogState(() => blockStatuses = v ?? false),
                title: const Text('不看TA的微博'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: blockInteract,
                onChanged: (v) =>
                    setDialogState(() => blockInteract = v ?? false),
                title: const Text('禁止TA与我互动'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: blockFollow,
                onChanged: (v) =>
                    setDialogState(() => blockFollow = v ?? false),
                title: const Text('禁止TA关注我'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final all = blockStatuses && blockInteract && blockFollow;
    try {
      await context.read<WeiyueService>().filterUser(
        uid: '${user.id}',
        screenName: user.screenName,
        blockStatuses: blockStatuses,
        blockInteract: blockInteract,
        blockFollow: blockFollow,
      );
      if (!mounted) return;
      setState(() {
        _blocked = true;
        _following = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(all ? '已拉黑' : '已屏蔽')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _showDetail() async {
    final svc = context.read<WeiyueService>();
    Map<String, dynamic> detail = const {};
    try {
      detail = await svc.getProfileDetail(widget.uid);
    } catch (_) {}
    if (!mounted) return;
    final user = _user;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          Text(
            user?.screenName ?? '资料',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (user != null && user.description.isNotEmpty)
            _row('简介', user.description),
          if (user != null && user.location.isNotEmpty)
            _row('所在地', user.location),
          if (user != null && user.verifiedReason.isNotEmpty)
            _row('认证', user.verifiedReason),
          if ((detail['birthday'] ?? '') != '')
            _row('生日', '${detail['birthday']}'),
          if ((detail['created_at'] ?? '') != '')
            _row('注册时间', '${detail['created_at']}'),
          if (detail['sunshine_credit'] is Map)
            _row(
              '阳光信用',
              '${(detail['sunshine_credit'] as Map)['level'] ?? ''}',
            ),
          if ((detail['companyVerified'] is Map))
            _row(
              '企业认证',
              '${(detail['companyVerified'] as Map)['realName'] ?? ''}',
            ),
          if (detail['label_desc'] is List)
            for (final l in detail['label_desc'] as List)
              if (l is Map && (l['name'] ?? '') != '')
                _row('标签', '${l['name']}'),
        ],
      ),
    );
  }

  Widget _row(String k, String v) {
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              k,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(v)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = _user;
    // 看的是本人主页时不显示关注按钮（关注自己无意义）
    final session = context.watch<SessionService>();
    final isSelf = session.uid.isNotEmpty && session.uid == widget.uid;
    return Scaffold(
      appBar: AppBar(
        title: Text(user?.screenName ?? '用户主页'),
        actions: [
          // 更多菜单（仅看他人主页且已登录时）：屏蔽/拉黑。
          // 举报在主包里是跳网页表单（service.account.weibo.com
          // /reportspam），没有 ajax 接口，不在此凑数。
          if (!isSelf && user != null && session.isLoggedIn)
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (v) {
                if (v == 'block') _showBlockDialog(user);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'block', child: Text('屏蔽/拉黑')),
              ],
            ),
        ],
      ),
      body: _error != null && user == null
          ? Center(child: Text(_error!))
          : NestedScrollView(
              headerSliverBuilder: (context, _) => [
                SliverToBoxAdapter(child: _buildHeader(cs, user, isSelf: isSelf)),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TabBarDelegate(
                    TabBar(
                      controller: _tabController,
                      labelColor: cs.primary,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: const [
                        Tab(text: '动态'),
                        Tab(text: '视频'),
                        Tab(text: '精选'),
                        Tab(text: '文章'),
                        Tab(text: '相册'),
                      ],
                    ),
                    cs.surface,
                  ),
                ),
              ],
              // 通知监听只裹 body：页签内层列表接近底部时按当前页签
              // 分发续拉；表头自身的收起/展开滚动不经过这里。
              body: NotificationListener<ScrollNotification>(
                onNotification: _onTabBodyScroll,
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _PagedStatuses(
                      key: _tabKeys[0],
                      loader: (page) => context
                          .read<WeiyueService>()
                          .getUserStatuses(widget.uid, page: page)
                          .then((r) => r.statuses),
                    ),
                    _PagedStatuses(
                      key: _tabKeys[1],
                      loader: (page) => context
                          .read<WeiyueService>()
                          .getUserVideos(widget.uid, page: page)
                          .then((r) => r.statuses),
                      header: _playlists.isEmpty
                          ? null
                          : _buildPlaylists(context),
                    ),
                    _PagedStatuses(
                      key: _tabKeys[2],
                      loader: (page) => context
                          .read<WeiyueService>()
                          .getUserFeatured(widget.uid, page: page)
                          .then((r) => r.statuses),
                    ),
                    _PagedStatuses(
                      key: _tabKeys[3],
                      loader: (page) => context
                          .read<WeiyueService>()
                          .getUserArticles(widget.uid, page: page)
                          .then((r) => r.statuses),
                    ),
                    _AlbumTab(uid: widget.uid),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildPlaylists(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('视频合集', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _playlists.length,
              itemBuilder: (context, i) {
                final p = _playlists[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: const Icon(Icons.playlist_play, size: 17),
                    label: Text('${p.name} · ${p.itemCount}'),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DetailScaffold(
                            child: PlaylistScreen(playlist: p),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs, WbUser? user, {bool isSelf = false}) {
    if (user == null) {
      return const SizedBox(
        height: 190,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      children: [
        // 封面
        SizedBox(
          height: 130,
          width: double.infinity,
          child: user.coverImagePhone.isNotEmpty
              ? NetImage(
                  url: user.coverImagePhone,
                  fit: BoxFit.cover,
                )
              : Container(color: cs.primaryContainer),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 30,
                backgroundImage: user.avatar.isNotEmpty
                    ? NetworkImage(user.avatar)
                    : null,
                child: user.avatar.isEmpty
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
                            user.screenName,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (user.verified) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.verified,
                            size: 17,
                            color: user.verifiedType == 3
                                ? const Color(0xFFF5A623)
                                : cs.primary,
                          ),
                        ],
                        const Spacer(),
                        if (!isSelf) ...[
                          if (_blocked)
                            OutlinedButton(
                              onPressed: null,
                              style: _followBtnStyle,
                              child: const Text('已拉黑'),
                            )
                          else if (_following)
                            OutlinedButton(
                              onPressed: _followBusy ? null : _toggleFollow,
                              style: _followBtnStyle,
                              child: const Text('已关注'),
                            )
                          else
                            FilledButton(
                              onPressed: _followBusy ? null : _toggleFollow,
                              style: _followBtnStyle,
                              child: const Text('关注'),
                            ),
                          const SizedBox(width: 2),
                        ],
                        TextButton(
                          onPressed: _showDetail,
                          child: const Text('资料'),
                        ),
                      ],
                    ),
                    if (user.description.isNotEmpty)
                      Text(
                        user.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _count('关注', user.friendsCount),
                        _count('粉丝', user.followersCount),
                        _count('动态', user.statusesCount),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _followBtnStyle = ButtonStyle(
    visualDensity: VisualDensity.compact,
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14, vertical: 0),
    ),
    textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13.5)),
  );

  Widget _count(String label, int value) {
    // 间距 16：22 时三项计数在 400px 窄屏下恰好溢出 1px（测试字体
    // 更宽时尤甚），收紧一点不影响观感。
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatPlayCount(value),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  final Color bg;
  _TabBarDelegate(this.tabBar, this.bg);

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(color: bg, child: tabBar);

  @override
  bool shouldRebuild(_TabBarDelegate old) => old.tabBar != tabBar;
}

/// 页签加载/空态占位：一支只含 SliverFillRemaining 的可滚动视图。
/// NestedScrollView 的 body 必须是可滚动体，手势才能在内外层
/// 之间接力（下拉回资料头）；裸 Center 不是滚动体，手势会断链
/// （与帖子详情页 _tabPlaceholder 同款做法）。
Widget _tabPlaceholder(Widget child) {
  return CustomScrollView(
    slivers: [
      SliverFillRemaining(hasScrollBody: false, child: Center(child: child)),
    ],
  );
}

/// m 容器分页微博列表（page 递增，空页结束）
class _PagedStatuses extends StatefulWidget {
  final Future<List<WbStatus>> Function(int page) loader;
  final Widget? header;
  const _PagedStatuses({super.key, required this.loader, this.header});

  @override
  State<_PagedStatuses> createState() => _PagedStatusesState();
}

class _PagedStatusesState extends State<_PagedStatuses>
    with AutomaticKeepAliveClientMixin {
  final List<WbStatus> _items = [];
  int _page = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _ended = false;

  /// 切页签时保活：已加载条目与分页进度不丢（TabBarView 默认会
  /// 销毁离屏页签的状态，回来又从第一页重拉）。
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadFirst();
  }

  /// 供外层滚动通知调用的续拉入口（替代旧自有 ScrollController
  /// 的位置监听）：实际防重入/到底判断都在 _loadMore 里。
  void loadMore() => _loadMore();

  Future<void> _loadFirst() async {
    try {
      final list = await widget.loader(1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _page = 1;
        _ended = list.isEmpty;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _ended) return;
    setState(() => _loadingMore = true);
    try {
      final list = await widget.loader(_page + 1);
      if (!mounted) return;
      setState(() {
        _page += 1;
        _items.addAll(list);
        _ended = list.isEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求
    if (_loading) return _tabPlaceholder(const CircularProgressIndicator());
    // 宽屏瀑布流/窄屏单列与其它列表共用 ResponsiveStatusList。
    // 关键：不给列表传自有 ScrollController——NestedScrollView 只
    // 协调使用其内置主控制器的内层滚动体；自有控制器会让内层
    // 独立滚动，外层资料头永远不收起、到顶下拉也不接力回来
    // （帖子详情页同款问题的另一触发点，见 detail 修复 6a9a709）。
    return ResponsiveStatusList(
      items: _items,
      header: widget.header,
      // 本人主页删帖与「我的帖子」页同口径：卡片菜单删除成功后
      // 即时摘除条目（菜单逻辑在 StatusCard 内共享，不另写一套）。
      onStatusDeleted: (s) {
        setState(() => _items.removeWhere((e) => e.id == s.id));
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('动态已删除')));
      },
      footer: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            _items.isEmpty
                ? '暂无内容'
                : _ended
                ? '没有更多了'
                : '',
          ),
        ),
      ),
    );
  }
}

/// 相册页签：优先正规路径（albumlist → m 容器照片），失败/为空时回退
/// 旧逻辑（getImageWall + 逐条 show 补图）。照片汇成宫格。
class _AlbumTab extends StatefulWidget {
  final String uid;
  const _AlbumTab({required this.uid});

  @override
  State<_AlbumTab> createState() => _AlbumTabState();
}

class _AlbumTabState extends State<_AlbumTab>
    with AutomaticKeepAliveClientMixin {
  List<List<WbPic>> _groups = const [];
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = context.read<WeiyueService>();
    var groups = const <List<WbPic>>[];
    try {
      groups = await svc.getAlbumPhotoGroups(widget.uid);
    } catch (_) {
      groups = const [];
    }
    if (groups.isEmpty) {
      // 兜底：旧逻辑逐条补图，图集即每条帖子的 pics
      try {
        final list = await svc.getAlbumStatuses(widget.uid);
        groups = [
          for (final s in list)
            if (s.pics.isNotEmpty) s.pics,
        ];
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _groups = groups;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求
    if (_loading) return _tabPlaceholder(const CircularProgressIndicator());
    // 相册宫格用图档位跟随设置；改设置后宫格即时重建换档。
    final imageQuality =
        context.watch<SettingsService>().imageQuality;
    // 拍平：(所属图集, 图下标)
    final flat = <(List<WbPic>, int)>[];
    for (final g in _groups) {
      for (var i = 0; i < g.length; i++) {
        flat.add((g, i));
      }
    }
    if (flat.isEmpty) return _tabPlaceholder(const Text('暂无图片'));
    return GridView.builder(
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: flat.length,
      itemBuilder: (context, i) {
        final (pics, idx) = flat[i];
        return GestureDetector(
          onTap: () => openPicViewer(
            context,
            pics,
            idx,
            imageQuality: imageQuality,
          ),
          child: NetImage(
            url: pics[idx].feedUrl(imageQuality),
            fit: BoxFit.cover,
            errorBuilder: (_) => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image_outlined),
            ),
          ),
        );
      },
    );
  }
}
