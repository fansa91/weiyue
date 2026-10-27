import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils.dart';
import '../models/models.dart';
import '../services/weibo_service.dart';
import '../widgets/photo_gallery.dart';
import '../widgets/status_card.dart';

/// 用户主页：PC profile/info 头 + 三页签
/// （微博 m 107603 / 视频 m 231567 / 相册 PC getImageWall+show 补图）。
class ProfileScreen extends StatefulWidget {
  final String uid;
  const ProfileScreen({super.key, required this.uid});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 3, vsync: this);
  WbUser? _user;
  String? _error;
  List<WbPlaylist> _playlists = const [];

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
    final svc = context.read<WeiboService>();
    try {
      final user = await svc.getProfileInfo(widget.uid);
      if (mounted) setState(() => _user = user);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    try {
      final playlists = await svc.getVideoTab(widget.uid);
      if (mounted) setState(() => _playlists = playlists);
    } catch (_) {}
  }

  void _showDetail() async {
    final svc = context.read<WeiboService>();
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
          Text(user?.screenName ?? '资料',
              style: Theme.of(context).textTheme.titleLarge),
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
            _row('阳光信用',
                '${(detail['sunshine_credit'] as Map)['level'] ?? ''}'),
          if ((detail['companyVerified'] is Map))
            _row('企业认证',
                '${(detail['companyVerified'] as Map)['realName'] ?? ''}'),
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
            child: Text(k,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
    return Scaffold(
      appBar: AppBar(title: Text(user?.screenName ?? '用户主页')),
      body: _error != null && user == null
          ? Center(child: Text(_error!))
          : NestedScrollView(
              headerSliverBuilder: (context, _) => [
                SliverToBoxAdapter(child: _buildHeader(cs, user)),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TabBarDelegate(
                    TabBar(
                      controller: _tabController,
                      labelColor: cs.primary,
                      tabs: const [
                        Tab(text: '微博'),
                        Tab(text: '视频'),
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
                        .read<WeiboService>()
                        .getUserStatuses(widget.uid, page: page)
                        .then((r) => r.statuses),
                  ),
                  _PagedStatuses(
                    key: ValueKey('vd_${widget.uid}'),
                    loader: (page) => context
                        .read<WeiboService>()
                        .getUserVideos(widget.uid, page: page)
                        .then((r) => r.statuses),
                    header: _playlists.isEmpty
                        ? null
                        : _buildPlaylists(context),
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
                      // v1 占位：合集二级页未做（videoalbumdetail 已在文档中确认）
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('合集详情页将在后续版本支持')),
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

  Widget _buildHeader(ColorScheme cs, WbUser? user) {
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
              ? CachedNetworkImage(
                  imageUrl: user.coverImagePhone, fit: BoxFit.cover)
              : Container(color: cs.primaryContainer),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 30,
                backgroundImage:
                    user.avatar.isNotEmpty ? NetworkImage(user.avatar) : null,
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
                          child: Text(user.screenName,
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (user.verified) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.verified,
                              size: 17,
                              color: user.verifiedType == 3
                                  ? const Color(0xFFF5A623)
                                  : cs.primary),
                        ],
                        const Spacer(),
                        TextButton(
                          onPressed: _showDetail,
                          child: const Text('资料'),
                        ),
                      ],
                    ),
                    if (user.description.isNotEmpty)
                      Text(user.description,
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _count('关注', user.friendsCount),
                        _count('粉丝', user.followersCount),
                        _count('微博', user.statusesCount),
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

  Widget _count(String label, int value) {
    return Padding(
      padding: const EdgeInsets.only(right: 22),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatPlayCount(value),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      Container(color: bg, child: tabBar);

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
      if (_scroll.position.pixels >=
          _scroll.position.maxScrollExtent - 500) {
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
    return ListView.builder(
      controller: _scroll,
      itemCount: _items.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) return widget.header ?? const SizedBox.shrink();
        if (i == _items.length + 1) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(_items.isEmpty
                  ? '暂无内容'
                  : _ended
                      ? '没有更多了'
                      : ''),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: StatusCard(status: _items[i - 1]),
        );
      },
    );
  }
}

/// 相册页签：getAlbumStatuses 已逐条 show 补图，这里汇成宫格。
class _AlbumTab extends StatefulWidget {
  final String uid;
  const _AlbumTab({required this.uid});

  @override
  State<_AlbumTab> createState() => _AlbumTabState();
}

class _AlbumTabState extends State<_AlbumTab> {
  List<WbStatus> _statuses = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list =
          await context.read<WeiboService>().getAlbumStatuses(widget.uid);
      if (mounted) {
        setState(() {
          _statuses = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    // 拍平：(所属微博的图集, 图下标)
    final flat = <(List<WbPic>, int)>[];
    for (final s in _statuses) {
      for (var i = 0; i < s.pics.length; i++) {
        flat.add((s.pics, i));
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
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PhotoGalleryScreen(pics: pics, initialIndex: idx),
          )),
          child: CachedNetworkImage(
            imageUrl: pics[idx].bestMiddle,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image_outlined),
            ),
          ),
        );
      },
    );
  }
}
