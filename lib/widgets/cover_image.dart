import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 圆角图片，带加载占位与失败占位（头像/封面通用）
class CoverImage extends StatelessWidget {
  final String url;
  final double size;
  final double radius;
  final IconData fallbackIcon;

  const CoverImage({
    super.key,
    required this.url,
    this.size = 48,
    this.radius = 8,
    this.fallbackIcon = Icons.image_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? Container(
                color: AppColors.card,
                child: Icon(fallbackIcon, color: AppColors.textSecondary),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(
                  color: AppColors.card,
                  child: const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                errorWidget: (_, _, _) => Container(
                  color: AppColors.card,
                  child: Icon(fallbackIcon, color: AppColors.textSecondary),
                ),
              ),
      ),
    );
  }
}
