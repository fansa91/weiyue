import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/user_tile.dart';

/// 我的关注（登录态）：/ajax/friendships/friends?relate=follows 按 page 翻页，
/// 每行复用 UserTile（头像/昵称+认证标/简介或粉丝数），点击进用户主页。
/// 未登录不会进到这个页面（入口在「我的」登录区）。
class FollowingScreen extends StatefulWidget {
  final String uid;

  /// 资料头已知的关注数（首屏总数未拉回前先用它展示）。
  final int initialTotal;

  const FollowingScreen({super.key, required this.uid, this.initialTotal = 0});

  @override
  State<FollowingScreen> createState() => _FollowingScreenState();
}

class _FollowingScreenState extends State<FollowingScreen> {
  static const _pageSize = 20;

  final _scroll = ScrollController();
  final List<WbUser> _items = [];
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
      final r = await context.read<WeiyueService>().getMyFollowing(
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
      final r = await context.read<WeiyueService>().getMyFollowing(
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的关注')),
      body: Column(
        children: [
          if (_total > 0)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Text(
                '共关注 $_total 人',
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
      return const Center(child: Text('暂无关注'));
    }
    return ListView.builder(
      controller: _scroll,
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
        return UserTile(user: _items[i]);
      },
    );
  }
}
