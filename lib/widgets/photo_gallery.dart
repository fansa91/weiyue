import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../models/models.dart';

/// 图片画廊：左右滑切换、双指缩放，看 large 图。
class PhotoGalleryScreen extends StatefulWidget {
  final List<WbPic> pics;
  final int initialIndex;
  const PhotoGalleryScreen(
      {super.key, required this.pics, this.initialIndex = 0});

  @override
  State<PhotoGalleryScreen> createState() => _PhotoGalleryScreenState();
}

class _PhotoGalleryScreenState extends State<PhotoGalleryScreen> {
  late int _index = widget.initialIndex;
  late final _controller = PageController(initialPage: widget.initialIndex);

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
      body: PhotoViewGallery.builder(
        pageController: _controller,
        itemCount: widget.pics.length,
        onPageChanged: (i) => setState(() => _index = i),
        builder: (context, i) {
          final pic = widget.pics[i];
          return PhotoViewGalleryPageOptions(
            imageProvider: CachedNetworkImageProvider(pic.bestLarge),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3,
            heroAttributes: PhotoViewHeroAttributes(tag: 'pic_${pic.pid}_$i'),
          );
        },
        loadingBuilder: (context, event) => const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
      ),
    );
  }
}
