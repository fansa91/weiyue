import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/download_service.dart';
import '../services/settings_service.dart';

/// 下载按钮的公共状态机：点击 → 下载中（按钮处转圈/进度）→
/// 完成 SnackBar 报保存去向，失败 SnackBar 报可读原因。
/// [task] 在点击时才构造（视频要按此刻的设置清晰度现取档）。
class _DownloadButtonCore extends StatefulWidget {
  final Future<DownloadResult> Function(DownloadProgress onProgress) task;
  final String tooltip;
  final Color? color;

  /// 渲染形态：普通图标按钮，或「更多」菜单里的一项（卡片封面用）。
  final bool asMenuItem;

  const _DownloadButtonCore({
    required this.task,
    required this.tooltip,
    this.color,
    this.asMenuItem = false,
  });

  @override
  State<_DownloadButtonCore> createState() => _DownloadButtonCoreState();
}

class _DownloadButtonCoreState extends State<_DownloadButtonCore> {
  bool _busy = false;
  double? _fraction;

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _fraction = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await widget.task((received, total) {
        if (!mounted) return;
        setState(() => _fraction = total > 0 ? received / total : null);
      });
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(result.describe)));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(e is DownloadException ? e.message : '保存失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _fraction = null;
        });
      }
    }
  }

  Widget _progress() {
    return SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        value: _fraction,
        color: widget.color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.asMenuItem) {
      // 卡片视频封面右上角的「更多」菜单：只有「下载视频」一项；
      // 下载中菜单按钮位置换成进度圈。
      return Material(
        color: Colors.black45,
        shape: const CircleBorder(),
        child: _busy
            ? Padding(padding: const EdgeInsets.all(10), child: _progress())
            : PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_vert,
                  color: Colors.white,
                  size: 20,
                ),
                tooltip: '更多',
                onSelected: (_) => _run(),
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    value: 'download',
                    child: Row(
                      children: const [
                        Icon(Icons.download_outlined, size: 19),
                        SizedBox(width: 8),
                        Text('下载视频'),
                      ],
                    ),
                  ),
                ],
              ),
      );
    }
    return IconButton(
      icon: _busy
          ? _progress()
          : Icon(Icons.download_outlined, color: widget.color),
      tooltip: widget.tooltip,
      onPressed: _busy ? null : _run,
    );
  }
}

/// 下载当前图片（原图）的按钮：图库与长图阅读器 AppBar 用。
class PicDownloadButton extends StatelessWidget {
  final WbPic pic;
  final String baseName;
  final DownloadService? service;
  final Color? color;

  const PicDownloadButton({
    super.key,
    required this.pic,
    required this.baseName,
    this.service,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final svc = service ?? DownloadService.shared;
    return _DownloadButtonCore(
      tooltip: '下载图片',
      color: color,
      task: (onProgress) => svc.saveImage(
        url: pic.bestOriginal,
        baseName: baseName,
        onProgress: onProgress,
      ),
    );
  }
}

/// 下载当前帖视频的按钮：播放地址在点击时按设置里的默认清晰度选档
///（与播放器默认档一致），无可播地址时按钮禁用。
class VideoDownloadButton extends StatelessWidget {
  final WbStatus status;
  final DownloadService? service;
  final Color? color;

  /// true 时渲染为封面右上角「更多」菜单（含「下载视频」一项）。
  final bool asMenu;

  const VideoDownloadButton({
    super.key,
    required this.status,
    this.service,
    this.color,
    this.asMenu = false,
  });

  @override
  Widget build(BuildContext context) {
    final video = status.video;
    if (video == null || !video.hasPlayable) {
      return const SizedBox.shrink();
    }
    final svc = service ?? DownloadService.shared;
    return _DownloadButtonCore(
      tooltip: '下载视频',
      color: color,
      asMenuItem: asMenu,
      task: (onProgress) {
        // 点击时刻读设置选档，与内嵌播放器默认档口径一致。
        final quality = context.read<SettingsService>().videoQuality;
        final url =
            video.playbackFor(quality)?.url ?? video.defaultUrl ?? '';
        return svc.saveVideo(
          url: url,
          baseName: 'weiyue_video_${status.id}',
          onProgress: onProgress,
        );
      },
    );
  }
}
