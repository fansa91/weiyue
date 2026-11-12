import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/session_service.dart';
import '../services/weiyue_service.dart';
import '../widgets/responsive_status_list.dart';

/// 我的帖子（登录态）：复用个人主页帖子流服务 getUserStatuses
/// （自己 uid 的 m 容器时间线），page 递增、空页到底。
/// 本人帖子卡片右上角菜单自带「删除动态」（StatusCard 共享逻辑，
/// 与主页/详情同一套）：删除成功经 onStatusDeleted 即时摘除条目
/// 并提示，失败由卡片弹服务端消息、条目保留。
/// 未登录不会进到这个页面（入口在「我的」登录区）。
class MyPostsScreen extends StatefulWidget {
  const MyPostsScreen({super.key});

  @override
  State<MyPostsScreen> createState() => _MyPostsScreenState();
}

class _MyPostsScreenState extends State<MyPostsScreen> {
  final _scroll = ScrollController();
  final List<WbStatus> _items = [];
  int _page = 1;
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

  String get _uid => context.read<SessionService>().uid;

  Future<void> _loadFirst() async {
    try {
      final r = await context.read<WeiyueService>().getUserStatuses(
        _uid,
        page: 1,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.statuses);
        _page = 1;
        _ended = r.statuses.isEmpty;
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
      final r = await context.read<WeiyueService>().getUserStatuses(
        _uid,
        page: _page + 1,
      );
      if (!mounted) return;
      setState(() {
        _page += 1;
        // 容器分页偶发回带重复条目，按 id 去重再并入。
        final seen = _items.map((s) => s.id).toSet();
        _items.addAll(r.statuses.where((s) => seen.add(s.id)));
        _ended = r.statuses.isEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onDeleted(WbStatus status) {
    setState(() => _items.removeWhere((s) => s.id == status.id));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('动态已删除')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的帖子')),
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
      return const Center(child: Text('暂无动态'));
    }
    return RefreshIndicator(
      onRefresh: _loadFirst,
      child: ResponsiveStatusList(
        items: _items,
        controller: _scroll,
        onStatusDeleted: _onDeleted,
        footer: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(child: Text(_ended ? '没有更多了' : '')),
        ),
      ),
    );
  }
}
