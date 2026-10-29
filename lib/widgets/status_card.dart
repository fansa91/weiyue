import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/emoticons.dart';
import '../core/long_image.dart';
import '../core/nav.dart';
import '../core/quality.dart';
import '../services/settings_service.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/download_service.dart';
import 'cover_image.dart';
import 'download_button.dart';
import 'interactions.dart';
import 'long_image_viewer.dart';
import 'network_image.dart';

/// 正文富文本分段：高亮 #话题#、@用户、链接，并把 [表情] 短码换成行内
/// 表情图（WidgetSpan）。话题点击默认打开话题页（见 WbRichText）；
/// 表情映射未就绪时短码保持原文，映射到达后自动刷新（Emoticons.version）。
List<InlineSpan> buildWbTextSpans(
  BuildContext context,
  String text, {
  TextStyle? baseStyle,
  void Function(String topic)? onTopicTap,
  void Function(String word)? onLinkTap,
  double emoticonSize = 18,
}) {
  final cs = Theme.of(context).colorScheme;
  final linkStyle = TextStyle(color: cs.primary);
  final pattern = RegExp(
    r'#[^#\s][^#]*#|@[^\s:：,，]+|https?://[^\s]+|\[[^\[\]\s]{1,16}\]',
  );
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    final token = m.group(0)!;
    if (token.startsWith('[')) {
      final url = Emoticons.urlOf(token);
      if (url != null && url.isNotEmpty) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: NetImage(
              url: url,
              width: emoticonSize,
              height: emoticonSize,
              errorBuilder: (_) => Text(token),
            ),
          ),
        );
      } else {
        spans.add(TextSpan(text: token));
      }
    } else {
      spans.add(
        TextSpan(
          text: token,
          style: linkStyle,
          recognizer: token.startsWith('#')
              ? (TapGestureRecognizer()..onTap = () => onTopicTap?.call(token))
              : token.startsWith('@')
              ? null
              : (TapGestureRecognizer()..onTap = () => onLinkTap?.call(token)),
        ),
      );
    }
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
    // 表情映射异步到达后，version 变化触发重建，正文短码换成表情图
    return ValueListenableBuilder<int>(
      valueListenable: Emoticons.version,
      builder: (context, _, _) => Text.rich(
        TextSpan(
          style: TextStyle(
            fontSize: fontSize,
            height: 1.45,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          children: buildWbTextSpans(
            context,
            text,
            onTopicTap: (token) => openTopic(context, token),
            emoticonSize: fontSize * 1.25,
          ),
        ),
        maxLines: maxLines,
        overflow: maxLines != null ? TextOverflow.ellipsis : TextOverflow.clip,
      ),
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

  /// 详情页可传入内嵌播放器替代视频封面（封面位置直接预览播放）；
  /// 列表态不传，保持封面 + 播放图标，避免列表出现多个播放器。
  final Widget? videoOverride;

  /// 视频封面「下载视频」用的下载服务覆盖（测试注入；默认共享实例）。
  final DownloadService? downloadService;

  /// 详情页用：底栏评论按钮改为打开评论编辑框（不传时随整卡进详情）。
  final VoidCallback? onCommentTap;

  /// 底栏互动（点赞/收藏/转发）成功后回传本地最新快照，
  /// 详情页据此同步页签计数；列表卡可不传。
  final ValueChanged<WbStatus>? onStatusChanged;

  const StatusCard({
    super.key,
    required this.status,
    this.tappable = true,
    this.expanded = false,
    this.videoOverride,
    this.downloadService,
    this.onCommentTap,
    this.onStatusChanged,
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
                          Icon(
                            Icons.verified,
                            size: 15,
                            color: user!.verifiedType == 3
                                ? const Color(0xFFF5A623)
                                : cs.primary,
                          ),
                        ],
                      ],
                    ),
                    Text(
                      [
                        formatTimeAgo(
                          status.createdAt,
                          fallback: status.createdAtRaw,
                        ),
                        if (status.source.isNotEmpty) '来自 ${status.source}',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
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
              child: Text(
                '全文',
                style: TextStyle(color: cs.primary, fontSize: 14),
              ),
            ),
          // 转发内嵌卡
          if (status.retweeted != null) ...[
            const SizedBox(height: 8),
            _RetweetedBlock(
              status: status.retweeted!,
              downloadService: downloadService,
            ),
          ],
          // 图片宫格
          if (status.pics.isNotEmpty) ...[
            const SizedBox(height: 8),
            _PicGrid(status: status),
          ],
          // 视频封面（详情页传 videoOverride 时换成内嵌播放器）
          if (status.hasVideo) ...[
            const SizedBox(height: 8),
            videoOverride ??
                _VideoCover(status: status, downloadService: downloadService),
          ],
          const SizedBox(height: 6),
          // 底栏互动区：转发/评论/点赞/收藏（可点，乐观更新，见
          // widgets/interactions.dart 的 StatusActionBar）
          Row(
            children: [
              StatusActionBar(
                status: status,
                onCommentTap: onCommentTap,
                onStatusChanged: onStatusChanged,
              ),
              const Spacer(),
              if (status.readsCount > 0)
                Text(
                  '${formatPlayCount(status.readsCount)} 阅读',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              // 分享：复制帖子链接（独立 IconButton，自行处理点击，
              // 不触发整卡进详情的 InkWell 手势）
              IconButton(
                icon: const Icon(Icons.share_outlined, size: 19),
                color: cs.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.only(left: 6),
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                tooltip: '复制链接',
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: wbStatusUrl(status)),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(const SnackBar(content: Text('链接已复制')));
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

class _RetweetedBlock extends StatelessWidget {
  final WbStatus status;
  final DownloadService? downloadService;
  const _RetweetedBlock({required this.status, this.downloadService});

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
            _PicGrid(status: status),
          ],
          if (status.hasVideo) ...[
            const SizedBox(height: 6),
            _VideoCover(status: status, downloadService: downloadService),
          ],
        ],
      ),
    );
  }
}

class _PicGrid extends StatelessWidget {
  final WbStatus status;
  const _PicGrid({required this.status});

  List<WbPic> get pics => status.pics;

  /// 视频/直播帖的图片区只是兜底呈现（解析层已剔除混入的封面/视频帧，
  /// 漏网时到这里）：不标「长图」、点图进详情走视频，不进长图阅读器。
  /// 判据走长图准入收口：本级或转发原帖任一含视频/直播即拦截
  ///（见 core/long_image.dart 的 statusAllowsLongImage）。
  bool get _isVideoPost => !statusAllowsLongImage(status);

  void _onTapPic(BuildContext context, int i, ImageQualityPref imageQuality) {
    if (_isVideoPost) {
      openDetail(context, status);
    } else {
      openPicViewer(
        context,
        pics,
        i,
        imageQuality: imageQuality,
        allowLongImage: statusAllowsLongImage(status),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 列表用图档位跟随设置；改设置后列表即时重建换档。
    final imageQuality = context.watch<SettingsService>().imageQuality;
    if (pics.length == 1) {
      final pic = pics.first;
      return GestureDetector(
        onTap: () => _onTapPic(context, 0, imageQuality),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 320,
                  maxWidth: 420,
                ),
                child: NetImage(
                  url: pic.feedUrl(imageQuality),
                  fit: BoxFit.cover,
                  errorBuilder: (_) => _errBox(context, height: 180),
                  placeholderBuilder: (_) => _errBox(context, height: 180),
                ),
              ),
              // 已知尺寸的长图：封顶高度裁剪展示 + 「长图」角标，
              // 点开进长图阅读器（宽撑满纵向滚动）。视频帖不标（见 _isVideoPost）。
              if (!_isVideoPost && pic.isLongImage)
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      '长图',
                      style: TextStyle(color: Colors.white, fontSize: 11.5),
                    ),
                  ),
                ),
            ],
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
          onTap: () => _onTapPic(context, i, imageQuality),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: NetImage(
              url: pics[i].feedUrl(imageQuality),
              fit: BoxFit.cover,
              errorBuilder: (_) => _errBox(context),
              placeholderBuilder: (_) => _errBox(context),
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
}

class _VideoCover extends StatelessWidget {
  final WbStatus status;
  final DownloadService? downloadService;
  const _VideoCover({required this.status, this.downloadService});

  @override
  Widget build(BuildContext context) {
    final video = status.video!;
    return GestureDetector(
      // 点封面进详情页内嵌预览播放，不再跳独立播放页
      onTap: () => openDetail(context, status),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
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
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  size: 56,
                  color: Colors.white,
                ),
              ),
              // 右上角「更多」菜单：下载视频（按设置默认清晰度取档）
              Positioned(
                top: 4,
                right: 4,
                child: VideoDownloadButton(
                  status: status,
                  asMenu: true,
                  service: downloadService,
                ),
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
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
