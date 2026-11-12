import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weiyue_service.dart';
import 'status_card.dart';

/// 单个关注分组的时间线（登录后可用）：与关注流同一交互骨架
/// （首屏加载、下拉刷新、滚到底续拉），分页走分组时间线接口的
/// max_id_str/since_id 双游标（friendstimeline/groupstimeline
/// 同形态，主包实证）；计数走服务端 total_number 不可得时不显。
/// [refresh] 供外层刷新钮调用（与 FriendsFeedView 同口径）。
class GroupFeedView extends StatefulWidget {
  final WbFollowGroup group;

  const GroupFeedView({super.key, required this.group});

  @override
  State<GroupFeedView> createState() => GroupFeedViewState();
}

class GroupFeedViewState extends State<GroupFeedView> {
  final List<WbStatus> _items = [];
  final ScrollController _scroll = ScrollController();
  String _maxId = '';
  String _sinceId = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _ended = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
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

  Future<void> refresh() => _loadFirst();

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _error = null;
      _ended = false;
      _maxId = '';
      _sinceId = '';
    });
    try {
      final r = await context.read<WeiyueService>().getGroupTimeline(
        gid: widget.group.gid,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.statuses);
        _maxId = r.maxId;
        _sinceId = r.sinceId;
        _ended = r.statuses.isEmpty;
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
      final r = await context.read<WeiyueService>().getGroupTimeline(
        gid: widget.group.gid,
        maxId: _maxId,
        sinceId: _sinceId,
      );
      if (!mounted) return;
      setState(() {
        final seen = _items.map((s) => s.id).toSet();
        _items.addAll(r.statuses.where((s) => seen.add(s.id)));
        // 游标不动或回空页都视为到底，避免原地打转。
        _ended =
            r.statuses.isEmpty ||
            (r.maxId == _maxId && r.sinceId == _sinceId);
        _maxId = r.maxId;
        _sinceId = r.sinceId;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text('加载失败：$_error', textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _loadFirst, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadFirst,
        child: ListView(
          controller: _scroll,
          children: const [
            SizedBox(height: 160),
            Center(child: Text('该分组暂无内容')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadFirst,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: _items.length + 1,
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(_ended ? '没有更多了' : '', style: _footerStyle()),
              ),
            );
          }
          return StatusCard(status: _items[i]);
        },
      ),
    );
  }

  TextStyle _footerStyle() => TextStyle(
    fontSize: 12.5,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );
}
