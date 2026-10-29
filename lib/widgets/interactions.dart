import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils.dart';
import '../models/models.dart';
import '../screens/login_screen.dart';
import '../services/session_service.dart';
import '../services/weiyue_service.dart';

/// 写操作前的登录守卫：已登录（且未过期）返回 true；
/// 否则弹「登录后可用」提示并带「去登录」入口，不发任何请求。
bool ensureLoggedIn(BuildContext context) {
  final session = context.read<SessionService>();
  if (session.isLoggedIn && !session.expired) return true;
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: const Text('登录后可用'),
        action: SnackBarAction(
          label: '去登录',
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            );
          },
        ),
      ),
    );
  return false;
}

void _snack(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// 通用文本编辑框（发评论/回复/转发语共用）：点「发送」返回文本
///（原文，调用方自行 trim），取消/关闭返回 null。
/// [allowEmpty]=true 时空文本也可提交（转发可无语）。
Future<String?> showWbComposer(
  BuildContext context, {
  required String title,
  String hint = '',
  String initialText = '',
  String submitLabel = '发送',
  bool allowEmpty = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      final controller = TextEditingController(text: initialText);
      return StatefulBuilder(
        builder: (context, setLocal) {
          final canSubmit =
              allowEmpty || controller.text.trim().isNotEmpty;
          return AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              maxLength: 2000,
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setLocal(() {}),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: canSubmit
                    ? () => Navigator.of(dialogContext).pop(controller.text)
                    : null,
                child: Text(submitLabel),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 帖子卡底栏互动区：转发 / 评论 / 点赞 / 收藏。
/// 点赞与收藏是乐观更新（图标与计数先变，失败回滚并弹服务端消息）；
/// 转发先开编辑框、成功后计数 +1；评论在列表卡里进详情，
/// 详情页传入 [onCommentTap] 改为打开评论编辑框。
/// 全部动作纯手动单次触发，请求中防重复点击；未登录时点击只提示。
class StatusActionBar extends StatefulWidget {
  final WbStatus status;

  /// 详情页用：点评论改为打开评论编辑框（不传时进详情页）。
  final VoidCallback? onCommentTap;

  /// 任一动作成功后回传本地最新快照（详情页据此同步页签计数）。
  final ValueChanged<WbStatus>? onStatusChanged;

  const StatusActionBar({
    super.key,
    required this.status,
    this.onCommentTap,
    this.onStatusChanged,
  });

  @override
  State<StatusActionBar> createState() => _StatusActionBarState();
}

class _StatusActionBarState extends State<StatusActionBar> {
  late bool _liked;
  late int _attitudes;
  late bool _favorited;
  late int _reposts;

  /// 上次从外部（widget.status）采纳的基线值：外部刷新换了新值才采纳，
  /// 避免父级拿旧对象重建时把本地乐观结果冲掉。
  late bool _baseLiked;
  late bool _baseFavorited;
  late int _baseReposts;

  bool _likeBusy = false;
  bool _favBusy = false;
  bool _repostBusy = false;

  @override
  void initState() {
    super.initState();
    _adoptAll(widget.status);
  }

  void _adoptAll(WbStatus s) {
    _liked = s.liked;
    _attitudes = s.attitudesCount;
    _favorited = s.favorited;
    _reposts = s.repostsCount;
    _baseLiked = s.liked;
    _baseFavorited = s.favorited;
    _baseReposts = s.repostsCount;
  }

  @override
  void didUpdateWidget(StatusActionBar old) {
    super.didUpdateWidget(old);
    final s = widget.status;
    if (old.status.id != s.id) {
      _adoptAll(s);
      return;
    }
    // 同一条帖子的外部刷新：仅当外部值相对基线变了才采纳
    if (!_likeBusy && s.liked != _baseLiked) {
      _liked = s.liked;
      _attitudes = s.attitudesCount;
      _baseLiked = s.liked;
    }
    if (!_favBusy && s.favorited != _baseFavorited) {
      _favorited = s.favorited;
      _baseFavorited = s.favorited;
    }
    if (!_repostBusy && s.repostsCount != _baseReposts) {
      _reposts = s.repostsCount;
      _baseReposts = s.repostsCount;
    }
  }

  void _emitChanged() {
    widget.onStatusChanged?.call(
      widget.status.copyWith(
        liked: _liked,
        attitudesCount: _attitudes,
        favorited: _favorited,
        repostsCount: _reposts,
      ),
    );
  }

  Future<void> _toggleLike() async {
    if (_likeBusy) return;
    if (!ensureLoggedIn(context)) return;
    final svc = context.read<WeiyueService>();
    final prevLiked = _liked;
    final prevCount = _attitudes;
    setState(() {
      _liked = !_liked;
      _attitudes += _liked ? 1 : -1;
      _likeBusy = true;
    });
    try {
      if (_liked) {
        await svc.likeStatus(widget.status.id);
      } else {
        await svc.unlikeStatus(widget.status.id);
      }
      _baseLiked = _liked;
      _emitChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _liked = prevLiked;
        _attitudes = prevCount;
      });
      _snack(context, '$e');
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  Future<void> _toggleFavorite() async {
    if (_favBusy) return;
    if (!ensureLoggedIn(context)) return;
    final svc = context.read<WeiyueService>();
    final prev = _favorited;
    setState(() {
      _favorited = !_favorited;
      _favBusy = true;
    });
    try {
      if (_favorited) {
        await svc.createFavorite(widget.status.id);
      } else {
        await svc.destroyFavorite(widget.status.id);
      }
      if (!mounted) return;
      _baseFavorited = _favorited;
      _emitChanged();
      _snack(context, _favorited ? '已收藏' : '已取消收藏');
    } catch (e) {
      if (!mounted) return;
      setState(() => _favorited = prev);
      _snack(context, '$e');
    } finally {
      if (mounted) setState(() => _favBusy = false);
    }
  }

  Future<void> _doRepost() async {
    if (_repostBusy) return;
    if (!ensureLoggedIn(context)) return;
    final svc = context.read<WeiyueService>();
    final text = await showWbComposer(
      context,
      title: '转发动态',
      hint: '说说你的看法…',
      submitLabel: '转发',
      allowEmpty: true,
    );
    if (text == null || !mounted) return;
    setState(() => _repostBusy = true);
    try {
      await svc.repostStatus(widget.status.id, comment: text.trim());
      if (!mounted) return;
      setState(() {
        _reposts += 1;
        _baseReposts = _reposts;
      });
      _emitChanged();
      _snack(context, '转发成功');
    } catch (e) {
      if (mounted) _snack(context, '$e');
    } finally {
      if (mounted) setState(() => _repostBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = widget.status;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionButton(
          icon: Icons.repeat,
          count: _reposts,
          tooltip: '转发',
          onTap: _doRepost,
        ),
        _ActionButton(
          icon: Icons.mode_comment_outlined,
          count: s.commentsCount,
          tooltip: '评论',
          onTap: widget.onCommentTap,
        ),
        _ActionButton(
          icon: _liked ? Icons.favorite : Icons.favorite_border,
          count: _attitudes,
          tooltip: '点赞',
          color: _liked ? const Color(0xFFE6162D) : null,
          onTap: _toggleLike,
        ),
        IconButton(
          icon: Icon(
            _favorited ? Icons.bookmark : Icons.bookmark_border,
            size: 19,
          ),
          color: _favorited ? const Color(0xFFF5A623) : cs.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          tooltip: '收藏',
          onPressed: _toggleFavorite,
        ),
      ],
    );
  }
}

/// 图标+计数小按钮（与旧 _CountItem 同视觉规格，计数走 formatPlayCount）。
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final int count;
  final String tooltip;
  final Color? color;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.count,
    required this.tooltip,
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final body = Padding(
      padding: const EdgeInsets.only(right: 22),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color ?? cs.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(
            count > 0 ? formatPlayCount(count) : '0',
            style: TextStyle(
              fontSize: 13,
              color: color ?? cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: body,
    );
  }
}
