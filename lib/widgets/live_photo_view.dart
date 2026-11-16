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
/// 预加载：成为当前页（[active]）即后台建播放器、打开首个候选并
/// 暂停待命（首帧已解码），播放意图到来时只 seek 回零 + 播放，
/// 视频层一盖上就是首帧画面，不再先黑一下才出画。
class LivePhotoView extends StatefulWidget {
  final WbPic pic;

  /// 静图地址（图库档位已由调用方选好）。
  final String imageUrl;

  /// 是否为图库当前页。
  final bool active;

  /// 静图是否位于图库翻页视图内（手势协调需与翻页配合时为 true）；
  /// 长图阅读器等独立单图场景传 false。
  final bool inPageView;

  /// 播放后端工厂（测试缝）；null 时用 media_kit 真实后端。
  final LivePlaybackFactory? playbackFactory;

  const LivePhotoView({
    super.key,
    required this.pic,
    required this.imageUrl,
    this.active = true,
    this.inPageView = true,
    this.playbackFactory,
  });

  @override
  State<LivePhotoView> createState() => _LivePhotoViewState();
}

class _LivePhotoViewState extends State<LivePhotoView> {
  LivePlayback? _playback;
  StreamSubscription<String>? _errorSub;

  /// 预加载任务（成为当前页时后台打开候选、暂停待命）；播放意图
  /// 到来时先等它落定再 seek+play，避免现开现播的首帧黑屏。
  Future<void>? _preloadTask;
  bool _preloading = false;

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
  void initState() {
    super.initState();
    _preload();
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
    // 成为当前页（或换了图）：后台预加载，播放时不再现开现等。
    if (widget.active) _preload();
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
    _preloadTask = null;
    _preloading = false;
  }

  /// 意图变化后对齐播放状态：有任一意图想播就开播，全部撤掉就停播。
  Future<void> _syncPlayback() async {
    if (_wantPlay) {
      await _startPlayback();
    } else {
      await _stopPlayback();
    }
  }

  /// 建播放器（工厂）并订阅错误流；已建则复用。原生库不可用等
  /// 创建失败时标记 _dead 静默保持静图，返回 null。
  LivePlayback? _ensurePlayback() {
    var playback = _playback;
    if (playback != null) return playback;
    try {
      playback = (widget.playbackFactory ??
          _mediaKitLivePlaybackFactory)();
    } catch (_) {
      // 原生库不可用等创建失败：静默保持静图
      _dead = true;
      return null;
    }
    _playback = playback;
    _errorSub = playback.errorStream.listen((_) => _onPlaybackError());
    return playback;
  }

  /// 预加载：后台打开首个候选并暂停待命（open 本身即暂停打开），
  /// 首帧解码就绪；打开失败的候选由 _openCandidate 自动顺延，
  /// 全部失败标记 _dead 回静图。视频层随打开成功挂载但透明度 0
  /// 不可见、不播放（见 build 的 live-video-layer）。
  void _preload() {
    if (!widget.active || _dead || _candidates.isEmpty) return;
    if (_playback != null || _preloading) return;
    _preloading = true;
    _preloadTask = _openCandidate(0).whenComplete(() {
      _preloading = false;
    });
  }

  Future<void> _startPlayback() async {
    if (_starting || _showVideo) return;
    if (!widget.active || _dead || _candidates.isEmpty) return;
    _starting = true;
    try {
      // 先等预加载落定（正在进行时），已预加载好直接走续播路径。
      final pending = _preloadTask;
      if (pending != null) await pending;
      if (!mounted || !_wantPlay || _dead) return;
      final playback = _playback;
      if (playback == null) {
        // 预加载没建起播放器（工厂失败已标记 _dead）或尚未预加载：
        // 走现开路径。
        if (_ensurePlayback() == null) return;
        await _openCandidate(0);
        return;
      }
      if (_candidateIndex >= 0) {
        // 已预加载/已开播过（停播只是暂停）：从头续播，首帧现成不黑屏
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
    final playback = _ensurePlayback();
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
    // 打开期间被翻页/换图释放过：这路候选作废，不再动界面
    if (!mounted || !identical(_playback, playback)) return;
    if (_wantPlay) {
      setState(() => _showVideo = true);
      await playback.play();
    } else {
      // 待命态：重建一次让视频层提前挂载（透明，见 build）——纹理在
      // 预加载期就建好并解码首帧，播放时只切透明度，不再临时建层。
      setState(() {});
    }
  }

  /// 播放中途出错（地址过期/网络失败）：还有候选就切下一个，
  /// 没有就静默回静图。无播放意图但已有预加载候选时也顺延候选
  /// （后台静默换好，下次播放不从坏地址起步）；什么都没加载时
  /// 忽略迟到的错误。
  void _onPlaybackError() {
    if (!mounted || _dead) return;
    if (!_wantPlay && _candidateIndex < 0) return;
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
              inPageView: widget.inPageView,
              enableSlideOutPage: true,
            ),
            // 视频层在候选打开成功后即挂载（预加载完成时，见
            // _openCandidate 的待命重建），未播放时透明度 0 藏在静图
            // 之上：纹理提前建好、首帧已解码，播放只把透明度切到 1。
            // 若等到播放时才挂载，纹理新建+首帧渲染的空窗会闪黑
            // （v0.2.6 真机实证：仅预加载 open 不挂层仍黑屏）。
            if (_playback != null && _candidateIndex >= 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    key: const ValueKey('live-video-layer'),
                    opacity: _showVideo ? 1.0 : 0.0,
                    child: _playback!.buildSurface(),
                  ),
                ),
              ),
            _buildBadge(),
          ],
        ),
      ),
    );
  }
}
