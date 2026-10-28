import 'package:extended_image_plus/extended_image_plus.dart';
import 'package:flutter/material.dart';

import '../core/quality.dart';
import '../models/models.dart';
import 'network_image.dart';

/// 图片画廊：左右滑切换、双指缩放，看 large 图。
///
/// 原 PhotoViewGallery 由 extended_image_plus 的
/// ExtendedImageGesturePageView + 手势模式 ExtendedImage 替代；
/// 原 PhotoView 的 heroAttributes 无对应 Hero 端承接（列表侧未包 Hero），
/// 迁移时直接去掉，不影响现有行为。
class PhotoGalleryScreen extends StatefulWidget {
  final List<WbPic> pics;
  final int initialIndex;

  /// 查看用图档位：默认标准（图库大图，省流量档降为中图）。
  final ImageQualityPref imageQuality;
  const PhotoGalleryScreen({
    super.key,
    required this.pics,
    this.initialIndex = 0,
    this.imageQuality = ImageQualityPref.standard,
  });

  @override
  State<PhotoGalleryScreen> createState() => _PhotoGalleryScreenState();
}

class _PhotoGalleryScreenState extends State<PhotoGalleryScreen> {
  late int _index = widget.initialIndex;
  late final _controller =
      ExtendedPageController(initialPage: widget.initialIndex);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.pics.length}'),
      ),
      body: ExtendedImageGesturePageView.builder(
        controller: _controller,
        itemCount: widget.pics.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          final pic = widget.pics[i];
          return GestureImage(
            url: pic.galleryUrl(widget.imageQuality),
            inPageView: true,
          );
        },
      ),
    );
  }
}
