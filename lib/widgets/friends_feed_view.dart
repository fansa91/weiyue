import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weiyue_service.dart';
import 'responsive_status_list.dart';

/// 关注流（登录态）：friendstimeline + since_id 游标分页。
/// 游标原样回传；返回空页或游标不再变化视为到底。
class FriendsFeedView extends StatefulWidget {
  const FriendsFeedView({super.key});

  @override
  State<FriendsFeedView> createState() => _FriendsFeedViewState();
}

class _FriendsFeedViewState extends State<FriendsFeedView> {
  final _scroll = ScrollController();
  final List<WbStatus> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _ended = false;
  String? _error;
  String _sinceId = '0';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadFirst();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context.read<WeiyueService>().getFriendsTimeline(
        sinceId: '0',
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.statuses);
        _sinceId = page.sinceId;
        _ended = page.statuses.isEmpty || page.sinceId.isEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _ended) return;
    setState(() => _loadingMore = true);
    try {
      final prev = _sinceId;
      final page = await context.read<WeiyueService>().getFriendsTimeline(
        sinceId: prev,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page.statuses);
        _sinceId = page.sinceId;
        // 空页、游标缺失或游标原地不动都视为到底，防死循环
        _ended =
            page.statuses.isEmpty ||
            page.sinceId.isEmpty ||
            page.sinceId == prev;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 40),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 10),
            FilledButton(onPressed: _loadFirst, child: const Text('重试')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadFirst,
      child: ResponsiveStatusList(
        items: _items,
        controller: _scroll,
        footer: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(_items.isEmpty ? '暂无内容' : (_ended ? '没有更多了' : '')),
          ),
        ),
      ),
    );
  }
}
