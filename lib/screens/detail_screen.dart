import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/nav.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/session_service.dart';
import '../services/weiyue_service.dart';
import '../widgets/inline_player.dart';
import '../widgets/interactions.dart';
import '../widgets/status_card.dart';
import '../widgets/user_tile.dart';

/// 评论排序方式（纯客户端排序，不额外请求接口）。
enum _CommentSort {
  server('默认（热评顺序）'),
  newest('最新'),
  oldest('最早'),
  mostLiked('最多点赞');

  final String label;
  const _CommentSort(this.label);
}

/// 微博详情：完整卡 + 长文补全 + 评论 + 点赞列表 + 相关视频页签。
/// 评论：访客态服务端只下发 1 条热评；登录后同一接口分页拉全
/// （max_id 游标），评论内嵌回复（楼中楼）缩进展示。
/// 转发列表访客不可见（服务端挡），登录后接 repostTimeline。
class DetailScreen extends StatefulWidget {
  final WbStatus status;

  /// 内嵌播放器后端工厂（测试缝）；null 时用 media_kit 真实后端。
  final InlinePlaybackFactory? inlinePlaybackFactory;

  const DetailScreen({
    super.key,
    required this.status,
    this.inlinePlaybackFactory,
  });

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late WbStatus _status = widget.status;
  List<WbComment> _comments = const [];
  int _commentTotal = 0;
  int _commentMaxId = 0;
  bool _commentsLoading = true;
  bool _commentsLoadingMore = false;
  List<WbAttitude> _attitudes = const [];
  bool _attitudesLoading = true;
  List<WbStatus> _related = const [];
  List<WbStatus> _reposts = const [];
  int _repostPage = 0;
  int _repostMaxPage = 0;
  bool _repostsRequested = false;
  bool _repostsLoading = false;
  _CommentSort _commentSort = _CommentSort.server;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = context.read<WeiyueService>();
    final id = _status.id;
    // 详情刷新（列表来的卡可能字段不全）
    try {
      final full = await svc.getStatus(id);
      if (mounted && full.id.isNotEmpty) setState(() => _status = full);
    } catch (_) {}
    // 长文补全
    if (_status.isLongText) {
      try {
        final long = await svc.getLongText(id);
        if (mounted && long.isNotEmpty) {
          setState(() {
            _status = _status.copyWith(
              text: long,
              textRaw: long,
              isLongText: false,
            );
          });
        }
      } catch (_) {}
    }
    // 直播帖且 media_info 没带可播流：试 getLiveInfo 取流地址。
    // ⚠️ 该接口访客态未实测（无直播样本），取不到就保持现状、静默。
    if (_status.isLive &&
        !_status.hasVideo &&
        _status.pageObjectId.isNotEmpty) {
      try {
        final url = await svc.getLiveStreamUrl(_status.pageObjectId);
        if (mounted && url != null && url.isNotEmpty) {
          setState(() {
            _status = _status.copyWith(
              video: WbVideo(cover: _status.pagePic, fallbackUrl: url),
            );
          });
        }
      } catch (_) {}
    }
    // 评论
    try {
      final r = await svc.getComments(
        id,
        authorUid: '${_status.user?.id ?? ''}',
      );
      if (mounted) {
        setState(() {
          _comments = r.comments;
          _commentTotal = r.total;
          _commentMaxId = r.maxId;
          _commentsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _commentsLoading = false);
    }
    // 点赞
    try {
      final r = await svc.getAttitudes(id);
      if (mounted) {
        setState(() {
          _attitudes = r.items;
          _attitudesLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _attitudesLoading = false);
    }
    // 相关视频
    if (_status.hasVideo) {
      try {
        final list = await svc.getRelatedVideos(id);
        if (mounted) setState(() => _related = list);
      } catch (_) {}
    }
  }

  /// 评论续拉（登录态 max_id 游标分页；访客态 max_id 恒 0 不会触发）。
  Future<void> _loadMoreComments() async {
    if (_commentsLoadingMore || _commentMaxId == 0) return;
    setState(() => _commentsLoadingMore = true);
    try {
      final r = await context.read<WeiyueService>().getComments(
        _status.id,
        authorUid: '${_status.user?.id ?? ''}',
        maxId: _commentMaxId,
      );
      if (mounted) {
        setState(() {
          final seen = _comments.map((c) => c.id).toSet();
          _comments = [
            ..._comments,
            ...r.comments.where((c) => seen.add(c.id)),
          ];
          _commentMaxId = r.maxId;
          if (r.total > 0) _commentTotal = r.total;
        });
      }
    } catch (_) {
      // 续拉失败静默，用户可再点
    } finally {
      if (mounted) setState(() => _commentsLoadingMore = false);
    }
  }

  /// 转发列表首拉（登录态，进页签时懒触发）。
  Future<void> _loadReposts() async {
    if (_repostsLoading) return;
    setState(() => _repostsLoading = true);
    try {
      final r = await context.read<WeiyueService>().getReposts(
        _status.id,
        page: 1,
      );
      if (mounted) {
        setState(() {
          _reposts = r.items;
          _repostPage = 1;
          _repostMaxPage = r.maxPage;
          _repostsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _repostsLoading = false);
    }
  }

  Future<void> _loadMoreReposts() async {
    if (_repostsLoading || _repostPage >= _repostMaxPage) return;
    setState(() => _repostsLoading = true);
    try {
      final r = await context.read<WeiyueService>().getReposts(
        _status.id,
        page: _repostPage + 1,
      );
      if (mounted) {
        setState(() {
          final seen = _reposts.map((s) => s.id).toSet();
          _reposts = [..._reposts, ...r.items.where((s) => seen.add(s.id))];
          _repostPage += 1;
          if (r.maxPage > 0) _repostMaxPage = r.maxPage;
          _repostsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _repostsLoading = false);
    }
  }

  /// 重新拉评论第一页（发评论/回复成功后调用）：替换列表与游标，
  /// 并把服务端总数同步进帖子（页签计数与底栏计数随之更新）。
  Future<void> _reloadComments() async {
    try {
      final r = await context.read<WeiyueService>().getComments(
        _status.id,
        authorUid: '${_status.user?.id ?? ''}',
      );
      if (!mounted) return;
      setState(() {
        _comments = r.comments;
        _commentTotal = r.total;
        _commentMaxId = r.maxId;
        _commentsLoading = false;
        if (r.total > 0) _status = _status.copyWith(commentsCount: r.total);
      });
    } catch (_) {
      // 刷新失败静默：刚发出的内容以服务端为准，下次进页会重新拉
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 发评论（[replyTo] 为空）或回复某条评论：先过登录守卫，
  /// 再开编辑框，成功后刷新评论列表。失败弹服务端消息。
  Future<void> _composeComment({WbComment? replyTo}) async {
    if (!ensureLoggedIn(context)) return;
    final targetName = replyTo?.user?.screenName ?? '';
    final text = await showWbComposer(
      context,
      title: replyTo == null ? '发表评论' : '回复评论',
      hint: replyTo == null ? '说说你的看法…' : '回复 @$targetName…',
      submitLabel: '发送',
    );
    if (text == null || !mounted) return;
    final svc = context.read<WeiyueService>();
    try {
      if (replyTo == null) {
        await svc.createComment(_status.id, text.trim());
      } else {
        await svc.replyComment(
          statusId: _status.id,
          commentId: replyTo.id,
          text: text.trim(),
        );
      }
      if (!mounted) return;
      _snack(replyTo == null ? '评论已发表' : '回复已发送');
      await _reloadComments();
    } catch (e) {
      _snack('$e');
    }
  }

  /// 帖子正文（窄屏与宽屏左栏共用）。视频帖在卡内封面位置
  /// 换成内嵌播放器，进入详情即按设置自动播放预览。
  List<Widget> _buildStatusOnly(BuildContext context) {
    return [
      StatusCard(
        status: _status,
        tappable: false,
        expanded: true,
        onCommentTap: () => _composeComment(),
        onStatusChanged: (s) {
          if (mounted) setState(() => _status = s);
        },
        videoOverride: _status.hasVideo
            ? InlineVideoPlayer(
                key: ValueKey('inline-player-${_status.id}'),
                status: _status,
                playbackFactory: widget.inlinePlaybackFactory,
              )
            : null,
      ),
    ];
  }

  /// 评论/点赞/转发/相关视频四页签。窄屏用固定高 520；宽屏右栏
  /// [fillHeight] 时用 Expanded 撑满面板高度，各页签列表独立滚动。
  Widget _buildTabs(ColorScheme cs, {bool fillHeight = false}) {
    final loggedIn = context.watch<SessionService>().isLoggedIn;
    final tabBarView = TabBarView(
      children: [
        _buildComments(cs, loggedIn: loggedIn),
        _buildAttitudes(),
        _buildRepostsTab(loggedIn),
        _buildRelated(),
      ],
    );
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          TabBar(
            labelColor: cs.primary,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '评论 ${_status.commentsCount}'),
              Tab(text: '点赞 ${_status.attitudesCount}'),
              Tab(text: '转发 ${_status.repostsCount}'),
              const Tab(text: '相关视频'),
            ],
          ),
          if (fillHeight)
            Expanded(child: tabBarView)
          else
            SizedBox(height: 520, child: tabBarView),
        ],
      ),
    );
  }

  /// 相关视频页签：原帖子下方区块改入页签栏，独立滚动。
  Widget _buildRelated() {
    if (_related.isEmpty) {
      return const Center(child: Text('暂无相关视频'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        for (final s in _related)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: StatusCard(status: s),
          ),
      ],
    );
  }

  /// 转发页签：未登录保持占位说明；登录后懒加载 repostTimeline 并分页。
  Widget _buildRepostsTab(bool loggedIn) {
    if (!loggedIn) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('转发列表访客不可见\n（服务端要求登录后查看）', textAlign: TextAlign.center),
        ),
      );
    }
    if (!_repostsRequested) {
      _repostsRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadReposts();
      });
      return const Center(child: CircularProgressIndicator());
    }
    if (_repostsLoading && _reposts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_reposts.isEmpty) {
      return const Center(child: Text('暂无转发'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      children: [
        for (final s in _reposts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: StatusCard(status: s),
          ),
        if (_repostPage < _repostMaxPage)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _repostsLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : OutlinedButton(
                      onPressed: _loadMoreReposts,
                      child: const Text('加载更多转发'),
                    ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('动态详情')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 900) {
            // 桌面双栏：左栏只放帖子正文（铺满剩余宽度、独立滚动），
            // 评论/点赞/转发/相关视频四页签整体只放右栏 420 面板，
            // 高度铺满（fillHeight）、各页签独立滚动，左栏不重复出现。
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    children: _buildStatusOnly(context),
                  ),
                ),
                Container(
                  width: 420,
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: cs.outlineVariant)),
                  ),
                  child: _buildTabs(cs, fillHeight: true),
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            children: [
              ..._buildStatusOnly(context),
              const SizedBox(height: 8),
              _buildTabs(cs),
            ],
          );
        },
      ),
    );
  }

  /// 按当前排序方式整理评论（纯客户端，不重新请求）。
  /// 时间用 parseWbTime 解析 createdAtRaw，解析失败的排末尾；
  /// 所有排序都带原始下标兜底，保证同值/失败项的相对顺序稳定。
  /// 注意：访客态服务端只下发 1 条热评，真实数据下排序效果有限，
  /// 登录态/数据量上来后才明显——控件先行，逻辑与数据量无关。
  List<WbComment> _sortedComments() {
    final indexed = <(int, WbComment)>[
      for (var i = 0; i < _comments.length; i++) (i, _comments[i]),
    ];
    int tieBreak((int, WbComment) a, (int, WbComment) b) =>
        a.$1.compareTo(b.$1);
    switch (_commentSort) {
      case _CommentSort.server:
        break;
      case _CommentSort.mostLiked:
        indexed.sort((a, b) {
          final c = b.$2.likeCount.compareTo(a.$2.likeCount);
          return c != 0 ? c : tieBreak(a, b);
        });
      case _CommentSort.newest:
      case _CommentSort.oldest:
        final desc = _commentSort == _CommentSort.newest;
        indexed.sort((a, b) {
          final ta = parseWbTime(a.$2.createdAtRaw);
          final tb = parseWbTime(b.$2.createdAtRaw);
          if (ta == null && tb == null) return tieBreak(a, b);
          if (ta == null) return 1; // 解析失败排末尾
          if (tb == null) return -1;
          final c = desc ? tb.compareTo(ta) : ta.compareTo(tb);
          return c != 0 ? c : tieBreak(a, b);
        });
    }
    return [for (final e in indexed) e.$2];
  }

  /// 评论页签顶部的紧凑排序切换（横幅上方，单栏/右栏共用）。
  Widget _buildSortBar(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
      child: Row(
        children: [
          Icon(Icons.sort, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            '评论排序',
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          PopupMenuButton<_CommentSort>(
            initialValue: _commentSort,
            tooltip: '评论排序',
            onSelected: (v) => setState(() => _commentSort = v),
            itemBuilder: (_) => [
              for (final v in _CommentSort.values)
                PopupMenuItem(value: v, child: Text(v.label)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _commentSort.label,
                    style: TextStyle(fontSize: 13, color: cs.primary),
                  ),
                  Icon(Icons.arrow_drop_down, size: 18, color: cs.primary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComments(ColorScheme cs, {required bool loggedIn}) {
    if (_commentsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final sorted = _sortedComments();
    final hasMore = _commentMaxId != 0 && _comments.length < _commentTotal;
    return ListView(
      children: [
        _buildSortBar(cs),
        if (!loggedIn && _commentTotal > _comments.length)
          Container(
            margin: const EdgeInsets.fromLTRB(8, 10, 8, 2),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '访客仅显示热评 · 共 $_commentTotal 条评论，登录后看全部',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        if (sorted.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('暂无评论')),
          ),
        for (final c in sorted)
          _CommentTile(comment: c, onReply: (t) => _composeComment(replyTo: t)),
        if (hasMore)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: _commentsLoadingMore
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : OutlinedButton(
                      onPressed: _loadMoreComments,
                      child: Text(
                        '加载更多评论（已显示 ${_comments.length} / 共 $_commentTotal 条）',
                      ),
                    ),
            ),
          ),
      ],
    );
  }

  Widget _buildAttitudes() {
    if (_attitudesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_attitudes.isEmpty) {
      return const Center(child: Text('暂无点赞'));
    }
    return ListView(
      children: [
        for (final a in _attitudes)
          if (a.user != null)
            UserTile(
              user: a.user!,
              subtitle: a.source.isNotEmpty ? '来自 ${a.source}' : null,
              trailingText: a.createdAtRaw,
            ),
      ],
    );
  }
}

class _CommentTile extends StatelessWidget {
  final WbComment comment;

  /// 点「回复」（含楼中楼里的回复）时回调，目标为被回复的那条评论。
  final ValueChanged<WbComment>? onReply;

  const _CommentTile({required this.comment, this.onReply});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = comment.user;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: user != null ? () => openProfile(context, user.id) : null,
            child: CircleAvatar(
              radius: 17,
              backgroundImage: (user?.avatar.isNotEmpty ?? false)
                  ? NetworkImage(user!.avatar)
                  : null,
              child: (user?.avatar.isEmpty ?? true)
                  ? const Icon(Icons.person, size: 17)
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      user?.screenName ?? '',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                    const Spacer(),
                    if (comment.likeCount > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.favorite_border,
                            size: 14,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            formatPlayCount(comment.likeCount),
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                // 与正文共用富文本渲染：话题可点、表情短码渲染成图
                WbRichText(comment.text, fontSize: 14.5),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          formatTimeAgo(
                            parseWbTime(comment.createdAtRaw),
                            fallback: comment.createdAtRaw,
                          ),
                          if (comment.source.isNotEmpty) comment.source,
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (onReply != null)
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => onReply!(comment),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            '回复',
                            style: TextStyle(fontSize: 12.5, color: cs.primary),
                          ),
                        ),
                      ),
                  ],
                ),
                // 楼中楼：接口内嵌的 replies 缩进展示（无独立楼层接口，只这一层）
                if (comment.replies.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final r in comment.replies)
                          _ReplyTile(reply: r, onReply: onReply),
                      ],
                    ),
                  ),
                ],
                const Divider(height: 14),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 楼中楼单条回复（评论内嵌 comments 子列表项，缩进小字号）。
class _ReplyTile extends StatelessWidget {
  final WbComment reply;

  /// 点「回复」时回调，目标为本条回复自身。
  final ValueChanged<WbComment>? onReply;

  const _ReplyTile({required this.reply, this.onReply});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = reply.user;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: user != null ? () => openProfile(context, user.id) : null,
            child: CircleAvatar(
              radius: 12,
              backgroundImage: (user?.avatar.isNotEmpty ?? false)
                  ? NetworkImage(user!.avatar)
                  : null,
              child: (user?.avatar.isEmpty ?? true)
                  ? const Icon(Icons.person, size: 12)
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user?.screenName ?? '',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 1),
                WbRichText(reply.text, fontSize: 13.5),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatTimeAgo(
                          parseWbTime(reply.createdAtRaw),
                          fallback: reply.createdAtRaw,
                        ),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (onReply != null)
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => onReply!(reply),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            '回复',
                            style: TextStyle(fontSize: 12, color: cs.primary),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
