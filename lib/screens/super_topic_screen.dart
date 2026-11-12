import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/session_service.dart';
import '../services/weiyue_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/interactions.dart';
import '../widgets/responsive_status_list.dart';

/// 超话页：帖子流（m 容器 100808{page_id}）+ 页头关注/签到区。
/// 关注/签到走 chaohua 族接口（主包 chaohua 模块实证），按钮状态
/// 来自 page/extend；未登录时按钮保留展示，点击走登录守卫。
class SuperTopicScreen extends StatefulWidget {
  /// 超话页 id（整串 100808…，即容器 id 与 chaohua 的 page_id）。
  final String pageId;
  final String title;
  final String cover;

  const SuperTopicScreen({
    super.key,
    required this.pageId,
    required this.title,
    this.cover = '',
  });

  @override
  State<SuperTopicScreen> createState() => _SuperTopicScreenState();
}

class _SuperTopicScreenState extends State<SuperTopicScreen> {
  final _scroll = ScrollController();
  final List<WbStatus> _items = [];
  int _page = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _ended = false;
  String? _error;

  SuperTopicState _state = const SuperTopicState();
  bool _followBusy = false;
  bool _checkinBusy = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 500) {
        _loadMore();
      }
    });
    _loadFirst();
    _loadState();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  WeiyueService get _svc => context.read<WeiyueService>();

  Future<void> _loadState() async {
    // 未登录不查状态：按钮用默认态，点击时由守卫引导登录。
    if (!context.read<SessionService>().isLoggedIn) return;
    try {
      final st = await _svc.getSuperTopicState(widget.pageId);
      if (mounted) setState(() => _state = st);
    } catch (_) {
      // 状态拉取失败静默：按钮保持默认态，写操作时服务端会再判。
    }
  }

  Future<void> _loadFirst() async {
    try {
      final page = await _svc.getSuperTopicStatuses(widget.pageId, page: 1);
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
      final page = await _svc.getSuperTopicStatuses(
        widget.pageId,
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

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggleFollow() async {
    if (_followBusy) return;
    if (!ensureLoggedIn(context)) return;
    if (_state.isFollowed) {
      // 取关先确认（主包文案逐字）。
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text('确定不再关注此超话？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _followBusy = true);
    try {
      final wasFollowed = _state.isFollowed;
      final btnText = wasFollowed
          ? await _svc.unfollowSuperTopic(widget.pageId)
          : await _svc.followSuperTopic(widget.pageId);
      if (!mounted) return;
      setState(() {
        _state = _state.copyWith(
          isFollowed: !wasFollowed,
          followBtnText: btnText,
        );
      });
      _toast(wasFollowed ? '已取消关注' : '关注成功');
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  Future<void> _checkin() async {
    if (_checkinBusy || _state.isChecked) return;
    if (!ensureLoggedIn(context)) return;
    setState(() => _checkinBusy = true);
    try {
      final r = await _svc.checkinSuperTopic(widget.pageId);
      if (!mounted) return;
      setState(() => _state = _state.copyWith(isChecked: true));
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(r.title),
          content: r.subTitle.isEmpty ? null : Text(r.subTitle),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _checkinBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.title}超话')),
      body: Column(
        children: [
          _header(context),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final followLabel = _state.followBtnText.isNotEmpty
        ? _state.followBtnText
        : (_state.isFollowed ? '已关注' : '关注');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          CoverImage(
            url: widget.cover,
            size: 48,
            radius: 10,
            fallbackIcon: Icons.tag,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '超话',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (_state.isFollowed)
            OutlinedButton(
              onPressed: _followBusy ? null : _toggleFollow,
              child: Text(followLabel),
            )
          else
            FilledButton(
              onPressed: _followBusy ? null : _toggleFollow,
              child: Text(followLabel),
            ),
          const SizedBox(width: 8),
          if (_state.isChecked)
            OutlinedButton(
              onPressed: null,
              child: const Text('已签到'),
            )
          else
            FilledButton.tonal(
              onPressed: _checkinBusy ? null : _checkin,
              child: const Text('签到'),
            ),
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
