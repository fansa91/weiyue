import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/nav.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/responsive_status_list.dart';
import '../widgets/status_card.dart';

/// 消息中心（登录态只读）：四页签——全部（msgList 混合流）、
/// @我的（微博/评论子切换）、评论（收到的/发出的子切换）、赞。
/// 页签结构与 PC 网页端主包消息页配置（tagMessage）对齐；
/// 写/发送私信不在本页范围。未登录不会进到这个页面
/// （入口在「我的」登录区，与我的关注/收藏一致）。
class MessageCenterScreen extends StatefulWidget {
  const MessageCenterScreen({super.key});

  @override
  State<MessageCenterScreen> createState() => _MessageCenterScreenState();
}

class _MessageCenterScreenState extends State<MessageCenterScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  MessageUnread _unread = MessageUnread.zero;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _loadUnread();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// 未读汇总只在本页打开时拉一次（本地状态，不轮询）；
  /// 服务层本身不抛错，这里再兜一层，失败只丢徽标不影响页签。
  Future<void> _loadUnread() async {
    try {
      final u = await context.read<WeiyueService>().getMessageSummary();
      if (mounted) setState(() => _unread = u);
    } catch (_) {}
  }

  Widget _tabLabel(String text, int unread) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text),
          if (unread > 0) ...[
            const SizedBox(width: 5),
            Badge(label: Text(unread > 99 ? '99+' : '$unread')),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息中心'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            _tabLabel('全部', 0),
            _tabLabel('@我的', _unread.mentions),
            _tabLabel('评论', _unread.commentsToMe),
            _tabLabel('赞', _unread.likesToMe),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _FeedTab(),
          _MentionsTab(),
          _CommentsTab(),
          _LikesTab(),
        ],
      ),
    );
  }
}

// ---------------- 通用双游标分页列表 ----------------

typedef _Loader<T> =
    Future<MessagePage<T>> Function(String maxId, String sinceId);

/// 消息族列表脚手架：首屏加载/失败重试/空态/滚动到底加载更多，
/// 形态与 FollowingScreen 一致，只是分页换成 max_id+sinceId 双游标。
class _PagedList<T> extends StatefulWidget {
  final _Loader<T> loader;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final String emptyText;

  const _PagedList({
    super.key,
    required this.loader,
    required this.itemBuilder,
    required this.emptyText,
  });

  @override
  State<_PagedList<T>> createState() => _PagedListState<T>();
}

class _PagedListState<T> extends State<_PagedList<T>>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  final List<T> _items = [];
  String _maxId = '';
  String _sinceId = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _ended = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

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
      final r = await widget.loader('', '');
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.items);
        _maxId = r.maxId;
        _sinceId = r.sinceId;
        _ended = !r.hasMore;
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
      final r = await widget.loader(_maxId, _sinceId);
      if (!mounted) return;
      setState(() {
        _items.addAll(r.items);
        _maxId = r.maxId;
        _sinceId = r.sinceId;
        _ended = !r.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
    if (_items.isEmpty) return Center(child: Text(widget.emptyText));
    final cs = Theme.of(context).colorScheme;
    return ListView.separated(
      controller: _scroll,
      itemCount: _items.length + 1,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 62, endIndent: 12),
      itemBuilder: (context, i) {
        if (i == _items.length) {
          return InkWell(
            onTap: _ended ? null : _loadMore,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(
                  _loadingMore ? '加载中…' : (_ended ? '没有更多了' : '加载更多'),
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                ),
              ),
            ),
          );
        }
        return widget.itemBuilder(context, _items[i]);
      },
    );
  }
}

// ---------------- 共用条目组件 ----------------

String _timeText(String raw) =>
    formatTimeAgo(parseWbTime(raw), fallback: raw);

/// 关联微博引用块：作者 + 正文摘录（整行点击跳详情由外层 InkWell 处理）。
Widget _statusQuote(BuildContext context, WbStatus status) {
  final cs = Theme.of(context).colorScheme;
  final author = status.user?.screenName ?? '';
  return Container(
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      author.isNotEmpty ? '@$author：${status.text}' : status.text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
    ),
  );
}

/// 消息条目骨架：头像（点进主页）+ 昵称/时间行 + 动作行 + 正文 + 引用块。
/// 整行点击优先跳帖子详情，无帖子时跳行为人主页，都没有则只展示。
Widget _messageTile(
  BuildContext context, {
  required WbUser? actor,
  required String actionText,
  required String timeRaw,
  String body = '',
  String quoteText = '',
  WbStatus? status,
  int likeCount = 0,
}) {
  final cs = Theme.of(context).colorScheme;
  return InkWell(
    onTap: status != null
        ? () => openDetail(context, status)
        : (actor != null && actor.id > 0
              ? () => openProfile(context, actor.id)
              : null),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: actor != null && actor.id > 0
                ? () => openProfile(context, actor.id)
                : null,
            child: CoverImage(
              url: actor?.avatar ?? '',
              size: 40,
              radius: 20,
              fallbackIcon: Icons.person_outline,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        actor?.screenName ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (likeCount > 0) ...[
                      Icon(
                        Icons.favorite_border,
                        size: 14,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        formatPlayCount(likeCount),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      _timeText(timeRaw),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (actionText.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    actionText,
                    style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                  ),
                ],
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  WbRichText(body, fontSize: 14.5),
                ],
                if (quoteText.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    quoteText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                ],
                if (status != null) _statusQuote(context, status),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

// ---------------- 全部（msgList 混合流） ----------------

class _FeedTab extends StatelessWidget {
  const _FeedTab();

  @override
  Widget build(BuildContext context) {
    final svc = context.read<WeiyueService>();
    return _PagedList<MessageFeedItem>(
      loader: (maxId, sinceId) =>
          svc.getMessageFeed(maxId: maxId, sinceId: sinceId),
      emptyText: '暂无消息',
      itemBuilder: (context, item) => _messageTile(
        context,
        actor: item.actor,
        actionText: item.actionText,
        timeRaw: item.createdAtRaw,
        body: item.text,
        quoteText: item.commentText.isNotEmpty ? '评论：${item.commentText}' : '',
        status: item.status,
      ),
    );
  }
}

// ---------------- @我的（微博 / 评论） ----------------

class _MentionsTab extends StatefulWidget {
  const _MentionsTab();

  @override
  State<_MentionsTab> createState() => _MentionsTabState();
}

class _MentionsTabState extends State<_MentionsTab> {
  bool _commentsMode = false;
  bool _onlyFollowed = false;

  @override
  Widget build(BuildContext context) {
    final svc = context.read<WeiyueService>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('微博')),
                  ButtonSegment(value: true, label: Text('评论')),
                ],
                selected: {_commentsMode},
                onSelectionChanged: (s) =>
                    setState(() => _commentsMode = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const Spacer(),
              FilterChip(
                label: const Text('仅关注的人'),
                selected: _onlyFollowed,
                onSelected: (v) => setState(() => _onlyFollowed = v),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Expanded(
          child: _commentsMode
              ? _PagedList<MessageComment>(
                  key: ValueKey('mention-cmt-$_onlyFollowed'),
                  loader: (maxId, sinceId) => svc.getMentionComments(
                    maxId: maxId,
                    sinceId: sinceId,
                    onlyFollowed: _onlyFollowed,
                  ),
                  emptyText: '暂无@我的评论',
                  itemBuilder: (context, item) =>
                      _commentTile(context, item, mine: false),
                )
              : _StatusCursorList(
                  key: ValueKey('mention-status-$_onlyFollowed'),
                  loader: (maxId, sinceId) => svc.getMentions(
                    maxId: maxId,
                    sinceId: sinceId,
                    onlyFollowed: _onlyFollowed,
                  ),
                  emptyText: '暂无@我的微博',
                ),
        ),
      ],
    );
  }
}

/// 状态流版双游标列表（@我的微博专用，条目复用响应式帖子列表，
/// 形态与收藏页一致）。
class _StatusCursorList extends StatefulWidget {
  final _Loader<WbStatus> loader;
  final String emptyText;

  const _StatusCursorList({
    super.key,
    required this.loader,
    required this.emptyText,
  });

  @override
  State<_StatusCursorList> createState() => _StatusCursorListState();
}

class _StatusCursorListState extends State<_StatusCursorList>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  final List<WbStatus> _items = [];
  String _maxId = '';
  String _sinceId = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _ended = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

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
      final r = await widget.loader('', '');
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.items);
        _maxId = r.maxId;
        _sinceId = r.sinceId;
        _ended = !r.hasMore;
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
      final r = await widget.loader(_maxId, _sinceId);
      if (!mounted) return;
      setState(() {
        _items.addAll(r.items);
        _maxId = r.maxId;
        _sinceId = r.sinceId;
        _ended = !r.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
    if (_items.isEmpty) return Center(child: Text(widget.emptyText));
    return ResponsiveStatusList(
      items: _items,
      controller: _scroll,
      footer: Padding(
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
      ),
    );
  }
}

// ---------------- 评论（收到的 / 发出的） ----------------

Widget _commentTile(
  BuildContext context,
  MessageComment item, {
  required bool mine,
}) {
  final c = item.comment;
  final action = mine
      ? ''
      : (item.replyTo != null ? '回复了你的评论' : '评论了你的微博');
  return _messageTile(
    context,
    actor: c.user,
    actionText: action,
    timeRaw: c.createdAtRaw,
    body: c.text,
    status: item.status,
    likeCount: c.likeCount,
  );
}

class _CommentsTab extends StatefulWidget {
  const _CommentsTab();

  @override
  State<_CommentsTab> createState() => _CommentsTabState();
}

class _CommentsTabState extends State<_CommentsTab> {
  bool _mine = false;

  @override
  Widget build(BuildContext context) {
    final svc = context.read<WeiyueService>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('收到的')),
                  ButtonSegment(value: true, label: Text('发出的')),
                ],
                selected: {_mine},
                onSelectionChanged: (s) => setState(() => _mine = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _mine
              ? _PagedList<MessageComment>(
                  key: const ValueKey('my-cmt'),
                  loader: (maxId, sinceId) =>
                      svc.getMyComments(maxId: maxId, sinceId: sinceId),
                  emptyText: '暂无发出的评论',
                  itemBuilder: (context, item) =>
                      _commentTile(context, item, mine: true),
                )
              : _PagedList<MessageComment>(
                  key: const ValueKey('cmt-inbox'),
                  loader: (maxId, sinceId) =>
                      svc.getCommentsToMe(maxId: maxId, sinceId: sinceId),
                  emptyText: '暂无收到的评论',
                  itemBuilder: (context, item) =>
                      _commentTile(context, item, mine: false),
                ),
        ),
      ],
    );
  }
}

// ---------------- 赞 ----------------

class _LikesTab extends StatelessWidget {
  const _LikesTab();

  @override
  Widget build(BuildContext context) {
    final svc = context.read<WeiyueService>();
    return _PagedList<MessageLike>(
      loader: (maxId, sinceId) =>
          svc.getLikesToMe(maxId: maxId, sinceId: sinceId),
      emptyText: '暂无收到的赞',
      itemBuilder: (context, item) => _messageTile(
        context,
        actor: item.user,
        actionText: item.commentText.isNotEmpty ? '赞了你的评论' : '赞了你的微博',
        timeRaw: item.createdAtRaw,
        quoteText: item.commentText.isNotEmpty ? '评论：${item.commentText}' : '',
        status: item.status,
      ),
    );
  }
}
