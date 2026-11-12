import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/user_tile.dart';

/// 我的粉丝（登录态）：/ajax/friendships/friends?relate=fans 按 page
/// 翻页（与我的关注 getMyFollowing 成对）。每行复用 UserTile，尾部
/// 放关系态按钮——关系态按主包 FollowBtn 的 followText 逻辑由
/// user.following / user.follow_me 组合：未关注显示「回关」，已关注
/// 且对方关注我显示「互相关注」，已关注未被关注显示「已关注」；
/// 点按钮走既有 followUser/unfollowUser 乐观更新，失败回滚并提示。
/// 入口在「我的」页资料头的粉丝计数（与关注计数点进关注页对称）。
class FansScreen extends StatefulWidget {
  final String uid;

  /// 资料头已知的粉丝数（首屏总数未拉回前先用它展示）。
  final int initialTotal;

  const FansScreen({super.key, required this.uid, this.initialTotal = 0});

  @override
  State<FansScreen> createState() => _FansScreenState();
}

class _FansScreenState extends State<FansScreen> {
  static const _pageSize = 20;

  static const _btnStyle = ButtonStyle(
    visualDensity: VisualDensity.compact,
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14, vertical: 0),
    ),
    textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13.5)),
  );

  final _scroll = ScrollController();
  final List<WbUser> _items = [];
  final Set<int> _busy = {};
  int _page = 1;
  late int _total = widget.initialTotal;
  bool _loading = true;
  bool _loadingMore = false;
  bool _ended = false;
  String? _error;

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

  bool _isEnded(List<WbUser> pageItems) {
    if (pageItems.isEmpty) return true;
    if (_total > 0) return _items.length >= _total;
    // 总数未知时：本页不足一页即到底
    return pageItems.length < _pageSize;
  }

  Future<void> _loadFirst() async {
    try {
      final r = await context.read<WeiyueService>().getMyFans(
        widget.uid,
        page: 1,
        count: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.users);
        _page = 1;
        if (r.total > 0) _total = r.total;
        _ended = _isEnded(r.users);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _ended) return;
    setState(() => _loadingMore = true);
    try {
      final r = await context.read<WeiyueService>().getMyFans(
        widget.uid,
        page: _page + 1,
        count: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _page += 1;
        _items.addAll(r.users);
        if (r.total > 0) _total = r.total;
        _ended = _isEnded(r.users);
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 回关/取关切换：先乐观翻转 following，请求失败回滚并弹服务端
  /// 消息（与主页 _toggleFollow 同口径）。
  Future<void> _toggleFan(WbUser fan) async {
    if (_busy.contains(fan.id)) return;
    final idx = _items.indexWhere((u) => u.id == fan.id);
    if (idx < 0) return;
    final prev = fan.following;
    setState(() {
      _busy.add(fan.id);
      _items[idx] = fan.copyWith(following: !prev);
    });
    try {
      final svc = context.read<WeiyueService>();
      if (!prev) {
        await svc.followUser('${fan.id}');
      } else {
        await svc.unfollowUser('${fan.id}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final cur = _items.indexWhere((u) => u.id == fan.id);
        if (cur >= 0) _items[cur] = _items[cur].copyWith(following: prev);
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy.remove(fan.id));
    }
  }

  Widget? _relationButton(WbUser fan) {
    // 自己不会出现在自己的粉丝里，万一数据带了也不给按钮。
    if ('${fan.id}' == widget.uid) return null;
    final busy = _busy.contains(fan.id);
    if (!fan.following) {
      return FilledButton(
        key: ValueKey('fan-follow-${fan.id}'),
        style: _btnStyle,
        onPressed: busy ? null : () => _toggleFan(fan),
        child: const Text('回关'),
      );
    }
    return OutlinedButton(
      key: ValueKey('fan-follow-${fan.id}'),
      style: _btnStyle,
      onPressed: busy ? null : () => _toggleFan(fan),
      child: Text(fan.followMe ? '互相关注' : '已关注'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的粉丝')),
      body: Column(
        children: [
          if (_total > 0)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Text(
                '共有 $_total 位粉丝',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：$_error'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                _loadFirst();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(child: Text('暂无粉丝'));
    }
    return RefreshIndicator(
      onRefresh: _loadFirst,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _items.length + 1,
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(
                  _loadingMore ? '加载中…' : (_ended ? '没有更多了' : ''),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }
          final fan = _items[i];
          return UserTile(user: fan, trailingWidget: _relationButton(fan));
        },
      ),
    );
  }
}
