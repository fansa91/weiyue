import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/responsive_status_list.dart';

/// 话题页：#话题# + 该话题的帖子流（m 话题容器 231522，cardlistInfo.page 翻页，
/// 与用户时间线同一套容器翻页规则）。正文里的话题点击、搜索都可进这里。
class TopicScreen extends StatefulWidget {
  final String topic;

  const TopicScreen({super.key, required this.topic});

  @override
  State<TopicScreen> createState() => _TopicScreenState();
}

class _TopicScreenState extends State<TopicScreen> {
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

  Future<void> _loadFirst() async {
    try {
      final page = await context.read<WeiyueService>().getTopicStatuses(
        widget.topic,
        page: 1,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.statuses);
        _page = 1;
        _ended = page.statuses.isEmpty;
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
      final page = await context.read<WeiyueService>().getTopicStatuses(
        widget.topic,
        page: _page + 1,
      );
      if (!mounted) return;
      setState(() {
        _page += 1;
        _items.addAll(page.statuses);
        _ended = page.statuses.isEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('#${widget.topic}#')),
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
      return const Center(child: Text('暂无内容'));
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
