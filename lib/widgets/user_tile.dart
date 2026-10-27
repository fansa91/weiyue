import 'package:flutter/material.dart';

import '../core/nav.dart';
import '../core/utils.dart';
import '../models/models.dart';
import 'cover_image.dart';

/// 用户行：头像 + 昵称（认证标）+ 简介/计数，点击进主页。
/// 搜索结果、点赞列表、评论区共用。
class UserTile extends StatelessWidget {
  final WbUser user;
  final String? subtitle;
  final String? trailingText;

  const UserTile({super.key, required this.user, this.subtitle, this.trailingText});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sub = subtitle ??
        (user.description.isNotEmpty
            ? user.description
            : '粉丝 ${formatPlayCount(user.followersCount)}');
    return ListTile(
      leading: CoverImage(
        url: user.avatar,
        size: 44,
        radius: 22,
        fallbackIcon: Icons.person_outline,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(user.screenName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (user.verified) ...[
            const SizedBox(width: 4),
            Icon(Icons.verified,
                size: 16,
                color: user.verifiedType == 3
                    ? const Color(0xFFF5A623)
                    : cs.primary),
          ],
        ],
      ),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailingText != null
          ? Text(trailingText!,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12))
          : const Icon(Icons.chevron_right, size: 18),
      onTap: () => openProfile(context, user.id),
    );
  }
}
