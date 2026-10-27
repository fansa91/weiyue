import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/nav.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/status_card.dart';
import '../widgets/user_tile.dart';

/// 微博详情：完整卡 + 长文补全 + 相关视频 + 评论（热评）+ 点赞列表。
/// 转发列表访客不可见（服务端挡），做占位说明。
class DetailScreen extends StatefulWidget {
  final WbStatus status;
  const DetailScreen({super.key, required this.status});

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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('动态详情')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          StatusCard(status: _status, tappable: false, expanded: true),
          if (_related.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Text('相关视频',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final s in _related)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: StatusCard(status: s),
              ),
          ],
          const SizedBox(height: 8),
          DefaultTabController(
            length: 3,
            child: Column(
              children: [
                TabBar(
                  labelColor: cs.primary,
                  tabs: [
                    Tab(text: '评论 ${_status.commentsCount}'),
                    Tab(text: '点赞 ${_status.attitudesCount}'),
                    Tab(text: '转发 ${_status.repostsCount}'),
                  ],
                ),
                SizedBox(
                  height: 520,
                  child: TabBarView(
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
                    ],
                  ),
                ),
              ],
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
    return ListView(
      children: [
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
        if (_comments.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('暂无评论')),
          ),
        for (final c in _comments) _CommentTile(comment: c),
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
