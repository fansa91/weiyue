import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weibo_service.dart';
import 'status_card.dart';

/// 热门分类 feed：hottimeline + max_id/fresh_idx 游标分页。
/// 换分类时父级换 Key 重建。
class HotFeedView extends StatefulWidget {
  final WbChannel channel;
  final bool Function(WbStatus status)? filter;
  final String emptyText;

  const HotFeedView({
    super.key,
    required this.channel,
    this.filter,
    this.emptyText = '暂无内容',
  });

  @override
  State<HotFeedView> createState() => _HotFeedViewState();
}

class _HotFeedViewState extends State<HotFeedView> {
  final _scroll = ScrollController();
  final List<WbStatus> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _ended = false;
  String? _error;
  int _maxId = 0;
  int _freshIdx = 1;

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
      final page = await context
          .read<WeiboService>()
          .getHotTimeline(widget.channel, maxId: 0, freshIdx: 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(_applyFilter(page.statuses));
        _maxId = page.maxId;
        _freshIdx = 1;
        _ended = page.statuses.isEmpty;
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

  List<WbStatus> _applyFilter(List<WbStatus> list) {
    final f = widget.filter;
    if (f == null) return list;
    return list.where(f).toList();
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _ended) return;
    setState(() => _loadingMore = true);
    try {
      // 过滤模式下服务端一页过滤后可能为空，多翻几页补齐
      var attempts = widget.filter != null ? 3 : 1;
      var added = 0;
      while (attempts-- > 0 && !_ended) {
        _freshIdx += 1;
        final page = await context.read<WeiboService>().getHotTimeline(
            widget.channel,
            maxId: _maxId,
            freshIdx: _freshIdx);
        if (page.statuses.isEmpty) {
          _ended = true;
          break;
        }
        _maxId = page.maxId;
        final filtered = _applyFilter(page.statuses);
        added += filtered.length;
        if (mounted) {
          setState(() => _items.addAll(filtered));
        }
        if (added > 0) break;
      }
    } catch (_) {
      // 加载更多失败静默，下次滚动再试
    } finally {
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
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: _items.length + 1,
        itemBuilder: (context, i) {
          if (i == _items.length) {
            if (_items.isEmpty) {
              return Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Center(child: Text(widget.emptyText)),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: _ended
                    ? const Text('没有更多了')
                    : const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: StatusCard(status: _items[i]),
          );
        },
      ),
    );
  }
}
