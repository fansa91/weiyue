import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 区块标题行：标题 + 右侧"更多"
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onMore;

  const SectionHeader({super.key, required this.title, this.onMore});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('更多',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                  Icon(Icons.chevron_right,
                      size: 16, color: AppColors.textSecondary),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
