import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/models.dart';
import 'network_image.dart';

/// 实况照片播放后端抽象：把 media_kit 关在接口后面，使长按播放与
/// 主/兜底地址切换逻辑可在无 libmpv 的环境注入假后端测试
/// （与 InlinePlayback 同思路）。真实运行时用 [_MediaKitLivePlayback]。
abstract class LivePlayback {
  /// 播放错误流：主地址出错时切兜底直链，再出错静默回静图。
  Stream<String> get errorStream;

  Future<void> open(String url);

  Future<void> play();

  Future<void> pause();

  Future<void> seekToStart();

  Future<void> dispose();

  /// 渲染视频画面（无控制层，静音循环由实现方配置）。
  Widget buildSurface();
}

typedef LivePlaybackFactory = LivePlayback Function();

LivePlayback _mediaKitLivePlaybackFactory() => _MediaKitLivePlayback();

class _MediaKitLivePlayback implements LivePlayback {
  final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  bool _configured = false;

  @override
  Stream<String> get errorStream => _player.stream.error;

  @override
  Future<void> open(String url) async {
    if (!_configured) {
      _configured = true;
      // 实况照片：静音、循环，只在按住期间出声势不出声。
      await _player.setVolume(0);
      await _player.setPlaylistMode(PlaylistMode.loop);
    }
    await _player.open(Media(url), play: false);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seekToStart() => _player.seek(Duration.zero);

  @override
  Future<void> dispose() => _player.dispose();

  @override
  Widget buildSurface() {
    return Video(
      controller: _controller,
      controls: NoVideoControls,
      fit: BoxFit.contain,
    );
  }
}

/// 图库里的实况照片页：静图照常展示（手势缩放走 GestureImage），
/// 动态部分有三条共用同一状态机的播放路径：
/// - 移动端**长按**：按住开播、松手停播并回到静图；
/// - 桌面端鼠标**悬停**：悬停在图片上自动开播、移开停播
///   （MouseRegion 只对可悬停指针生效，触摸不触发）；
/// - 点左上角 **LIVE 标识**：切换播放/暂停（全平台兜底）。
/// 三条路径各自只维护一个「想播」意图，任一意图在场就播、全部
/// 撤掉才停，互不打架（如长按中鼠标移开，长按意图仍在、继续播）。
/// 视频层与图片同区域覆盖显示（IgnorePointer 不抢手势）。
/// 播放优先主地址（media/play 包装地址），出错切模型里解出的
/// .mov 兜底直链再试一次，再失败静默回静图（本页驻留期间不再重试，
/// 翻页回来可再试）。翻页（[active] 变 false）与组件销毁时释放播放器。
class LivePhotoView extends StatefulWidget {
  final WbPic pic;

  /// 静图地址（图库档位已由调用方选好）。
  final String imageUrl;

  /// 是否为图库当前页。
  final bool active;

  /// 播放后端工厂（测试缝）；null 时用 media_kit 真实后端。
  final LivePlaybackFactory? playbackFactory;

  const LivePhotoView({
    super.key,
    required this.pic,
    required this.imageUrl,
    this.active = true,
    this.playbackFactory,
  });

  @override
  State<LivePhotoView> createState() => _LivePhotoViewState();
}

class _LivePhotoViewState extends State<LivePhotoView> {
  LivePlayback? _playback;
  StreamSubscription<String>? _errorSub;

  /// 三条播放路径各自的「想播」意图（见类注释），任一为真就应播放。
  bool _longPressing = false;
  bool _hovering = false;
  bool _toggleOn = false;

  bool get _wantPlay => _longPressing || _hovering || _toggleOn;

  /// 开播流程进行中（防悬停/长按/点标识并发重复开播）。
  bool _starting = false;

  /// 视频层是否正盖在静图上。
  bool _showVideo = false;

  /// 全部候选都失败过：静默回静图，本页驻留期间不再重试。
  bool _dead = false;

  /// 当前打开的是第几个候选（-1 表示尚未打开）。
  int _candidateIndex = -1;

  /// 候选地址链：主地址 → 兜底直链（去重、去空）。
  List<String> get _candidates {
    final urls = <String>[];
    if (widget.pic.liveVideoUrl.isNotEmpty) {
      urls.add(widget.pic.liveVideoUrl);
    }
    final fb = widget.pic.liveVideoFallbackUrl;
    if (fb.isNotEmpty && !urls.contains(fb)) urls.add(fb);
    return urls;
  }

  @override
  void didUpdateWidget(covariant LivePhotoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pic.pid != widget.pic.pid) {
      _clearIntents();
      _release();
      _dead = false;
    } else if (!widget.active && oldWidget.active) {
      // 翻走：清掉全部播放意图、停播并释放播放器资源
      //（翻回来重新触发任一路径会重新建）。
      _clearIntents();
      _release();
      _dead = false;
      if (mounted) setState(() => _showVideo = false);
    }
  }

  void _clearIntents() {
    _longPressing = false;
    _hovering = false;
    _toggleOn = false;
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    _errorSub?.cancel();
    _errorSub = null;
    _playback?.dispose();
    _playback = null;
    _candidateIndex = -1;
  }

  /// 意图变化后对齐播放状态：有任一意图想播就开播，全部撤掉就停播。
  Future<void> _syncPlayback() async {
    if (_wantPlay) {
      await _startPlayback();
    } else {
      await _stopPlayback();
    }
  }

  Future<void> _startPlayback() async {
    if (_starting || _showVideo) return;
    if (!widget.active || _dead || _candidates.isEmpty) return;
    _starting = true;
    try {
      var playback = _playback;
      if (playback == null) {
        try {
          playback = (widget.playbackFactory ??
              _mediaKitLivePlaybackFactory)();
        } catch (_) {
          // 原生库不可用等创建失败：静默保持静图
          _dead = true;
          return;
        }
        _playback = playback;
        _errorSub = playback.errorStream.listen((_) => _onPlaybackError());
      }
      if (_candidateIndex >= 0) {
        // 已开播过（停播只是暂停）：从头续播
        await playback.seekToStart();
        if (!mounted || !_wantPlay) return;
        setState(() => _showVideo = true);
        await playback.play();
        return;
      }
      await _openCandidate(0);
    } finally {
      _starting = false;
    }
  }

  Future<void> _openCandidate(int index) async {
    final playback = _playback;
    if (playback == null) return;
    final urls = _candidates;
    if (index >= urls.length) {
      // 全部候选失败：静默回静图
      _candidateIndex = -1;
      _dead = true;
      if (mounted) setState(() => _showVideo = false);
      return;
    }
    _candidateIndex = index;
    try {
      await playback.open(urls[index]);
    } catch (_) {
      await _openCandidate(index + 1);
      return;
    }
    if (!mounted) return;
    if (_wantPlay) {
      setState(() => _showVideo = true);
      await playback.play();
    }
  }

  /// 播放中途出错（地址过期/网络失败）：还有候选就切下一个，
  /// 没有就静默回静图。已无播放意图（停播中）时忽略迟到的错误。
  void _onPlaybackError() {
    if (!mounted || !_wantPlay || _dead) return;
    unawaited(_openCandidate(_candidateIndex + 1));
  }

  Future<void> _stopPlayback() async {
    if (mounted && _showVideo) setState(() => _showVideo = false);
    final playback = _playback;
    if (playback != null && _candidateIndex >= 0) {
      await playback.pause();
      await playback.seekToStart();
    }
  }

  void _onLongPressStart() {
    _longPressing = true;
    unawaited(_syncPlayback());
  }

  void _onLongPressEnd() {
    if (!_longPressing) return;
    _longPressing = false;
    unawaited(_syncPlayback());
  }

  void _toggle() {
    _toggleOn = !_toggleOn;
    unawaited(_syncPlayback());
  }

  /// 左上角 LIVE 标识：点它切换播放/暂停（全平台兜底入口），
  /// 小图标随播放状态变（播放中显示暂停、静图时显示播放）。
  Widget _buildBadge() {
    final playing = _showVideo;
    return Positioned(
      left: 12,
      top: 12,
      child: GestureDetector(
        key: const ValueKey('gallery-live-badge'),
        onTap: _toggle,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.motion_photos_on,
                color: Colors.white,
                size: 13,
              ),
              const SizedBox(width: 4),
              const Text(
                'LIVE',
                style: TextStyle(color: Colors.white, fontSize: 11.5),
              ),
              const SizedBox(width: 3),
              Icon(
                playing ? Icons.pause : Icons.play_arrow,
                key: ValueKey(
                  playing ? 'live-badge-icon-pause' : 'live-badge-icon-play',
                ),
                color: Colors.white,
                size: 12,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // 桌面端悬停播放：MouseRegion 只响应可悬停指针（鼠标），
      // 触摸不会产生 enter/exit，移动端行为不受影响。
      onEnter: (_) {
        _hovering = true;
        unawaited(_syncPlayback());
      },
      onExit: (_) {
        _hovering = false;
        unawaited(_syncPlayback());
      },
      child: GestureDetector(
        // 长按识别与图片的缩放/翻页手势走手势竞技场：静止按住长按胜出，
        // 一旦拖动则长按被取消（_onLongPressEnd），不会边翻页边播。
        onLongPressStart: (_) => _onLongPressStart(),
        onLongPressEnd: (_) => _onLongPressEnd(),
        onLongPressCancel: _onLongPressEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureImage(
              url: widget.imageUrl,
              inPageView: true,
              enableSlideOutPage: true,
            ),
            if (_showVideo && _playback != null)
              Positioned.fill(
                child: IgnorePointer(child: _playback!.buildSurface()),
              ),
            _buildBadge(),
          ],
        ),
      ),
    );
  }
}
