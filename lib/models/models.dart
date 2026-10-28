import 'package:intl/intl.dart';

import '../core/long_image.dart';
import '../core/quality.dart';
import '../core/utils.dart';

/// 微博数据模型（只取客户端需要的子集）。
/// 服务端字段类型飘忽（数字可能是字符串、计数可能是 "1.2万"），处处防御。

int _intOf(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) {
    final n = int.tryParse(v.replaceAll(',', ''));
    if (n != null) return n;
    // "1.2万" / "9.3万" 这类格式化计数粗略还原
    final m = RegExp(r'^([\d.]+)\s*(万|亿)?$').firstMatch(v.trim());
    if (m != null) {
      final base = double.tryParse(m.group(1)!) ?? 0;
      final unit = m.group(2) == '亿'
          ? 100000000
          : m.group(2) == '万'
          ? 10000
          : 1;
      return (base * unit).round();
    }
    return 0;
  }
  return 0;
}

String _strOf(dynamic v) {
  if (v == null) return '';
  if (v is String) return v;
  return v.toString();
}

bool _boolOf(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return false;
}

Map<String, dynamic> _mapOf(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry('$k', val));
  return const {};
}

List<dynamic> _listOf(dynamic v) => v is List ? v : const [];

/// "Mon Oct 26 13:09:19 +0800 2026" (en_US)；解析失败返回 null。
DateTime? parseWbTime(String raw) {
  if (raw.isEmpty) return null;
  try {
    return DateFormat('EEE MMM dd HH:mm:ss Z yyyy', 'en_US').parse(raw);
  } catch (_) {
    // intl 对 'Z' 时区段解析不稳定：去掉 ±XXXX 只取本地时间部分
    final stripped = raw.replaceAll(RegExp(r'\s[+-]\d{4}\s'), ' ').trim();
    try {
      return DateFormat('EEE MMM dd HH:mm:ss yyyy', 'en_US').parse(stripped);
    } catch (_) {
      return DateTime.tryParse(raw);
    }
  }
}

class WbUser {
  final int id;
  final String screenName;
  final String avatar; // avatar_large 优先，其次 profile_image_url
  final bool verified;
  final int verifiedType;
  final String verifiedReason;
  final String description;
  final int followersCount;
  final String followersCountStr;
  final int friendsCount;
  final int statusesCount;
  final String location;
  final String coverImagePhone;

  const WbUser({
    required this.id,
    required this.screenName,
    this.avatar = '',
    this.verified = false,
    this.verifiedType = -1,
    this.verifiedReason = '',
    this.description = '',
    this.followersCount = 0,
    this.followersCountStr = '',
    this.friendsCount = 0,
    this.statusesCount = 0,
    this.location = '',
    this.coverImagePhone = '',
  });

  String get followersDisplay => followersCount > 0
      ? formatPlayCount(followersCount)
      : (followersCountStr.isNotEmpty ? followersCountStr : '0');

  factory WbUser.fromJson(Map<String, dynamic> j) {
    final avatarLarge = _strOf(j['avatar_large']);
    return WbUser(
      id: _intOf(j['id'] ?? j['uid']),
      screenName: _strOf(j['screen_name'] ?? j['name'] ?? j['nick']),
      avatar: httpsUrl(
        avatarLarge.isNotEmpty ? avatarLarge : _strOf(j['profile_image_url']),
      ),
      verified: _boolOf(j['verified']),
      verifiedType: _intOf(j['verified_type'] ?? -1),
      verifiedReason: _strOf(j['verified_reason']),
      description: _strOf(j['description']),
      followersCount: _intOf(j['followers_count']),
      followersCountStr: _strOf(j['followers_count_str']),
      friendsCount: _intOf(j['friends_count']),
      statusesCount: _intOf(j['statuses_count']),
      location: _strOf(j['location']),
      coverImagePhone: httpsUrl(_strOf(j['cover_image_phone'])),
    );
  }
}

class WbPic {
  final String pid;
  final String thumbnail;
  final String bmiddle;
  final String large;
  final String original;

  /// 接口给出的图片尺寸（像素，取 large 档）；接口没给时为 0，
  /// 长图判定改由查看器打开后用 ImageStream 解析真实尺寸。
  final int width;
  final int height;

  const WbPic({
    required this.pid,
    this.thumbnail = '',
    this.bmiddle = '',
    this.large = '',
    this.original = '',
    this.width = 0,
    this.height = 0,
  });

  String get bestLarge =>
      large.isNotEmpty ? large : (original.isNotEmpty ? original : bmiddle);
  String get bestMiddle => bmiddle.isNotEmpty ? bmiddle : bestLarge;

  /// 查看长图/原图优先 original，其次 large。
  String get bestOriginal => original.isNotEmpty ? original : bestLarge;

  /// 列表（帖子卡片、相册宫格）用图：跟随图片清晰度设置。
  String feedUrl(ImageQualityPref pref) {
    switch (pref) {
      case ImageQualityPref.standard:
        return bestMiddle;
      case ImageQualityPref.hd:
        return bestLarge;
      case ImageQualityPref.original:
        return bestOriginal;
      case ImageQualityPref.dataSaver:
        return thumbnail.isNotEmpty ? thumbnail : bestMiddle;
    }
  }

  /// 图库查看器用图：跟随图片清晰度设置。
  String galleryUrl(ImageQualityPref pref) {
    switch (pref) {
      case ImageQualityPref.standard:
        return bestLarge;
      case ImageQualityPref.hd:
      case ImageQualityPref.original:
        return bestOriginal;
      case ImageQualityPref.dataSaver:
        return bestMiddle;
    }
  }

  /// 长图查看器用图：长图查看本就是看原图，只有省流量档降为中图。
  String longViewerUrl(ImageQualityPref pref) {
    switch (pref) {
      case ImageQualityPref.dataSaver:
        return bestMiddle;
      case ImageQualityPref.standard:
      case ImageQualityPref.hd:
      case ImageQualityPref.original:
        return bestOriginal;
    }
  }

  /// 尺寸已知且高宽比 ≥2.5 → 长图。
  bool get isLongImage => isLongAspect(width, height);

  /// 尺寸是否已知（两个都 >0）。
  bool get hasSize => width > 0 && height > 0;
}

class WbPlayback {
  final String label;
  final int width;
  final int height;
  final String url;
  final int bitrate;

  const WbPlayback({
    required this.label,
    this.width = 0,
    this.height = 0,
    required this.url,
    this.bitrate = 0,
  });

  String get qualityLabel =>
      height > 0 ? '${height}p' : label.replaceFirst('mp4_', '');
}

class WbVideo {
  final String cover;
  final double durationSec;
  final String onlineUsers;
  final List<WbPlayback> playbackList; // 按高度降序
  final String fallbackUrl; // playback_list 为空时的直链

  const WbVideo({
    this.cover = '',
    this.durationSec = 0,
    this.onlineUsers = '',
    this.playbackList = const [],
    this.fallbackUrl = '',
  });

  bool get hasPlayable => playbackList.isNotEmpty || fallbackUrl.isNotEmpty;

  /// 默认档：<=720p 的最高档，没有则最低档
  WbPlayback? get defaultPlayback {
    if (playbackList.isEmpty) return null;
    for (final p in playbackList) {
      if (p.height <= 720) return p;
    }
    return playbackList.last;
  }

  /// 按清晰度设置选档：取「高度 ≤ 上限的最高档」，没有符合的取最低档；
  /// 最高档取档位表第一档；自动沿用 [defaultPlayback]。
  /// 高度为 0 的档不参与上限比较（元数据缺失时不被误选）。
  WbPlayback? playbackFor(VideoQualityPref pref) {
    if (playbackList.isEmpty) return null;
    if (pref == VideoQualityPref.auto) return defaultPlayback;
    if (pref == VideoQualityPref.highest) return playbackList.first;
    final cap = pref.maxHeight!;
    for (final p in playbackList) {
      if (p.height > 0 && p.height <= cap) return p;
    }
    return playbackList.last;
  }

  String? get defaultUrl =>
      defaultPlayback?.url ?? (fallbackUrl.isNotEmpty ? fallbackUrl : null);
}

class WbStatus {
  final String id;
  final String mblogid; // PC mblogid / m 端 bid
  final WbUser? user;
  final String text; // 展示文本（已剥 HTML）
  final String textRaw;
  final DateTime? createdAt;
  final String createdAtRaw;
  final String source;
  final int repostsCount;
  final int commentsCount;
  final int attitudesCount;
  final int readsCount;
  final List<WbPic> pics;
  final WbVideo? video;
  final bool isLongText;
  final WbStatus? retweeted;

  /// page_info.object_id（视频/直播对象 id，直播取流 getLiveInfo 用）。
  final String pageObjectId;

  /// page_info 为直播型（type 或 object_type == live）。直播回放通常仍带
  /// media_info 回放流；纯直播帖可能没有，需详情页再试 getLiveInfo。
  final bool isLive;

  /// page_info 封面（PC 为字符串、m 端为 {url} 对象），直播兜底封面用。
  final String pagePic;

  const WbStatus({
    required this.id,
    this.mblogid = '',
    this.user,
    this.text = '',
    this.textRaw = '',
    this.createdAt,
    this.createdAtRaw = '',
    this.source = '',
    this.repostsCount = 0,
    this.commentsCount = 0,
    this.attitudesCount = 0,
    this.readsCount = 0,
    this.pics = const [],
    this.video,
    this.isLongText = false,
    this.retweeted,
    this.pageObjectId = '',
    this.isLive = false,
    this.pagePic = '',
  });

  bool get hasVideo => video != null && video!.hasPlayable;

  WbStatus copyWith({
    String? text,
    String? textRaw,
    bool? isLongText,
    WbVideo? video,
  }) {
    return WbStatus(
      id: id,
      mblogid: mblogid,
      user: user,
      text: text ?? this.text,
      textRaw: textRaw ?? this.textRaw,
      createdAt: createdAt,
      createdAtRaw: createdAtRaw,
      source: source,
      repostsCount: repostsCount,
      commentsCount: commentsCount,
      attitudesCount: attitudesCount,
      readsCount: readsCount,
      pics: pics,
      video: video ?? this.video,
      isLongText: isLongText ?? this.isLongText,
      retweeted: retweeted,
      pageObjectId: pageObjectId,
      isLive: isLive,
      pagePic: pagePic,
    );
  }

  factory WbStatus.fromJson(Map<String, dynamic> j) {
    final rawText = _strOf(j['text_raw']);
    final htmlText = _strOf(j['text']);
    final text = rawText.isNotEmpty
        ? cleanWbText(rawText)
        : stripHtml(htmlText);

    // 视频/直播：PC page_info.object_type == 'video'/'live'；m 端 object_type
    // 为数字（11=视频）且 type == 'video'/'live'。取流在 media_info.playback_list。
    // （提到图片解析之前：媒体帖的 pics 需要按视频侧条目过滤，见下。）
    WbVideo? video;
    final pageInfo = _mapOf(j['page_info']);
    final piType = _strOf(pageInfo['type']);
    final piObjType = pageInfo['object_type'];
    final isMediaPage =
        pageInfo.isNotEmpty &&
        (piObjType == 'video' ||
            piObjType == 'live' ||
            piObjType == 11 ||
            piType == 'video' ||
            piType == 'live');
    if (isMediaPage) {
      final mi = _mapOf(pageInfo['media_info']);
      final playbacks = <WbPlayback>[];
      for (final item in _listOf(mi['playback_list'])) {
        final im = _mapOf(item);
        final play = _mapOf(im['play_info']);
        final url = httpsUrl(_strOf(play['url']));
        if (url.isEmpty) continue;
        final meta = _mapOf(im['meta']);
        playbacks.add(
          WbPlayback(
            label: _strOf(play['label'] ?? meta['label']),
            width: _intOf(play['width']),
            height: _intOf(play['height']),
            url: url,
            bitrate: _intOf(play['bitrate']),
          ),
        );
      }
      playbacks.sort((a, b) => b.height.compareTo(a.height));
      final dur = mi['duration'];
      var cover = _pagePicOf(pageInfo);
      if (cover.isEmpty) {
        final picInfo = _mapOf(pageInfo['pic_info']);
        cover = httpsUrl(_strOf(_mapOf(picInfo['pic_big'])['url']));
      }
      video = WbVideo(
        cover: cover,
        durationSec: dur is num ? dur.toDouble() : double.tryParse('$dur') ?? 0,
        onlineUsers: _strOf(mi['online_users']),
        playbackList: playbacks,
        fallbackUrl: httpsUrl(
          _strOf(mi['stream_url_hd'] ?? mi['mp4_hd_url'] ?? mi['stream_url']),
        ),
      );
    }

    // 图片：PC 用 pic_ids + pic_infos{pid:{thumbnail/bmiddle/large/original:{url}}}
    // m 端用 pics[{pid,url,large:{url}}]
    // 视频/直播帖的 pics 会混入视频侧条目（封面/视频帧）：访客实证的图文+
    // 视频混合帖里，pics 条数多于 pic_ids，多出的条目 pid 不在 pic_ids 内、
    // 与 page_pic 同上传批次，尺寸取视频帧尺寸——竖长视频（帧高宽比 ≥2.5）
    // 会被误判成长图。故媒体帖只保留 pid ∈ pic_ids 的真图片；pic_ids 为空
    // 时整组丢弃（纯视频帖 pics 本就应为空，封面由 page_pic 呈现，不受影响；
    // 视频合集/视频页签走 page_info 封面不用 pics，同样不受影响）。
    final picIdSet = _listOf(j['pic_ids']).map((e) => '$e').toSet();
    final coverPid = _strOf(_mapOf(pageInfo['page_pic'])['pid']);
    bool keepPic(String pid) {
      if (video == null) return true; // 非媒体帖：原样保留
      if (pid.isNotEmpty && pid == coverPid) return false; // 封面本体
      return picIdSet.contains(pid); // pic_ids 为空 → 全剔除
    }

    final pics = <WbPic>[];
    final picInfos = _mapOf(j['pic_infos']);
    final picIds = _listOf(j['pic_ids']);
    if (picInfos.isNotEmpty) {
      final pids = picIds.isNotEmpty
          ? picIds.map((e) => '$e').toList()
          : picInfos.keys.toList();
      for (final pid in pids) {
        final info = _mapOf(picInfos[pid]);
        if (info.isEmpty) continue;
        if (!keepPic(pid)) continue;
        String u(String k) => httpsUrl(_strOf(_mapOf(info[k])['url']));
        // 尺寸：各档位对象除 url 外通常还带 width/height（数字或字符串），
        // 优先 large，其次 original/bmiddle/thumbnail，取第一组有效值。
        var w = 0, h = 0;
        for (final k in ['large', 'original', 'bmiddle', 'thumbnail']) {
          final sizeObj = _mapOf(info[k]);
          w = _intOf(sizeObj['width']);
          h = _intOf(sizeObj['height']);
          if (w > 0 && h > 0) break;
        }
        pics.add(
          WbPic(
            pid: pid,
            thumbnail: u('thumbnail'),
            bmiddle: u('bmiddle'),
            large: u('large'),
            original: u('original'),
            width: w,
            height: h,
          ),
        );
      }
    } else {
      for (final p in _listOf(j['pics'])) {
        final pm = _mapOf(p);
        if (pm.isEmpty) continue;
        if (!keepPic(_strOf(pm['pid']))) continue;
        // m 端尺寸：large:{url,width,height} 或 geo:{width,height}
        final largeObj = _mapOf(pm['large']);
        final geo = _mapOf(pm['geo']);
        pics.add(
          WbPic(
            pid: _strOf(pm['pid']),
            thumbnail: httpsUrl(_strOf(pm['url'])),
            bmiddle: httpsUrl(_strOf(pm['url'])),
            large: httpsUrl(_strOf(largeObj['url'])),
            width: _intOf(largeObj['width'] ?? geo['width']),
            height: _intOf(largeObj['height'] ?? geo['height']),
          ),
        );
      }
    }

    final userMap = _mapOf(j['user']);
    final rtMap = _mapOf(j['retweeted_status']);
    final createdRaw = _strOf(j['created_at']);
    return WbStatus(
      id: _strOf(j['idstr'] ?? j['id'] ?? j['mid']),
      mblogid: _strOf(j['mblogid'] ?? j['bid']),
      user: userMap.isEmpty ? null : WbUser.fromJson(userMap),
      text: text,
      textRaw: rawText,
      createdAt: parseWbTime(createdRaw),
      createdAtRaw: createdRaw,
      source: cleanSource(_strOf(j['source'])),
      repostsCount: _intOf(j['reposts_count']),
      commentsCount: _intOf(j['comments_count']),
      attitudesCount: _intOf(j['attitudes_count']),
      readsCount: _intOf(j['reads_count']),
      pics: pics,
      video: video,
      isLongText: _boolOf(j['isLongText']),
      retweeted: rtMap.isEmpty ? null : WbStatus.fromJson(rtMap),
      pageObjectId: _strOf(pageInfo['object_id']),
      isLive: piObjType == 'live' || piType == 'live',
      pagePic: _pagePicOf(pageInfo),
    );
  }

  /// page_pic 两栈形态不一：PC 是 URL 字符串，m 端是 {url} 对象
  /// （注意 _strOf 对 Map 会 toString，必须按运行时类型分发）。
  static String _pagePicOf(Map<String, dynamic> pageInfo) {
    final pp = pageInfo['page_pic'];
    if (pp is String) return httpsUrl(pp);
    final m = _mapOf(pp);
    return m.isEmpty ? '' : httpsUrl(_strOf(m['url']));
  }
}

class WbComment {
  final String id;
  final WbUser? user;
  final String text;
  final String createdAtRaw;
  final String source;
  final int likeCount;
  final int floorNumber;

  /// 内嵌回复（楼中楼）：buildComments 响应里评论对象自带的 comments 子列表。
  /// 文档/主包未见独立的楼层分页接口证据，故只展示接口内嵌的这一层，
  /// 不另接接口（见 WEIBO_API.md 评论节）。
  final List<WbComment> replies;

  const WbComment({
    required this.id,
    this.user,
    this.text = '',
    this.createdAtRaw = '',
    this.source = '',
    this.likeCount = 0,
    this.floorNumber = 0,
    this.replies = const [],
  });

  factory WbComment.fromJson(Map<String, dynamic> j) {
    final userMap = _mapOf(j['user']);
    return WbComment(
      id: _strOf(j['idstr'] ?? j['id']),
      user: userMap.isEmpty ? null : WbUser.fromJson(userMap),
      text: stripHtml(_strOf(j['text'])),
      createdAtRaw: _strOf(j['created_at']),
      source: _strOf(j['source']),
      likeCount: _intOf(j['like_count'] ?? j['like_counts']),
      floorNumber: _intOf(j['floor_number']),
      replies: _listOf(j['comments'])
          .map((e) => WbComment.fromJson(_mapOf(e)))
          .where((c) => c.id.isNotEmpty)
          .toList(),
    );
  }
}

/// 点赞条目（m attitudes/show）
class WbAttitude {
  final String id;
  final WbUser? user;
  final String createdAtRaw;
  final String source;

  const WbAttitude({
    required this.id,
    this.user,
    this.createdAtRaw = '',
    this.source = '',
  });

  factory WbAttitude.fromJson(Map<String, dynamic> j) {
    final userMap = _mapOf(j['user']);
    return WbAttitude(
      id: _strOf(j['id']),
      user: userMap.isEmpty ? null : WbUser.fromJson(userMap),
      createdAtRaw: _strOf(j['created_at']),
      source: _strOf(j['source']),
    );
  }
}

class WbChannel {
  final String gid;
  final String title;
  final String containerid;

  const WbChannel({
    required this.gid,
    required this.title,
    required this.containerid,
  });

  factory WbChannel.fromJson(Map<String, dynamic> j) => WbChannel(
    gid: _strOf(j['gid']),
    title: _strOf(j['title'] ?? j['name']),
    containerid: _strOf(j['containerid'] ?? j['fid'] ?? j['gid']),
  );

  Map<String, dynamic> toJson() => {
    'gid': gid,
    'title': title,
    'containerid': containerid,
  };
}

class HotWord {
  final String word;
  final int num;
  final int realpos;
  final String label; // 爆/热/新 等
  final String flagDesc; // 综艺 等分类标

  const HotWord({
    required this.word,
    this.num = 0,
    this.realpos = 0,
    this.label = '',
    this.flagDesc = '',
  });

  factory HotWord.fromJson(Map<String, dynamic> j) => HotWord(
    word: _strOf(j['word'] ?? j['note']),
    num: _intOf(j['num']),
    realpos: _intOf(j['realpos']),
    label: _strOf(j['icon_desc'] ?? j['label_name']),
    flagDesc: _strOf(j['flag_desc']),
  );
}

class BandItem {
  final String word;
  final int num;
  final int realpos;
  final String category;
  final String label;

  const BandItem({
    required this.word,
    this.num = 0,
    this.realpos = 0,
    this.category = '',
    this.label = '',
  });

  factory BandItem.fromJson(Map<String, dynamic> j) => BandItem(
    word: _strOf(j['word'] ?? j['note']),
    num: _intOf(j['num'] ?? j['hot_num']),
    realpos: _intOf(j['realpos']),
    category: _strOf(j['category'] ?? j['m_category']),
    label: _strOf(j['icon_desc']),
  );
}

class WbPlaylist {
  final String id;
  final String name;
  final int itemCount;
  final bool isPay;

  const WbPlaylist({
    required this.id,
    required this.name,
    this.itemCount = 0,
    this.isPay = false,
  });

  factory WbPlaylist.fromJson(Map<String, dynamic> j) => WbPlaylist(
    id: _strOf(j['id_str'] ?? j['id']),
    name: _strOf(j['name']),
    itemCount: _intOf(j['item_count']),
    isPay: _intOf(j['is_pay']) != 0,
  );
}

/// m 容器一页解析结果
class ContainerPage {
  final List<WbStatus> statuses;
  final int total;
  final int nextPage;

  const ContainerPage({
    this.statuses = const [],
    this.total = 0,
    this.nextPage = 0,
  });
}

/// 热门流一页
class HotPage {
  final List<WbStatus> statuses;
  final int maxId;
  final int freshIdx;

  const HotPage({this.statuses = const [], this.maxId = 0, this.freshIdx = 1});
}

/// 搜索结果（综合页解析后拆分）
class SearchResult {
  final List<WbUser> users;
  final List<WbStatus> statuses;

  const SearchResult({this.users = const [], this.statuses = const []});
}

/// 把微博正文 HTML 剥成纯文本：<br>→换行、<img alt>保留表情文本、其余标签去掉。
String stripHtml(String html) {
  if (html.isEmpty) return '';
  var s = html;
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAllMapped(
    RegExp(r'<img[^>]*\balt="([^"]*)"[^>]*>', caseSensitive: false),
    (m) => m.group(1) ?? '',
  );
  s = s.replaceAll(RegExp(r'<img[^>]*>', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  s = s.replaceAll('​', '').trimRight();
  if (s.endsWith('全文')) s = s.substring(0, s.length - 2).trimRight();
  return s.trim();
}

/// text_raw 轻清洗：去掉零宽字符
String cleanWbText(String raw) => raw.replaceAll('​', '').trim();

/// source 清洗：可能是纯文本、<a>微博视频号</a> 或 "来自 湖南"
String cleanSource(String raw) {
  var s = stripHtml(raw).trim();
  if (s.startsWith('来自')) s = s.substring(2).trim();
  return s;
}

/// 搜索建议（PC /ajax/side/search）：联想词 + 推荐用户。
class SearchSuggest {
  final List<String> queries;
  final List<WbUser> users;

  const SearchSuggest({this.queries = const [], this.users = const []});

  bool get isEmpty => queries.isEmpty && users.isEmpty;
}

/// 用户相册（PC /ajax/profile/albumlist）。containerid 已剥掉
/// `&background=ffffff` 后缀（拉取时作为独立参数传）。
class WbAlbum {
  final String title;
  final String cover;
  final String containerid;

  const WbAlbum({this.title = '', this.cover = '', this.containerid = ''});

  factory WbAlbum.fromJson(Map<String, dynamic> j) {
    final raw = _strOf(j['containerid']);
    return WbAlbum(
      title: _strOf(j['pic_title']),
      cover: httpsUrl(_strOf(j['pic'])),
      containerid: raw.split('&').first,
    );
  }
}

/// 解析 statuses/config 的 data → 表情短码→图标 URL 映射。
/// 结构：data.emoticon = {语言: {分类: [{phrase: "[泪]", url: ...}]}}，
/// phrase 本身带方括号，正文里以原文形态出现。
Map<String, String> parseEmoticonMap(Map<String, dynamic> data) {
  final result = <String, String>{};
  for (final lang in _mapOf(data['emoticon']).values) {
    for (final cat in _mapOf(lang).values) {
      for (final item in _listOf(cat)) {
        final im = _mapOf(item);
        final phrase = _strOf(im['phrase']);
        final url = httpsUrl(_strOf(im['url']));
        if (phrase.isNotEmpty && url.isNotEmpty) result[phrase] = url;
      }
    }
  }
  return result;
}
