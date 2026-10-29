import 'package:extended_image_plus/extended_image_plus.dart';
import 'package:flutter/material.dart';

import '../core/long_image.dart';
import '../core/quality.dart';
import '../models/models.dart';
import 'network_image.dart';
import 'photo_gallery.dart';
import 'viewer_nav.dart';

/// 打开图片查看的统一入口：
/// - 单图帖 → [LongImageReader]：尺寸已知按已知判定长图；未知先按
///   普通缩放模式占位，打开后解析真实尺寸，是长图自动切滚动阅读。
/// - 多图帖点中已知长图 → [LongImageReader]（内含上一张/下一张，
///   可逐张翻看整组，其余图按各自尺寸决定模式）；
/// - 多图帖点中普通/未知图 → 原图库 [PhotoGalleryScreen]（左右滑 + 缩放）。
/// - [allowLongImage] 为 false 时（帖级长图准入收口判定不通过，如帖子
///   本级或转发原帖含视频/直播）一律走普通图库，绝不进长图阅读器。
void openPicViewer(
  BuildContext context,
  List<WbPic> pics,
  int index, {
  ImageQualityPref imageQuality = ImageQualityPref.standard,
  bool allowLongImage = true,
}) {
  if (pics.isEmpty) return;
  final i = index.clamp(0, pics.length - 1);
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => (allowLongImage && (pics.length == 1 || pics[i].isLongImage))
          ? LongImageReader(
              pics: pics,
              initialIndex: i,
              imageQuality: imageQuality,
            )
          : PhotoGalleryScreen(
              pics: pics,
              initialIndex: i,
              imageQuality: imageQuality,
            ),
    ),
  );
}

/// 长图阅读器：一组图片里以长图为入口时的查看页。
///
/// 每张图独立判定模式：
/// - 长图（接口尺寸已知，或打开后 ImageStream 解析出高宽比 ≥2.5）：
///   默认「滚动阅读」——宽度撑满、按原比例纵向滚动看全图；
///   AppBar 按钮或双击可切「缩放细看」（extended_image_plus 手势模式）。
/// - 普通图：缩放模式（与图库单页一致）。
/// - 尺寸未知：先按缩放模式占位，解析出是长图后自动切滚动阅读
///   （用户已手动切换过模式的图不自动改）。
///
/// 上一张/下一张按钮在 AppBar 右侧，长图模式内可逐张翻看整组图。
class LongImageReader extends StatefulWidget {
  final List<WbPic> pics;
  final int initialIndex;

  /// 查看用图档位：默认标准（长图查看原图，省流量档降为中图）。
  final ImageQualityPref imageQuality;

  const LongImageReader({
    super.key,
    required this.pics,
    this.initialIndex = 0,
    this.imageQuality = ImageQualityPref.standard,
  });

  @override
  State<LongImageReader> createState() => _LongImageReaderState();
}

class _LongImageReaderState extends State<LongImageReader> {
  late int _index = widget.initialIndex.clamp(0, widget.pics.length - 1);

  /// 每张图是否为长图：接口尺寸已知的 initState 即填；
  /// 未知的打开后用 ImageStream 解析补填。
  final Map<int, bool> _isLong = {};

  /// 用户手动切过的模式（true=滚动阅读，false=缩放），优先于自动判定。
  final Map<int, bool> _scrollOverride = {};

  final _scrollController = ScrollController();

  WbPic get _pic => widget.pics[_index];

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.pics.length; i++) {
      final p = widget.pics[i];
      if (p.hasSize) _isLong[i] = p.isLongImage;
    }
    _resolveSize(_index);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 尺寸未知时解析真实尺寸判定长图；失败按普通图处理。
  void _resolveSize(int i) {
    if (_isLong.containsKey(i)) return;
    final pic = widget.pics[i];
    final stream = ExtendedNetworkImageProvider(
      pic.longViewerUrl(widget.imageQuality),
      cache: true,
    ).resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!mounted) return;
        setState(
          () => _isLong[i] = isLongAspect(info.image.width, info.image.height),
        );
      },
      onError: (_, _) {
        stream.removeListener(listener);
        if (mounted) setState(() => _isLong[i] = false);
      },
    );
    stream.addListener(listener);
  }

  void _goTo(int i) {
    if (i < 0 || i >= widget.pics.length) return;
    setState(() => _index = i);
    _resolveSize(i);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// 当前图是否处于滚动阅读模式。
  bool get _scrollMode {
    final override = _scrollOverride[_index];
    if (override != null) return override;
    return _isLong[_index] ?? false;
  }

  void _toggleMode() {
    if (_isLong[_index] != true) return; // 只有长图有双模式
    setState(() => _scrollOverride[_index] = !_scrollMode);
  }

  @override
  Widget build(BuildContext context) {
    final pic = _pic;
    final isLong = _isLong[_index] == true;
    final multi = widget.pics.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        // 多图时才显示「第几页 / 总数」；单图只保留「长图」标识。
        title: multi
            ? Text(
                isLong
                    ? '长图 ${_index + 1} / ${widget.pics.length}'
                    : '${_index + 1} / ${widget.pics.length}',
              )
            : (isLong ? const Text('长图') : null),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '上一张',
            onPressed: _index > 0 ? () => _goTo(_index - 1) : null,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '下一张',
            onPressed: _index < widget.pics.length - 1
                ? () => _goTo(_index + 1)
                : null,
          ),
          if (isLong)
            IconButton(
              key: const ValueKey('long-image-mode-toggle'),
              icon: Icon(
                _scrollMode
                    ? Icons.zoom_in_outlined
                    : Icons.unfold_more_outlined,
              ),
              tooltip: _scrollMode ? '缩放细看' : '滚动阅读',
              onPressed: _toggleMode,
            ),
        ],
      ),
      body: ViewerKeyboardShortcuts(
        canPrev: _index > 0,
        canNext: _index < widget.pics.length - 1,
        onPrev: () => _goTo(_index - 1),
        onNext: () => _goTo(_index + 1),
        child: Stack(
          children: [
            _scrollMode ? _buildScrollBody(pic) : _buildZoomBody(pic),
            // 桌面/宽屏：查看区两侧上一张/下一张按钮（与图库统一；
            // AppBar 上的小箭头保留，窄屏仍可用）。
            if (multi && viewerShowsSideButtons(context))
              Positioned.fill(
                child: ViewerSideButtons(
                  index: _index,
                  count: widget.pics.length,
                  onGoTo: _goTo,
                ),
              ),
            // 多图时底部黑底页码（与图库一致），不拦截手势。
            if (multi)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    key: const ValueKey('long-image-page-indicator'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_index + 1} / ${widget.pics.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 滚动阅读：宽度撑满可用宽度、按原图比例显示完整长图，纵向滚动。
  Widget _buildScrollBody(WbPic pic) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onDoubleTap: _toggleMode,
          child: SingleChildScrollView(
            key: const ValueKey('long-image-scroll'),
            controller: _scrollController,
            child: NetImage(
              url: pic.longViewerUrl(widget.imageQuality),
              width: constraints.maxWidth,
              fit: BoxFit.fitWidth,
              placeholderBuilder: (_) => SizedBox(
                height: 420,
                width: constraints.maxWidth,
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
              errorBuilder: (_) => SizedBox(
                height: 300,
                width: constraints.maxWidth,
                child: const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 40,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 缩放细看：与图库单页一致的手势模式 ExtendedImage，
  /// 双击切回滚动阅读（与 AppBar 按钮同效）。
  Widget _buildZoomBody(WbPic pic) {
    return GestureImage(
      key: const ValueKey('long-image-zoom'),
      url: pic.longViewerUrl(widget.imageQuality),
      onDoubleTap: (_) => _toggleMode(),
    );
  }
}
