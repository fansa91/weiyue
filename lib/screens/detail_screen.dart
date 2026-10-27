import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/nav.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/inline_player.dart';
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

/// 微博详情：完整卡 + 长文补全 + 评论（热评）+ 点赞列表 + 相关视频页签。
/// 转发列表访客不可见（服务端挡），做占位说明。
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
  bool _commentsLoading = true;
  List<WbAttitude> _attitudes = const [];
  bool _attitudesLoading = true;
  List<WbStatus> _related = const [];
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
            _status = WbStatus(
              id: _status.id,
              mblogid: _status.mblogid,
              user: _status.user,
              text: long,
              textRaw: long,
              createdAt: _status.createdAt,
              createdAtRaw: _status.createdAtRaw,
              source: _status.source,
              repostsCount: _status.repostsCount,
              commentsCount: _status.commentsCount,
              attitudesCount: _status.attitudesCount,
              readsCount: _status.readsCount,
              pics: _status.pics,
              video: _status.video,
              isLongText: false,
              retweeted: _status.retweeted,
            );
          });
        }
      } catch (_) {}
    }
    // 评论
    try {
      final r = await svc.getComments(id,
          authorUid: '${_status.user?.id ?? ''}');
      if (mounted) {
        setState(() {
          _comments = r.comments;
          _commentTotal = r.total;
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

  /// 帖子正文（窄屏与宽屏左栏共用）。视频帖在卡内封面位置
  /// 换成内嵌播放器，进入详情即按设置自动播放预览。
  List<Widget> _buildStatusOnly(BuildContext context) {
    return [
      StatusCard(
        status: _status,
        tappable: false,
        expanded: true,
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
    final tabBarView = TabBarView(
      children: [
        _buildComments(cs),
        _buildAttitudes(),
        const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '转发列表访客不可见\n（服务端要求登录后查看）',
              textAlign: TextAlign.center,
            ),
          ),
        ),
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('动态详情')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 900) {
            // 桌面双栏：左栏正文+相关视频独立滚动，右栏固定宽评论面板。
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    children: _buildStatusOnly(context),
                  ),
                ),
                Container(
                  width: 420,
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: cs.outlineVariant),
                    ),
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
          Text('评论排序',
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
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
                  Text(_commentSort.label,
                      style: TextStyle(fontSize: 13, color: cs.primary)),
                  Icon(Icons.arrow_drop_down, size: 18, color: cs.primary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComments(ColorScheme cs) {
    if (_commentsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final sorted = _sortedComments();
    return ListView(
      children: [
        _buildSortBar(cs),
        if (_commentTotal > _comments.length)
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
        for (final c in sorted) _CommentTile(comment: c),
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
  const _CommentTile({required this.comment});

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
              backgroundImage:
                  (user?.avatar.isNotEmpty ?? false)
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
                    Text(user?.screenName ?? '',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13.5)),
                    const Spacer(),
                    if (comment.likeCount > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.favorite_border,
                              size: 14, color: cs.onSurfaceVariant),
                          const SizedBox(width: 3),
                          Text(formatPlayCount(comment.likeCount),
                              style: TextStyle(
                                  fontSize: 12, color: cs.onSurfaceVariant)),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(comment.text, style: const TextStyle(fontSize: 14.5)),
                const SizedBox(height: 3),
                Text(
                  [
                    formatTimeAgo(parseWbTime(comment.createdAtRaw),
                        fallback: comment.createdAtRaw),
                    if (comment.source.isNotEmpty) comment.source,
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                const Divider(height: 14),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
