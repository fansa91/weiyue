import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../core/ime.dart';
import '../core/utils.dart';
import 'download_button.dart';
import 'network_image.dart';
import '../models/models.dart';
import '../services/settings_service.dart';

/// 播放后端抽象：把 media_kit 的 Player/VideoController 关在接口后面，
/// 使内嵌播放器可在无 libmpv 的环境（如测试机）注入假后端测试，
/// 真实运行时默认用 [_mediaKitPlaybackFactory]。
abstract class InlinePlayback {
  Stream<int?> get widthStream;
  Stream<int?> get heightStream;

  /// 播放/暂停状态流：驱动预览框暂停按钮图标与控制层自动隐藏
  ///（暂停时控制层常显，不自动隐藏）。
  Stream<bool> get playingStream;

  Future<void> open(String url);

  Future<void> play();

  Future<void> pause();

  Future<void> toggleFullscreen();

  Future<void> dispose();

  /// 渲染视频画面（含 media_kit 默认控制层：播放/暂停/进度/音量/全屏）。
  Widget buildSurface();
}

/// 播放后端工厂：全屏进/出回调由 [InlineVideoPlayer] 提供
/// （按视频比例定向逻辑在播放器组件内，后端只负责透传给 Video）。
typedef InlinePlaybackFactory =
    InlinePlayback Function({
      required Future<void> Function() onEnterFullscreen,
      required Future<void> Function() onExitFullscreen,
    });

InlinePlayback _mediaKitPlaybackFactory({
  required Future<void> Function() onEnterFullscreen,
  required Future<void> Function() onExitFullscreen,
}) => _MediaKitPlayback(
  onEnterFullscreen: onEnterFullscreen,
  onExitFullscreen: onExitFullscreen,
);

class _MediaKitPlayback implements InlinePlayback {
  _MediaKitPlayback({
    required Future<void> Function() onEnterFullscreen,
    required Future<void> Function() onExitFullscreen,
  }) : _onEnterFullscreen = onEnterFullscreen,
       _onExitFullscreen = onExitFullscreen;

  final Future<void> Function() _onEnterFullscreen;
  final Future<void> Function() _onExitFullscreen;

  final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  final _videoKey = GlobalKey<VideoState>();

  @override
  Stream<int?> get widthStream => _player.stream.width;

  @override
  Stream<int?> get heightStream => _player.stream.height;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Future<void> open(String url) => _player.open(Media(url));

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> toggleFullscreen() async {
    await _videoKey.currentState?.toggleFullscreen();
  }

  @override
  Future<void> dispose() => _player.dispose();

  @override
  Widget buildSurface() {
    return Video(
      key: _videoKey,
      controller: _controller,
      onEnterFullscreen: _onEnterFullscreen,
      onExitFullscreen: _onExitFullscreen,
    );
  }
}

/// 详情页内嵌视频播放器：进入详情按设置自动播放（设置关时显示
/// 封面 + 大播放按钮，点击才建播放器开播）；带画质切换（playback_list
/// 多档，默认按设置清晰度选档）与显式全屏按钮；左下角有暂停/续播
/// 按钮，自有控制层在播放中 3 秒无操作后自动隐藏（暂停时常显），
/// 点画面可唤回。
/// 移动端全屏方向按视频实际宽高决定：横屏视频全屏转横屏，
/// 竖屏视频全屏保持竖屏；桌面沿用 media_kit 默认全屏实现。
/// 播放器创建/打开失败（如运行环境缺原生库）时兜底回封面态可重试，
/// 不让详情页崩溃。
class InlineVideoPlayer extends StatefulWidget {
  final WbStatus status;

  /// 自动播放覆盖：null 时读 SettingsService.videoAutoplay。
  final bool? autoplay;

  /// 播放后端工厂（测试缝）；null 时用 media_kit 真实后端。
  final InlinePlaybackFactory? playbackFactory;

  const InlineVideoPlayer({
    super.key,
    required this.status,
    this.autoplay,
    this.playbackFactory,
  });

  @override
  State<InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<InlineVideoPlayer> {
  InlinePlayback? _playback;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;
  StreamSubscription<bool>? _playingSub;
  WbPlayback? _current;
  bool _started = false;
  bool _failed = false;

  /// 播放中：播放流的状态；暂停按钮图标与自动隐藏据此决定。
  bool _isPlaying = false;

  /// 预览框自有控制层（画质/全屏/暂停按钮）是否可见。
  bool _controlsVisible = true;

  /// 控制层自动隐藏延时：播放中无操作 3 秒后隐藏，点画面可唤回。
  static const _kControlsHideDelay = Duration(seconds: 3);
  Timer? _hideTimer;

  /// 当前视频宽高：先用档位元数据占位，播放开始后以流的宽高为准。
  int? _videoWidth;
  int? _videoHeight;

  /// 自动播放是否生效：initState 时定格（widget.autoplay 优先，
  /// 否则读设置项），页面生命周期内不随设置变化重启播放。
  late final bool _autoplayEffective;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  bool get _isLandscapeVideo => isLandscapeVideoSize(_videoWidth, _videoHeight);

  @override
  void initState() {
    super.initState();
    _autoplayEffective =
        widget.autoplay ?? context.read<SettingsService>().videoAutoplay;
    _initDims(widget.status);
    if (_autoplayEffective && widget.status.hasVideo) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }
  }

  @override
  void didUpdateWidget(covariant InlineVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status.id != oldWidget.status.id) {
      // 换帖：释放旧播放并按新帖重来
      _resetPlayback();
      _initDims(widget.status);
      if (_autoplayEffective && widget.status.hasVideo) _start();
    } else if (_playback == null &&
        !_failed &&
        _autoplayEffective &&
        widget.status.hasVideo) {
      // 同帖数据补全（如详情刷新后才拿到可播地址）时补启动
      _start();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _playingSub?.cancel();
    _playback?.dispose();
    // 退出详情恢复系统默认方向（仅移动端动过方向设置）。
    if (_isMobile) {
      SystemChrome.setPreferredOrientations(const []);
    }
    // Windows IME 缓解：播放器原生窗口销毁后落定版重新关联
    //（含 350ms 延迟补刀，覆盖 mpv 窗口拆晚于 dispose 的竞态）。
    unawaited(ensureImeAttachedSettled());
    super.dispose();
  }

  void _initDims(WbStatus status) {
    // 默认档跟随设置里的默认视频清晰度；手动切档后 _current 已定，
    // 换帖时 _resetPlayback 会清掉它，这里重新按设置取档。
    final quality = context.read<SettingsService>().videoQuality;
    final p = status.video?.playbackFor(quality) ?? status.video?.defaultPlayback;
    _current = p;
    _videoWidth = p?.width;
    _videoHeight = p?.height;
  }

  void _resetPlayback() {
    _hideTimer?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _playingSub?.cancel();
    _playback?.dispose();
    _playback = null;
    _started = false;
    _failed = false;
    _current = null;
    _isPlaying = false;
    _controlsVisible = true;
  }

  /// 播放中启动/续上 3 秒隐藏计时；暂停时不隐藏。
  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_isPlaying) return;
    _hideTimer = Timer(_kControlsHideDelay, () {
      if (mounted && _isPlaying && _controlsVisible) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  /// 点画面唤回控制层，并重新计时。
  void _showControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHide();
  }

  /// 暂停/续播切换：暂停后控制层常显，续播后重新计时隐藏。
  Future<void> _togglePause() async {
    final playback = _playback;
    if (playback == null) return;
    if (_isPlaying) {
      await playback.pause();
      _hideTimer?.cancel();
      if (mounted) setState(() => _controlsVisible = true);
    } else {
      await playback.play();
      _showControls();
    }
  }

  Future<void> _start({WbPlayback? quality}) async {
    final video = widget.status.video;
    if (video == null) return;
    // 未手动选档时按设置里的默认清晰度取档；_current 已是该档时等价。
    final settingDefault = video.playbackFor(
      context.read<SettingsService>().videoQuality,
    );
    final target = quality ?? _current ?? settingDefault ?? video.defaultPlayback;
    final url = target?.url ?? video.defaultUrl;
    if (url == null || url.isEmpty) return;

    var playback = _playback;
    if (playback == null) {
      try {
        playback = (widget.playbackFactory ?? _mediaKitPlaybackFactory)(
          onEnterFullscreen: _enterFullscreen,
          onExitFullscreen: _exitFullscreen,
        );
      } catch (_) {
        // 原生库不可用等创建失败：回封面态，允许点击重试
        if (mounted) setState(() => _failed = true);
        return;
      }
      _playback = playback;
      _playingSub = playback.playingStream.listen((playing) {
        if (!mounted) return;
        setState(() {
          _isPlaying = playing;
          if (!playing) _controlsVisible = true;
        });
        if (playing) {
          _scheduleHide();
        } else {
          _hideTimer?.cancel();
        }
      });
      _widthSub = playback.widthStream.listen((w) {
        if (w != null && w > 0 && mounted) {
          setState(() => _videoWidth = w);
          _applyPageOrientations();
        }
      });
      _heightSub = playback.heightStream.listen((h) {
        if (h != null && h > 0 && mounted) {
          setState(() => _videoHeight = h);
          _applyPageOrientations();
        }
      });
    }

    if (mounted) {
      setState(() {
        _failed = false;
        _started = true;
        _current = target;
        _controlsVisible = true;
        if (target != null && target.width > 0 && target.height > 0) {
          _videoWidth = target.width;
          _videoHeight = target.height;
        }
      });
    }
    _applyPageOrientations();
    try {
      await playback.open(url);
    } catch (_) {
      playback.dispose();
      if (identical(_playback, playback)) _playback = null;
      if (mounted) setState(() => _failed = true);
    }
  }

  /// 详情页内允许的方向：横屏视频放开横屏，竖屏视频只留竖屏。仅移动端。
  List<DeviceOrientation> _pageOrientations() {
    if (_isLandscapeVideo) {
      return const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    return const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown];
  }

  void _applyPageOrientations() {
    if (!_isMobile) return;
    SystemChrome.setPreferredOrientations(_pageOrientations());
  }

  /// 全屏进入（media_kit 全屏路由回调）：移动端按视频比例定向；
  /// 桌面沿用 media_kit 默认实现。
  Future<void> _enterFullscreen() async {
    if (!_isMobile) {
      await defaultEnterNativeFullscreen();
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [],
    );
    await SystemChrome.setPreferredOrientations(
      _isLandscapeVideo
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
            ],
    );
  }

  /// 全屏退出：恢复系统栏与页面方向集合（组件销毁时再彻底放开）。
  Future<void> _exitFullscreen() async {
    if (!_isMobile) {
      await defaultExitNativeFullscreen();
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    await SystemChrome.setPreferredOrientations(_pageOrientations());
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.status.video;
    if (video == null) return const SizedBox.shrink();
    final ratio =
        (_videoWidth != null &&
            _videoHeight != null &&
            _videoWidth! > 0 &&
            _videoHeight! > 0)
        ? _videoWidth! / _videoHeight!
        : 16 / 9;
    return Center(
      child: ConstrainedBox(
        // 竖屏视频按真实比例展示时限制最大高度，避免撑满整页。
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.72,
        ),
        child: AspectRatio(
          aspectRatio: ratio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: (_started && _playback != null && !_failed)
                ? _buildSurfaceStack()
                : _buildCover(context),
          ),
        ),
      ),
    );
  }

  Widget _buildSurfaceStack() {
    final playbackList = widget.status.video?.playbackList ?? const [];
    return Stack(
      fit: StackFit.expand,
      children: [
        // 点画面唤回控制层（Listener 只监听指针按下，不与 media_kit
        // 自身手势抢夺，画质/全屏/暂停按钮在其上层，不触发这里）。
        Listener(
          onPointerDown: (_) => _showControls(),
          child: _playback!.buildSurface(),
        ),
        // 自有控制层：播放中 3 秒无操作自动隐藏，暂停时常显。
        if (_controlsVisible) ...[
          Positioned(
            top: 6,
            right: 6,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (playbackList.length > 1)
                  _circleButton(
                    child: PopupMenuButton<WbPlayback>(
                      icon: const Icon(
                        Icons.high_quality_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                      tooltip: '画质',
                      onSelected: (q) => _start(quality: q),
                      itemBuilder: (_) => [
                        for (final p in playbackList)
                          PopupMenuItem(
                            value: p,
                            child: Row(
                              children: [
                                Text(p.qualityLabel),
                                if (p.bitrate > 0)
                                  Text(
                                    '  ${(p.bitrate / 1000000).toStringAsFixed(1)}Mbps',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
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
                  ),
                if (playbackList.length > 1) const SizedBox(width: 6),
                // 显式全屏按钮（不依赖默认控件是否显示），走按比例定向逻辑
                _circleButton(
                  child: IconButton(
                    icon: const Icon(
                      Icons.fullscreen,
                      color: Colors.white,
                      size: 22,
                    ),
                    tooltip: '全屏',
                    onPressed: () => _playback?.toggleFullscreen(),
                  ),
                ),
                const SizedBox(width: 6),
                // 下载视频（按设置默认清晰度取档，与播放默认档一致）
                _circleButton(
                  child: VideoDownloadButton(
                    status: widget.status,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 6,
            bottom: 6,
            child: _circleButton(
              child: IconButton(
                key: const ValueKey('inline-player-pause'),
                icon: Icon(
                  _isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 22,
                ),
                tooltip: _isPlaying ? '暂停' : '播放',
                onPressed: _togglePause,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _circleButton({required Widget child}) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.black45,
        shape: BoxShape.circle,
      ),
      child: child,
    );
  }

  /// 未开播/开播失败的封面态：封面 + 大播放按钮，点击才（重新）开播。
  Widget _buildCover(BuildContext context) {
    final video = widget.status.video!;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (video.cover.isNotEmpty)
          NetImage(
            url: video.cover,
            fit: BoxFit.cover,
            errorBuilder: (_) => Container(color: Colors.black87),
          )
        else
          Container(color: Colors.black87),
        Container(color: Colors.black.withValues(alpha: 0.18)),
        // 未开播时也能直接下载视频（右上角）
        Positioned(
          top: 6,
          right: 6,
          child: _circleButton(
            child: VideoDownloadButton(
              status: widget.status,
              color: Colors.white,
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(
                  Icons.play_circle_fill,
                  size: 64,
                  color: Colors.white,
                ),
                tooltip: '播放',
                onPressed: () => _start(),
              ),
              if (_failed)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '播放器加载失败，点击重试',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          left: 8,
          bottom: 6,
          child: Text(
            video.onlineUsers.isNotEmpty
                ? video.onlineUsers
                : (widget.status.user?.screenName ?? ''),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        if (video.durationSec > 0)
          Positioned(
            right: 8,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                formatDurationSec(video.durationSec),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}
