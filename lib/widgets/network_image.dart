import 'package:extended_image_plus/extended_image_plus.dart';
import 'package:flutter/material.dart';

/// 普通网络图（extended_image_plus 替代 CachedNetworkImage）。
///
/// loading / failed 时显示调用方给的占位；未给占位时显示空白，
/// 不沿用 extended_image 默认的转圈 / “Failed to load image” 文案，
/// 以保持原有各处的占位样式。
class NetImage extends StatelessWidget {
  final String url;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final WidgetBuilder? placeholderBuilder;
  final WidgetBuilder? errorBuilder;

  const NetImage({
    super.key,
    required this.url,
    this.fit,
    this.width,
    this.height,
    this.placeholderBuilder,
    this.errorBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return ExtendedImage.network(
      url,
      fit: fit,
      width: width,
      height: height,
      cache: true,
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return placeholderBuilder?.call(context) ?? const SizedBox.shrink();
          case LoadState.failed:
            return errorBuilder?.call(context) ?? const SizedBox.shrink();
          case LoadState.completed:
            return null;
        }
      },
    );
  }
}

/// 手势缩放图（extended_image_plus 替代 PhotoView）。
///
/// 初始为完整显示（contained），双击回调由调用方处理；
/// 缩放范围 0.8～3.0，近似原 PhotoView（contained～covered*3）的手感。
class GestureImage extends StatelessWidget {
  final String url;
  final DoubleTap? onDoubleTap;

  /// 在 ExtendedImageGesturePageView 内时必须为 true，
  /// 否则缩放后的拖动无法与翻页手势协调。
  final bool inPageView;

  const GestureImage({
    super.key,
    required this.url,
    this.onDoubleTap,
    this.inPageView = false,
  });

  @override
  Widget build(BuildContext context) {
    return ExtendedImage.network(
      url,
      cache: true,
      mode: ExtendedImageMode.gesture,
      initGestureConfigHandler: (_) => GestureConfig(
        minScale: 0.8,
        maxScale: 3.0,
        initialScale: 1.0,
        cacheGesture: false,
        inPageView: inPageView,
      ),
      onDoubleTap: onDoubleTap,
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          case LoadState.failed:
            return const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 40,
              ),
            );
          case LoadState.completed:
            return null;
        }
      },
    );
  }
}
