import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/session_service.dart';
import '../services/weiyue_service.dart';
import '../widgets/responsive_status_list.dart';

/// 我赞过的（登录态）：/ajax/profile/getLikeList 按 cursor 游标翻页
/// （cursor 从 0 起，next_cursor=-1 到底），条目就是帖子对象——
/// 点赞条目自带点赞态，卡片上的操作栏可直接取消赞（与全站同口径）。
/// 未登录不会进到这个页面（入口在「我的」登录区）。
class LikesScreen extends StatefulWidget {
  const LikesScreen({super.key});

  @override
  State<LikesScreen> createState() => _LikesScreenState();
}

class _LikesScreenState extends State<LikesScreen> {
  final _scroll = ScrollController();
  final List<WbStatus> _items = [];
  int _cursor = 0;
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

  Future<void> _loadFirst() async {
    try {
      final uid = context.read<SessionService>().uid;
      final r = await context.read<WeiyueService>().getLikeList(uid);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.items);
        _cursor = r.nextCursor;
        _ended = r.items.isEmpty || r.nextCursor < 0;
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
      final uid = context.read<SessionService>().uid;
      final r = await context
          .read<WeiyueService>()
          .getLikeList(uid, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        // 瀑布流游标可能回带重复条目，按 id 去重再并入。
        final seen = _items.map((s) => s.id).toSet();
        _items.addAll(r.items.where((s) => seen.add(s.id)));
        _cursor = r.nextCursor;
        _ended = r.items.isEmpty || r.nextCursor < 0;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我赞过的')),
      body: _buildBody(),
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
      return const Center(child: Text('暂无赞过的内容'));
    }
    return ResponsiveStatusList(
      items: _items,
      controller: _scroll,
      footer: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(child: Text(_ended ? '没有更多了' : '')),
      ),
    );
  }
}
