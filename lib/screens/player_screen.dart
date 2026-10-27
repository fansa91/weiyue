import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../core/ime.dart';

import '../core/utils.dart';
import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/status_card.dart';

/// 视频播放页：media_kit 播放，默认 <=720p 最高档，可切换画质；
/// 下方信息 + 相关视频（点换播）。
class PlayerScreen extends StatefulWidget {
  final WbStatus status;
  const PlayerScreen({super.key, required this.status});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late WbStatus _status = widget.status;
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  List<WbStatus> _related = const [];
  WbPlayback? _current;

  @override
  void initState() {
    super.initState();
    _open(_status);
    _loadRelated();
  }

  @override
  void dispose() {
    _player.dispose();
    // Windows IME 缓解③：退出播放页时兜底把 IME 重新关联回主窗口，
    // 防止 mpv 原生窗口销毁后 IME 上下文悬空、回搜索框打不了中文。
    unawaited(ensureImeAttached());
    super.dispose();
  }

  Future<void> _open(WbStatus status, {WbPlayback? quality}) async {
    final video = status.video;
    if (video == null) return;
    final target = quality ?? video.defaultPlayback;
    final url = target?.url ?? video.defaultUrl;
    if (url == null) return;
    setState(() {
      _status = status;
      _current = target;
    });
    await _player.open(Media(url));
  }

  Future<void> _loadRelated() async {
    try {
      final list =
          await context.read<WeiyueService>().getRelatedVideos(_status.id);
      if (mounted) setState(() => _related = list);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final video = _status.video;
    final user = _status.user;
    return Scaffold(
      appBar: AppBar(
        title: const Text('视频'),
        actions: [
          if (video != null && video.playbackList.length > 1)
            PopupMenuButton<WbPlayback>(
              icon: const Icon(Icons.high_quality_outlined),
              tooltip: '画质',
              onSelected: (q) => _open(_status, quality: q),
              itemBuilder: (_) => [
                for (final p in video.playbackList)
                  PopupMenuItem(
                    value: p,
                    child: Row(
                      children: [
                        Text(p.qualityLabel),
                        if (p.bitrate > 0)
                          Text(
                            '  ${(p.bitrate / 1000000).toStringAsFixed(1)}Mbps',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                        if (_current?.url == p.url) ...[
                          const Spacer(),
                          const Icon(Icons.check, size: 17),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Video(controller: _controller),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(
                  _status.text.isNotEmpty
                      ? _status.text
                      : (user?.screenName ?? ''),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                child: Text(
                  [
                    if (user != null) user.screenName,
                    formatTimeAgo(_status.createdAt,
                        fallback: _status.createdAtRaw),
                    if (video?.onlineUsers.isNotEmpty ?? false)
                      video!.onlineUsers,
                    if (_status.readsCount > 0)
                      '${formatPlayCount(_status.readsCount)} 阅读',
                  ].join(' · '),
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _StatChip(
                        icon: Icons.repeat, label: '${_status.repostsCount}'),
                    const SizedBox(width: 10),
                    _StatChip(
                        icon: Icons.mode_comment_outlined,
                        label: '${_status.commentsCount}'),
                    const SizedBox(width: 10),
                    _StatChip(
                        icon: Icons.favorite_border,
                        label: '${_status.attitudesCount}'),
                  ],
                ),
              ),
              if (_related.isNotEmpty) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('相关视频',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                for (final s in _related)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: StatusCard(status: s),
                  ),
              ],
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _StatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 17),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}
