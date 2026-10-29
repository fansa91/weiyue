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

  /// 关注态：初始取 user.following，点击乐观切换、失败回滚。
  bool _following = false;
  bool _followBusy = false;

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
      appBar: AppBar(title: Text(user?.screenName ?? '用户主页')),
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
              body: TabBarView(
                controller: _tabController,
                children: [
                  _PagedStatuses(
                    key: ValueKey('wb_${widget.uid}'),
                    loader: (page) => context
                        .read<WeiyueService>()
                        .getUserStatuses(widget.uid, page: page)
                        .then((r) => r.statuses),
                  ),
                  _PagedStatuses(
                    key: ValueKey('vd_${widget.uid}'),
                    loader: (page) => context
                        .read<WeiyueService>()
                        .getUserVideos(widget.uid, page: page)
                        .then((r) => r.statuses),
                    header: _playlists.isEmpty
                        ? null
                        : _buildPlaylists(context),
                  ),
                  _PagedStatuses(
                    key: ValueKey('ft_${widget.uid}'),
                    loader: (page) => context
                        .read<WeiyueService>()
                        .getUserFeatured(widget.uid, page: page)
                        .then((r) => r.statuses),
                  ),
                  _PagedStatuses(
                    key: ValueKey('ar_${widget.uid}'),
                    loader: (page) => context
                        .read<WeiyueService>()
                        .getUserArticles(widget.uid, page: page)
                        .then((r) => r.statuses),
                  ),
                  _AlbumTab(uid: widget.uid),
                ],
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
                          if (_following)
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
    return Padding(
      padding: const EdgeInsets.only(right: 22),
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

/// m 容器分页微博列表（page 递增，空页结束）
class _PagedStatuses extends StatefulWidget {
  final Future<List<WbStatus>> Function(int page) loader;
  final Widget? header;
  const _PagedStatuses({super.key, required this.loader, this.header});

  @override
  State<_PagedStatuses> createState() => _PagedStatusesState();
}

class _PagedStatusesState extends State<_PagedStatuses> {
  final _scroll = ScrollController();
  final List<WbStatus> _items = [];
  int _page = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 500) {
        _loadMore();
      }
    });
    _loadFirst();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

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
    if (_loading) return const Center(child: CircularProgressIndicator());
    // 宽屏瀑布流/窄屏单列与其它列表共用 ResponsiveStatusList；
    // 本列表挂在 NestedScrollView 的 TabBarView 里，作内层滚动视图。
    return ResponsiveStatusList(
      items: _items,
      controller: _scroll,
      header: widget.header,
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

class _AlbumTabState extends State<_AlbumTab> {
  List<List<WbPic>> _groups = const [];
  bool _loading = true;

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
    if (_loading) return const Center(child: CircularProgressIndicator());
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
    if (flat.isEmpty) return const Center(child: Text('暂无图片'));
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
