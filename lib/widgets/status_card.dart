import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/nav.dart';
import '../core/utils.dart';
import '../models/models.dart';
import 'cover_image.dart';
import 'photo_gallery.dart';

/// 正文富文本：高亮 #话题#、@用户、链接（点击行为：话题/用户进搜索/主页
/// 需要上下文路由，这里只对 @ 与链接做可点处理，话题跳搜索页）。
List<TextSpan> buildWbTextSpans(
  BuildContext context,
  String text, {
  TextStyle? baseStyle,
  void Function(String topic)? onTopicTap,
  void Function(String word)? onLinkTap,
}) {
  final cs = Theme.of(context).colorScheme;
  final linkStyle = TextStyle(color: cs.primary);
  final pattern = RegExp(r'#[^#\s][^#]*#|@[^\s:：,，]+|https?://[^\s]+');
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    final token = m.group(0)!;
    spans.add(TextSpan(
      text: token,
      style: linkStyle,
      recognizer: token.startsWith('#')
          ? (TapGestureRecognizer()
            ..onTap = () => onTopicTap?.call(token))
          : token.startsWith('@')
              ? null
              : (TapGestureRecognizer()
                ..onTap = () => onLinkTap?.call(token)),
    ));
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

class WbRichText extends StatelessWidget {
  final String text;
  final int? maxLines;
  final double fontSize;

  const WbRichText(this.text, {super.key, this.maxLines, this.fontSize = 15});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: fontSize,
          height: 1.45,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        children: buildWbTextSpans(context, text),
      ),
      maxLines: maxLines,
      overflow: maxLines != null ? TextOverflow.ellipsis : TextOverflow.clip,
    );
  }
}

/// 平台标准帖子链接：优先 https://weibo.com/{作者uid}/{mblogid}；
/// mblogid 为空（或作者缺失）时退到 https://weibo.com/detail/{id}。
String wbStatusUrl(WbStatus status) {
  final uid = status.user?.id;
  if (status.mblogid.isNotEmpty && uid != null && uid > 0) {
    return 'https://weibo.com/$uid/${status.mblogid}';
  }
  return 'https://weibo.com/detail/${status.id}';
}

/// 微博卡片：头像行 / 正文 / 转发内嵌卡 / 图片宫格 / 视频封面 / 底栏计数。
class StatusCard extends StatelessWidget {
  final WbStatus status;

  /// 是否在列表中（列表点击整卡进详情；详情页里传 false 关掉跳转）
  final bool tappable;

  /// 详情页用完整正文
  final bool expanded;

  const StatusCard({
    super.key,
    required this.status,
    this.tappable = true,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final user = status.user;
    final cs = Theme.of(context).colorScheme;
    final card = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像行
          Row(
            children: [
              GestureDetector(
                onTap: user != null
                    ? () => openProfile(context, user.id)
                    : null,
                child: CoverImage(
                  url: user?.avatar ?? '',
                  size: 42,
                  radius: 21,
                  fallbackIcon: Icons.person_outline,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user?.screenName ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              color: (user?.verified ?? false)
                                  ? const Color(0xFFF07C22)
                                  : cs.onSurface,
                            ),
                          ),
                        ),
                        if (user?.verified ?? false) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.verified,
                              size: 15,
                              color: user!.verifiedType == 3
                                  ? const Color(0xFFF5A623)
                                  : cs.primary),
                        ],
                      ],
                    ),
                    Text(
                      [
                        formatTimeAgo(status.createdAt,
                            fallback: status.createdAtRaw),
                        if (status.source.isNotEmpty) '来自 ${status.source}',
                      ].join(' · '),
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 正文
          WbRichText(status.text, maxLines: expanded ? null : 8),
          if (status.isLongText && !expanded)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('全文',
                  style: TextStyle(color: cs.primary, fontSize: 14)),
            ),
          // 转发内嵌卡
          if (status.retweeted != null) ...[
            const SizedBox(height: 8),
            _RetweetedBlock(status: status.retweeted!),
          ],
          // 图片宫格
          if (status.pics.isNotEmpty) ...[
            const SizedBox(height: 8),
            _PicGrid(pics: status.pics),
          ],
          // 视频封面
          if (status.hasVideo) ...[
            const SizedBox(height: 8),
            _VideoCover(status: status),
          ],
          const SizedBox(height: 6),
          // 底栏计数
          Row(
            children: [
              _CountItem(
                  icon: Icons.repeat, count: status.repostsCount),
              _CountItem(
                  icon: Icons.mode_comment_outlined,
                  count: status.commentsCount),
              _CountItem(
                  icon: Icons.favorite_border,
                  count: status.attitudesCount),
              const Spacer(),
              if (status.readsCount > 0)
                Text('${formatPlayCount(status.readsCount)} 阅读',
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              // 分享：复制帖子链接（独立 IconButton，自行处理点击，
              // 不触发整卡进详情的 InkWell 手势）
              IconButton(
                icon: const Icon(Icons.share_outlined, size: 19),
                color: cs.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.only(left: 6),
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                tooltip: '复制链接',
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: wbStatusUrl(status)));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                          const SnackBar(content: Text('链接已复制')));
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
    if (!tappable) return Card(child: card);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openDetail(context, status),
        child: card,
      ),
    );
  }
}

class _CountItem extends StatelessWidget {
  final IconData icon;
  final int count;
  const _CountItem({required this.icon, required this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 28),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(
            count > 0 ? formatPlayCount(count) : '0',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _RetweetedBlock extends StatelessWidget {
  final WbStatus status;
  const _RetweetedBlock({required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = status.user?.screenName ?? '';
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WbRichText(
            name.isNotEmpty ? '@$name：${status.text}' : status.text,
            maxLines: 6,
            fontSize: 14,
          ),
          if (status.pics.isNotEmpty) ...[
            const SizedBox(height: 6),
            _PicGrid(pics: status.pics),
          ],
          if (status.hasVideo) ...[
            const SizedBox(height: 6),
            _VideoCover(status: status),
          ],
        ],
      ),
    );
  }
}

class _PicGrid extends StatelessWidget {
  final List<WbPic> pics;
  const _PicGrid({required this.pics});

  @override
  Widget build(BuildContext context) {
    if (pics.length == 1) {
      final pic = pics.first;
      return GestureDetector(
        onTap: () => _openGallery(context, 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320, maxWidth: 420),
            child: CachedNetworkImage(
              imageUrl: pic.bestMiddle,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _errBox(context, height: 180),
              placeholder: (_, _) => _errBox(context, height: 180),
            ),
          ),
        ),
      );
    }
    final cols = pics.length <= 4 ? 2 : 3;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: pics.length > 9 ? 9 : pics.length,
      itemBuilder: (context, i) {
        return GestureDetector(
          onTap: () => _openGallery(context, i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CachedNetworkImage(
              imageUrl: pics[i].bestMiddle,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _errBox(context),
              placeholder: (_, _) => _errBox(context),
            ),
          ),
        );
      },
    );
  }

  Widget _errBox(BuildContext context, {double? height}) {
    return Container(
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.broken_image_outlined)),
    );
  }

  void _openGallery(BuildContext context, int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PhotoGalleryScreen(pics: pics, initialIndex: index),
    ));
  }
}

class _VideoCover extends StatelessWidget {
  final WbStatus status;
  const _VideoCover({required this.status});

  @override
  Widget build(BuildContext context) {
    final video = status.video!;
    return GestureDetector(
      onTap: () => openPlayer(context, status),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (video.cover.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: video.cover,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) =>
                      Container(color: Colors.black87),
                )
              else
                Container(color: Colors.black87),
              Container(color: Colors.black.withValues(alpha: 0.18)),
              const Center(
                child: Icon(Icons.play_circle_fill,
                    size: 56, color: Colors.white),
              ),
              Positioned(
                left: 8,
                bottom: 6,
                child: Text(
                  video.onlineUsers.isNotEmpty
                      ? video.onlineUsers
                      : (status.user?.screenName ?? ''),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              if (video.durationSec > 0)
                Positioned(
                  right: 8,
                  bottom: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          ),
        ),
      ),
    );
  }
}
