import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/responsive_status_list.dart';

/// 我的收藏（登录态）：/ajax/favorites/all_fav 按 page 翻页，
/// 条目解包后就是帖子流。未登录不会进到这个页面（入口在「我的」登录区）。
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final _scroll = ScrollController();
  final List<WbStatus> _items = [];
  int _page = 1;
  int _total = 0;
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
      final r = await context.read<WeiyueService>().getFavorites(page: 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.items);
        _page = 1;
        _total = r.total;
        _ended = r.items.isEmpty || (_total > 0 && _items.length >= _total);
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
      final r = await context.read<WeiyueService>().getFavorites(
        page: _page + 1,
      );
      if (!mounted) return;
      setState(() {
        _page += 1;
        _items.addAll(r.items);
        if (r.total > 0) _total = r.total;
        _ended = r.items.isEmpty || (_total > 0 && _items.length >= _total);
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的收藏')),
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
      return const Center(child: Text('暂无收藏'));
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
