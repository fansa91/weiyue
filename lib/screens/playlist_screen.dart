import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/responsive_status_list.dart';

/// 视频合集详情：标题/封面/集数列表（videoalbumdetail，next_cursor 游标翻页）。
/// 点单集卡片进该帖详情，详情页内嵌播放器直接预览播放。
class PlaylistScreen extends StatefulWidget {
  final WbPlaylist playlist;

  const PlaylistScreen({super.key, required this.playlist});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
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
      final r = await context.read<WeiyueService>().getVideoAlbum(
        widget.playlist.id,
        cursor: 0,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.statuses);
        _cursor = r.nextCursor;
        _ended = r.statuses.isEmpty || r.nextCursor <= 0;
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
      final r = await context.read<WeiyueService>().getVideoAlbum(
        widget.playlist.id,
        cursor: _cursor,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(r.statuses);
        _cursor = r.nextCursor;
        _ended = r.statuses.isEmpty || r.nextCursor <= 0;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.playlist;
    return Scaffold(
      appBar: AppBar(title: Text(p.name.isEmpty ? '视频合集' : p.name)),
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
