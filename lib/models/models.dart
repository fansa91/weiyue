import 'dart:convert';

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
  final String gender;
  final String birthday;
  final String coverImage;
  final String coverImagePhone;

  /// 当前登录用户是否已关注此人（接口 user 对象自带 following 字段，
  /// 访客态恒 false；关注/取关按钮的初始态来源）。
  final bool following;

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
    this.gender = '',
    this.birthday = '',
    this.coverImage = '',
    this.coverImagePhone = '',
    this.following = false,
  });

  /// 封面展示图：手机版封面优先，其次通用封面。
  String get bestCover =>
      coverImagePhone.isNotEmpty ? coverImagePhone : coverImage;

  WbUser copyWith({
    int? id,
    String? screenName,
    String? avatar,
    bool? verified,
    int? verifiedType,
    String? verifiedReason,
    String? description,
    int? followersCount,
    String? followersCountStr,
    int? friendsCount,
    int? statusesCount,
    String? location,
    String? gender,
    String? birthday,
    String? coverImage,
    String? coverImagePhone,
    bool? following,
  }) {
    return WbUser(
      id: id ?? this.id,
      screenName: screenName ?? this.screenName,
      avatar: avatar ?? this.avatar,
      verified: verified ?? this.verified,
      verifiedType: verifiedType ?? this.verifiedType,
      verifiedReason: verifiedReason ?? this.verifiedReason,
      description: description ?? this.description,
      followersCount: followersCount ?? this.followersCount,
      followersCountStr: followersCountStr ?? this.followersCountStr,
      friendsCount: friendsCount ?? this.friendsCount,
      statusesCount: statusesCount ?? this.statusesCount,
      location: location ?? this.location,
      gender: gender ?? this.gender,
      birthday: birthday ?? this.birthday,
      coverImage: coverImage ?? this.coverImage,
      coverImagePhone: coverImagePhone ?? this.coverImagePhone,
      following: following ?? this.following,
    );
  }

  /// 存本地会话用（字段名与接口一致，fromJson 可直接读回）。
  Map<String, dynamic> toJson() => {
    'id': id,
    'screen_name': screenName,
    'avatar_large': avatar,
    'verified': verified,
    'verified_type': verifiedType,
    'verified_reason': verifiedReason,
    'description': description,
    'followers_count': followersCount,
    'followers_count_str': followersCountStr,
    'friends_count': friendsCount,
    'statuses_count': statusesCount,
    'location': location,
    'gender': gender,
    'birthday': birthday,
    'cover_image': coverImage,
    'cover_image_phone': coverImagePhone,
    'following': following,
  };

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
      gender: _strOf(j['gender']),
      birthday: _strOf(j['birthday']),
      coverImage: httpsUrl(_strOf(j['cover_image'])),
      coverImagePhone: httpsUrl(_strOf(j['cover_image_phone'])),
      following: _boolOf(j['following']),
    );
  }
}

/// .mov 直链是否像样：真实 fid 文件名主干有 30+ 字符；接口偶发残缺
/// 空壳（解码出 https://us.sinaimg.cn/.mov，主干为空）必须判无效。
bool _isPlausibleMovUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty || uri.pathSegments.isEmpty) {
    return false;
  }
  final seg = uri.pathSegments.last;
  if (!seg.toLowerCase().endsWith('.mov')) return false;
  return seg.length - 4 >= 8;
}

/// 从 media/play 包装地址的 livephoto= 参数解码出 .mov 直链；
/// 无此参数或解出的不是像样的 .mov 时返回空串。
String _livePhotoDirectUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return '';
  final inner = uri.queryParameters['livephoto'];
  if (inner == null || inner.isEmpty) return '';
  return _isPlausibleMovUrl(inner) ? httpsUrl(inner) : '';
}

/// 实况地址是否有效：包装地址看其 livephoto= 直链，直链看自身。
bool _isValidLiveVideoUrl(String url) {
  final direct = _livePhotoDirectUrl(url);
  return _isPlausibleMovUrl(direct.isNotEmpty ? direct : url);
}

/// 在候选地址（按优先级排列）里挑第一个有效的作主播放地址，
/// 并解出兜底直链（优先从主地址解，主地址无参数时再看其余候选）。
/// 全无效时主/兜底都为空串（该图按普通照片处理）。
({String primary, String fallback}) _pickLiveVideo(List<String> candidates) {
  final cleaned = [for (final c in candidates) httpsUrl(c.trim())];
  for (final url in cleaned) {
    if (url.isEmpty || !_isValidLiveVideoUrl(url)) continue;
    var fallback = _livePhotoDirectUrl(url);
    if (fallback.isEmpty) {
      for (final other in cleaned) {
        if (other.isEmpty || other == url) continue;
        fallback = _livePhotoDirectUrl(other);
        if (fallback.isNotEmpty) break;
      }
    }
    return (primary: url, fallback: fallback);
  }
  return (primary: '', fallback: '');
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

  /// 实况照片（Live Photo）动态部分的主播放地址：media/play 包装地址
  /// （PC pic_infos 的 video_hd 优先、video 兜底，见 [_pickLiveVideo]；
  /// m pics 的 videoSrc）。普通照片为空串。
  final String liveVideoUrl;

  /// 实况照片动态部分的兜底直链：从主地址的 livephoto= 参数解码出的
  /// .mov 直链，主地址播放失败时切换。无可解码参数时为空串。
  final String liveVideoFallbackUrl;

  const WbPic({
    required this.pid,
    this.thumbnail = '',
    this.bmiddle = '',
    this.large = '',
    this.original = '',
    this.width = 0,
    this.height = 0,
    this.liveVideoUrl = '',
    this.liveVideoFallbackUrl = '',
  });

  /// 是否实况照片：以解析到有效动态地址为准（残缺地址不算）。
  bool get isLivePhoto => liveVideoUrl.isNotEmpty;

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

/// 投票的一个选项（主包 FeedVote 组件 vote_list 条目字段实证，2026-11-12）：
/// id / content / part_num（票数）/ part_ratio（占比 0..1）/ selected（1=本人已选）。
class WbVoteItem {
  final int id;
  final String content;
  final int partNum;
  final double partRatio;
  final bool selected;

  const WbVoteItem({
    required this.id,
    this.content = '',
    this.partNum = 0,
    this.partRatio = 0,
    this.selected = false,
  });

  factory WbVoteItem.fromJson(Map<String, dynamic> j) {
    final ratio = j['part_ratio'];
    return WbVoteItem(
      id: _intOf(j['id']),
      content: _strOf(j['content']),
      partNum: _intOf(j['part_num']),
      partRatio: ratio is num
          ? ratio.toDouble()
          : double.tryParse('${ratio ?? ''}') ?? 0,
      selected: _intOf(j['selected']) == 1,
    );
  }
}

/// 帖子投票（PC 帖子 card_info.vote_object，主包 FeedVote 组件实证）：
/// parted>0 本人已投；state==0 已结束；is_multi_select==1 多选，
/// 多选可选区间 [minimum, maximum]；expire_date 为截止秒级时间戳。
class WbVote {
  final int id;
  final List<WbVoteItem> items;
  final int partInfo; // 总参与人数
  final bool voted;
  final bool multiSelect;
  final bool ended;
  final int minimum;
  final int maximum;
  final DateTime? expireAt;
  final String userNick;

  const WbVote({
    required this.id,
    this.items = const [],
    this.partInfo = 0,
    this.voted = false,
    this.multiSelect = false,
    this.ended = false,
    this.minimum = 1,
    this.maximum = 1,
    this.expireAt,
    this.userNick = '',
  });

  /// 结构不完整（无 id 或无选项）返回 null：普通帖子恒为 null。
  static WbVote? tryParse(Map<String, dynamic> j) {
    if (j.isEmpty) return null;
    final id = _intOf(j['id']);
    final items = [
      for (final e in _listOf(j['vote_list'])) WbVoteItem.fromJson(_mapOf(e)),
    ].where((e) => e.id > 0).toList();
    if (id <= 0 || items.isEmpty) return null;
    final expire = _intOf(j['expire_date']);
    final maxRaw = _intOf(j['maximum']);
    return WbVote(
      id: id,
      items: items,
      partInfo: _intOf(j['part_info']),
      voted: _intOf(j['parted']) > 0,
      multiSelect: _intOf(j['is_multi_select']) == 1,
      ended: _intOf(j['state']) == 0,
      minimum: _intOf(j['minimum']) > 0 ? _intOf(j['minimum']) : 1,
      maximum: maxRaw > 0 ? maxRaw : items.length,
      expireAt: expire > 0
          ? DateTime.fromMillisecondsSinceEpoch(expire * 1000)
          : null,
      userNick: _strOf(j['user_nick']),
    );
  }
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

  /// 当前登录用户是否已赞此帖（接口 attitudes_status：0 未赞、非 0 已赞；
  /// 访客态恒 false）。点赞按钮初始态与乐观更新的回滚基线。
  final bool liked;

  /// 当前登录用户是否已收藏此帖（接口 favorited 字段，抓包实证存在）。
  final bool favorited;

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

  /// 帖子投票（card_info.vote_object）；无投票为 null。
  final WbVote? vote;

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
    this.liked = false,
    this.favorited = false,
    this.pics = const [],
    this.video,
    this.isLongText = false,
    this.retweeted,
    this.pageObjectId = '',
    this.isLive = false,
    this.pagePic = '',
    this.vote,
  });

  bool get hasVideo => video != null && video!.hasPlayable;

  /// 本级或转发链任一层含视频/直播：长图准入的硬兜底判据
  ///（见 core/long_image.dart 的 statusAllowsLongImage）。
  bool get hasAnyMediaVideo =>
      hasVideo || isLive || (retweeted?.hasAnyMediaVideo ?? false);

  WbStatus copyWith({
    String? text,
    String? textRaw,
    bool? isLongText,
    WbVideo? video,
    int? repostsCount,
    int? commentsCount,
    int? attitudesCount,
    bool? liked,
    bool? favorited,
    WbVote? vote,
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
      repostsCount: repostsCount ?? this.repostsCount,
      commentsCount: commentsCount ?? this.commentsCount,
      attitudesCount: attitudesCount ?? this.attitudesCount,
      readsCount: readsCount,
      liked: liked ?? this.liked,
      favorited: favorited ?? this.favorited,
      pics: pics,
      video: video ?? this.video,
      isLongText: isLongText ?? this.isLongText,
      retweeted: retweeted,
      pageObjectId: pageObjectId,
      isLive: isLive,
      pagePic: pagePic,
      vote: vote,
    );
  }

  factory WbStatus.fromJson(Map<String, dynamic> j) {
    final rawText = _strOf(j['text_raw']);
    final htmlText = _strOf(j['text']);
    final text = rawText.isNotEmpty
        ? cleanWbText(rawText)
        : stripHtml(htmlText);

    // 视频/直播：主来源是 page_info（PC object_type == 'video'/'live'；
    // m 端 object_type 为数字 11 且 type == 'video'/'live'）。取流在
    // media_info.playback_list。
    // 次来源是 mix_media_info（PC 新结构，访客实证 2026-10-29）：图文/多
    // 视频混合帖没有 page_info、没有 pic_infos，全部媒体在
    // mix_media_info.items[] 里——pic 项 data 与 pic_infos 条目同构，
    // video 项 data 与 page_info 同构（media_info 带 playback_list）。
    // 旧解析对这类帖 pics 全丢、video=null，视频既播不了，其封面在别的
    // 数据形态下还会被当普通图判长图，故这里统一分流。
    // （视频解析提到图片解析之前：媒体帖的 pics 需要按视频侧条目过滤。）
    final pageInfo = _mapOf(j['page_info']);
    final mixItems = <Map<String, dynamic>>[];
    for (final e in _listOf(_mapOf(j['mix_media_info'])['items'])) {
      final m = _mapOf(e);
      if (m.isNotEmpty) mixItems.add(m);
    }
    Map<String, dynamic>? mixVideoData;
    for (final it in mixItems) {
      final t = _strOf(it['type']);
      if (t == 'video' || t == 'live') {
        mixVideoData = _mapOf(it['data']);
        break;
      }
    }
    var mediaMap = pageInfo;
    if (!_isMediaMap(mediaMap) &&
        mixVideoData != null &&
        _isMediaMap(mixVideoData)) {
      mediaMap = mixVideoData;
    }
    WbVideo? video;
    if (_isMediaMap(mediaMap)) {
      video = _buildVideo(mediaMap);
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
    var coverPid = _strOf(_mapOf(pageInfo['page_pic'])['pid']);
    if (coverPid.isEmpty && mixVideoData != null) {
      coverPid = _strOf(_mapOf(mixVideoData['page_pic'])['pid']);
    }
    bool keepPic(String pid) {
      if (video == null) return true; // 非媒体帖：原样保留
      if (pid.isNotEmpty && pid == coverPid) return false; // 封面本体
      return picIdSet.contains(pid); // pic_ids 为空 → 全剔除
    }

    // pic_infos 条目 / mix pic 项 data 同构，共用一个构建器。
    WbPic picFromInfo(String pid, Map<String, dynamic> info) {
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
      // 实况照片（type=='livephoto'）另带 video / video_hd 两个
      // media/play 包装地址（带时效签名，实测样本 pc_hottimeline_p2）：
      // hd 优先，但 hd 偶见残缺空壳，_pickLiveVideo 按有效性回落。
      var liveUrl = '', liveFallback = '';
      if (_strOf(info['type']) == 'livephoto') {
        final picked = _pickLiveVideo([
          _strOf(info['video_hd']),
          _strOf(info['video']),
        ]);
        liveUrl = picked.primary;
        liveFallback = picked.fallback;
      }
      return WbPic(
        pid: pid,
        thumbnail: u('thumbnail'),
        bmiddle: u('bmiddle'),
        large: u('large'),
        original: u('original'),
        width: w,
        height: h,
        liveVideoUrl: liveUrl,
        liveVideoFallbackUrl: liveFallback,
      );
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
        // 条目自带 type 标记为视频的，是视频封面/帧，不是照片
        //（type=='livephoto' 是实况照片，仍按图片保留）。
        if (_strOf(info['type']) == 'video') continue;
        if (!keepPic(pid)) continue;
        pics.add(picFromInfo(pid, info));
      }
    } else if (mixItems.any((it) => _strOf(it['type']) == 'pic')) {
      // mix 帖的图片只在 items 里（pic_infos 为空）：pic 项由 type 显式
      // 标记，不走 pic_ids 过滤（避免与 pic_ids 形态差异误杀真图），
      // 只排除与视频封面同 pid 的条目（防御）。
      for (final it in mixItems) {
        if (_strOf(it['type']) != 'pic') continue;
        final data = _mapOf(it['data']);
        if (data.isEmpty) continue;
        final pid = _strOf(it['id'] ?? data['pic_id']);
        if (pid.isNotEmpty && pid == coverPid) continue;
        pics.add(picFromInfo(pid, data));
      }
    } else {
      for (final p in _listOf(j['pics'])) {
        final pm = _mapOf(p);
        if (pm.isEmpty) continue;
        // m 端混合帖的 pics 里混有 type=='video' 的条目（带 videoSrc，
        // 是视频封面/帧）：按 type 标记直接剔除，不再单靠 pic_ids 名单
        //（名单完整性在不同容器下并不一致）。
        // 例外：type=='livephoto' 的条目同样带 videoSrc，但那是实况
        // 照片的动态部分（实测样本 raw/m_hot_local.json），按图片保留
        // 并把 videoSrc 接成实况播放地址。
        final pmType = _strOf(pm['type']);
        if (pmType == 'video') continue;
        if (pmType != 'livephoto' && pm.containsKey('videoSrc')) continue;
        if (!keepPic(_strOf(pm['pid']))) continue;
        var liveUrl = '', liveFallback = '';
        if (pmType == 'livephoto') {
          final picked = _pickLiveVideo([_strOf(pm['videoSrc'])]);
          liveUrl = picked.primary;
          liveFallback = picked.fallback;
        }
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
            liveVideoUrl: liveUrl,
            liveVideoFallbackUrl: liveFallback,
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
      // attitudes_status：抓包实证字段（0 未赞；已赞为态度 id/类型值）。
      // 个别形态另给 liked 布尔，一并兼容。
      liked: _intOf(j['attitudes_status']) != 0 || _boolOf(j['liked']),
      favorited: _boolOf(j['favorited']),
      pics: pics,
      video: video,
      isLongText: _boolOf(j['isLongText']),
      retweeted: rtMap.isEmpty ? null : WbStatus.fromJson(rtMap),
      pageObjectId: _strOf(pageInfo['object_id'] ?? mediaMap['object_id']),
      isLive: _isLiveMap(pageInfo) || _isLiveMap(mediaMap),
      pagePic: () {
        final pp = _pagePicOf(pageInfo);
        return pp.isNotEmpty ? pp : _pagePicOf(mediaMap);
      }(),
      // 投票：主包 FeedVote 从 data.card_info.vote_object 取（逐字实证）；
      // 顶层 vote_object 仅作防御式兜底。
      vote: WbVote.tryParse(
        _mapOf(_mapOf(j['card_info'])['vote_object']).isNotEmpty
            ? _mapOf(_mapOf(j['card_info'])['vote_object'])
            : _mapOf(j['vote_object']),
      ),
    );
  }

  /// page_info / mix video 项 data 是否为视频/直播媒体映射：
  /// object_type ∈ {'video','live',11} 或 type ∈ {'video','live','11'}。
  static bool _isMediaMap(Map<String, dynamic> m) {
    if (m.isEmpty) return false;
    final objType = m['object_type'];
    final type = _strOf(m['type']);
    return objType == 'video' ||
        objType == 'live' ||
        objType == 11 ||
        type == 'video' ||
        type == 'live' ||
        type == '11';
  }

  static bool _isLiveMap(Map<String, dynamic> m) =>
      m['object_type'] == 'live' || _strOf(m['type']) == 'live';

  /// 从 page_info 同构映射构建视频（mix video 项的 data 与之同构，共用）。
  static WbVideo _buildVideo(Map<String, dynamic> mediaMap) {
    final mi = _mapOf(mediaMap['media_info']);
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
    var cover = _pagePicOf(mediaMap);
    if (cover.isEmpty) {
      final picInfo = _mapOf(mediaMap['pic_info']);
      cover = httpsUrl(_strOf(_mapOf(picInfo['pic_big'])['url']));
    }
    return WbVideo(
      cover: cover,
      durationSec: dur is num ? dur.toDouble() : double.tryParse('$dur') ?? 0,
      onlineUsers: _strOf(mi['online_users']),
      playbackList: playbacks,
      fallbackUrl: httpsUrl(
        _strOf(mi['stream_url_hd'] ?? mi['mp4_hd_url'] ?? mi['stream_url']),
      ),
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

  /// 当前登录用户是否已赞此评论（主包评论数据变换实证字段
  /// `liked`，访客态样本不带、默认 false）。
  final bool liked;
  final int floorNumber;

  /// 内嵌回复（楼中楼）：buildComments 响应里评论对象自带的 comments 子列表。
  /// 文档/主包未见独立的楼层分页接口证据，故只展示接口内嵌的这一层，
  /// 不另接接口（见 WEIBO_API.md 评论节）。
  final List<WbComment> replies;

  /// 评论配图（至多一张；无图为 null）。字段证据见 [_picFromJson]。
  final WbPic? pic;

  const WbComment({
    required this.id,
    this.user,
    this.text = '',
    this.createdAtRaw = '',
    this.source = '',
    this.likeCount = 0,
    this.liked = false,
    this.floorNumber = 0,
    this.replies = const [],
    this.pic,
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
      liked: _boolOf(j['liked']),
      floorNumber: _intOf(j['floor_number']),
      replies: _listOf(j['comments'])
          .map((e) => WbComment.fromJson(_mapOf(e)))
          .where((c) => c.id.isNotEmpty)
          .toList(),
      pic: _picFromJson(j),
    );
  }

  /// 评论配图解析（2026-11-12 访客探针实证，帖 5356521951070602 热评）：
  /// pic_num>0 的评论在 url_struct 的「查看图片」条目里带
  /// pic_infos{pid: {thumbnail/bmiddle/large/woriginal}}，与帖子
  /// pic_infos 条目同构（原图档键名是 woriginal 而非 original）。
  /// 注意：楼中楼回复的 url_struct 会原样继承父评论的图条目
  /// （pic_num=0 的回复也带着 pic_infos），故必须以评论自身
  /// pic_num>0 为准入门，不能只看 pic_infos 是否存在。
  static WbPic? _picFromJson(Map<String, dynamic> j) {
    if (_intOf(j['pic_num']) <= 0) return null;
    for (final entry in _listOf(j['url_struct'])) {
      final infos = _mapOf(_mapOf(entry)['pic_infos']);
      if (infos.isEmpty) continue;
      final pid = infos.keys.first;
      final info = _mapOf(infos[pid]);
      String u(String k) => httpsUrl(_strOf(_mapOf(info[k])['url']));
      var w = 0, h = 0;
      for (final k in [
        'large',
        'original',
        'woriginal',
        'bmiddle',
        'thumbnail',
      ]) {
        final sizeObj = _mapOf(info[k]);
        w = _intOf(sizeObj['width']);
        h = _intOf(sizeObj['height']);
        if (w > 0 && h > 0) break;
      }
      final original = u('original');
      return WbPic(
        pid: pid,
        thumbnail: u('thumbnail'),
        bmiddle: u('bmiddle'),
        large: u('large'),
        original: original.isNotEmpty ? original : u('woriginal'),
        width: w,
        height: h,
      );
    }
    return null;
  }

  /// 局部更新（删楼中楼回复时换 replies、点赞乐观更新时换
  /// liked/likeCount 用，其余字段原样带过）。
  WbComment copyWith({
    List<WbComment>? replies,
    bool? liked,
    int? likeCount,
  }) {
    return WbComment(
      id: id,
      user: user,
      text: text,
      createdAtRaw: createdAtRaw,
      source: source,
      likeCount: likeCount ?? this.likeCount,
      liked: liked ?? this.liked,
      floorNumber: floorNumber,
      replies: replies ?? this.replies,
      pic: pic,
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

/// 关注分组（allGroups 中 group_type==0 分段的条目）：
/// gid 是「list_id+本人 uid」拼接的完整串（如 100051641537045），
/// 时间线请求原样回传（主包 formatGroup / 时间线加载器实证）。
class WbFollowGroup {
  final String gid;
  final String title;

  const WbFollowGroup({required this.gid, required this.title});
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

/// 搜索分类（m container `100103type={N}`，2026-11-12 访客探针实证：
/// 全部第一页可读；专属分类访客态翻页会被 302 跳登录，只有一页量）。
enum SearchCategory {
  all(1, '综合'),
  realtime(61, '实时'),
  users(3, '用户'),
  video(64, '视频'),
  pics(63, '图片'),
  topic(38, '话题'),
  supertopic(98, '超话');

  const SearchCategory(this.type, this.label);

  /// containerid 里的 type 值。
  final int type;
  final String label;

  bool get isTopicLike => this == topic || this == supertopic;
}

/// 话题 / 超话条目（搜索 card_type=8：title_sub 标题、desc1 简介、
/// desc2 统计文案、pic 封面、scheme 指向话题/超话容器页）。
class WbTopicEntry {
  final String title;
  final String desc1;
  final String desc2;
  final String pic;
  final String scheme;

  const WbTopicEntry({
    this.title = '',
    this.desc1 = '',
    this.desc2 = '',
    this.pic = '',
    this.scheme = '',
  });

  factory WbTopicEntry.fromJson(Map<String, dynamic> j) => WbTopicEntry(
        title: _strOf(j['title_sub']),
        desc1: _strOf(j['desc1']),
        desc2: _strOf(j['desc2']),
        pic: httpsUrl(_strOf(j['pic'])),
        scheme: _strOf(j['scheme']),
      );

  /// scheme 的 containerid 为 100808… 时即超话页 id（整串就是
  /// chaohua 族接口的 page_id、也是 m 容器 id）；普通话题
  /// （231522…）或解析不到返回 null。
  String? get superPageId {
    final cid = Uri.tryParse(scheme)?.queryParameters['containerid'] ?? '';
    return cid.startsWith('100808') ? cid : null;
  }
}

/// 超话页状态（chaohua/page/extend 响应字段，主包实证）：
/// 关注态与按钮文案、今日签到态。按钮文案为空时用关注态推导。
class SuperTopicState {
  final bool isFollowed;
  final String followBtnText;
  final bool isChecked;

  const SuperTopicState({
    this.isFollowed = false,
    this.followBtnText = '',
    this.isChecked = false,
  });

  SuperTopicState copyWith({
    bool? isFollowed,
    String? followBtnText,
    bool? isChecked,
  }) =>
      SuperTopicState(
        isFollowed: isFollowed ?? this.isFollowed,
        followBtnText: followBtnText ?? this.followBtnText,
        isChecked: isChecked ?? this.isChecked,
      );
}

/// 一个分类的一页搜索结果（按分类只填对应列表）。
/// [nextPage] 是 cardlistInfo.page 给出的下一页序号，0 表示没有下一页。
class SearchCategoryPage {
  final List<WbStatus> statuses;
  final List<WbUser> users;
  final List<WbTopicEntry> topics;
  final int total;
  final int nextPage;

  const SearchCategoryPage({
    this.statuses = const [],
    this.users = const [],
    this.topics = const [],
    this.total = 0,
    this.nextPage = 0,
  });
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

// ---------------- 消息中心（登录态，/ajax/message 族） ----------------
// 依据：WEIBO_API.md「登录与写接口」节静态确认路径 + PC 网页端主包
// （raw/pc_index.js）消息页组件实证的信封/参数/条目结构。登录态真实
// 返回未经真机实测，解析全部防御式，结构对不上的条目跳过不崩。

/// 消息族列表的双游标分页结果：请求带 max_id + sinceId 两参
/// （主包消息页组件实证），响应回传 next_cursor / nextId。
typedef MessagePage<T> = ({
  List<T> items,
  String maxId,
  String sinceId,
  bool hasMore,
});

/// 消息未读汇总。分类键名来自主包未读状态表（mention_status /
/// all_mention_cmt / cmt / attitude，主包实证）；数值由
/// WeiyueService.getMessageSummary 多形态防御提取，全零即无徽标。
class MessageUnread {
  /// @我的微博未读（mention_status）
  final int mentionStatuses;

  /// @我的评论未读（all_mention_cmt）
  final int mentionComments;

  /// 收到的评论未读（cmt）
  final int commentsToMe;

  /// 收到的赞未读（attitude）
  final int likesToMe;

  /// 私信类未读（dm_total，防御字段）
  final int directMessages;

  /// 服务端给的总未读（messages 键）；0 表示未提供，total 退回本地求和
  final int serverTotal;

  const MessageUnread({
    this.mentionStatuses = 0,
    this.mentionComments = 0,
    this.commentsToMe = 0,
    this.likesToMe = 0,
    this.directMessages = 0,
    this.serverTotal = 0,
  });

  static const zero = MessageUnread();

  /// @我的页签徽标（微博 + 评论）
  int get mentions => mentionStatuses + mentionComments;

  int get categoriesSum => mentions + commentsToMe + likesToMe + directMessages;

  /// 「我的」入口总徽标：服务端总数优先，否则分类求和
  int get total => serverTotal > 0 ? serverTotal : categoriesSum;
}

/// 「全部消息」混合流条目（/ajax/message/msgList?type=all，主包实证
/// 语义是 24 小时全部消息而非私信会话）：条目 = {uuidTmp, create_time,
/// userInfo, tips, msg_type, msgInfo}，msg_type 分段（主包
/// handleAllMessage 实证）：1-2 状态类、3-6 评论类、7-9 赞类，
/// msgInfo 是内嵌的状态/评论对象。
enum MessageFeedKind { status, comment, like, other }

class MessageFeedItem {
  final String key;
  final WbUser? actor;
  final String actionText; // tips：服务端给的动作描述（如「评论了你的微博」）
  final String createdAtRaw; // create_time
  final MessageFeedKind kind;
  final String text; // 主体文本（状态/评论正文）
  final WbStatus? status; // 关联微博（点击跳详情）
  final String commentText; // 赞类且赞的是评论时，被赞评论的文本

  const MessageFeedItem({
    required this.key,
    this.actor,
    this.actionText = '',
    this.createdAtRaw = '',
    this.kind = MessageFeedKind.other,
    this.text = '',
    this.status,
    this.commentText = '',
  });

  /// 是否有可展示/可跳转的内容（全空条目由服务层过滤掉）。
  bool get hasContent => actor != null || text.isNotEmpty || status != null;

  factory MessageFeedItem.fromJson(Map<String, dynamic> j) {
    final info = _mapOf(j['msgInfo']);
    final userMap = _mapOf(j['userInfo']);
    final type = _intOf(j['msg_type']);
    final kind = (type == 1 || type == 2)
        ? MessageFeedKind.status
        : (type >= 3 && type <= 6)
        ? MessageFeedKind.comment
        : (type >= 7 && type <= 9)
        ? MessageFeedKind.like
        : MessageFeedKind.other;
    WbStatus? status;
    var text = '';
    var commentText = '';
    if (info.isNotEmpty) {
      switch (kind) {
        case MessageFeedKind.status:
          final s = WbStatus.fromJson(info);
          if (s.id.isNotEmpty) status = s;
          text = s.text;
        case MessageFeedKind.comment:
          text = WbComment.fromJson(info).text;
          final sm = _mapOf(info['status']);
          if (sm.isNotEmpty) {
            final s = WbStatus.fromJson(sm);
            if (s.id.isNotEmpty) status = s;
          }
        case MessageFeedKind.like:
          final inner = _mapOf(info['status']);
          if (inner.isNotEmpty) {
            // msgInfo 是被赞的评论：其 text 是评论文本，status 是所属微博
            commentText = stripHtml(_strOf(info['text']));
            final s = WbStatus.fromJson(inner);
            if (s.id.isNotEmpty) status = s;
          } else {
            // msgInfo 本身就是被赞的微博
            final s = WbStatus.fromJson(info);
            if (s.id.isNotEmpty) {
              status = s;
              text = s.text;
            }
          }
        case MessageFeedKind.other:
          text = stripHtml(_strOf(info['text']));
          final sm = _mapOf(info['status']);
          if (sm.isNotEmpty) {
            final s = WbStatus.fromJson(sm);
            if (s.id.isNotEmpty) status = s;
          }
      }
    }
    return MessageFeedItem(
      key: _strOf(j['uuidTmp'] ?? j['id']),
      actor: userMap.isEmpty ? null : WbUser.fromJson(userMap),
      actionText: _strOf(j['tips']),
      createdAtRaw: _strOf(j['create_time'] ?? j['created_at']),
      kind: kind,
      text: text,
      status: status,
      commentText: commentText,
    );
  }
}

/// 消息评论条目（message/cmt、message/myCmt、comments/mentions 共用）：
/// 评论本体复用 WbComment，另带它针对的微博与被回复的评论。
class MessageComment {
  final WbComment comment;
  final WbStatus? status;
  final WbComment? replyTo;

  const MessageComment({required this.comment, this.status, this.replyTo});

  factory MessageComment.fromJson(Map<String, dynamic> j) {
    final statusMap = _mapOf(j['status']);
    // 主包两种拼写都出现过：reply_comment（节点消息）/ replay_comment
    // （混合流 msgInfo），两个都认。
    final replyMap = _mapOf(j['reply_comment'] ?? j['replay_comment']);
    return MessageComment(
      comment: WbComment.fromJson(j),
      status: statusMap.isEmpty ? null : WbStatus.fromJson(statusMap),
      replyTo: replyMap.isEmpty ? null : WbComment.fromJson(replyMap),
    );
  }
}

/// 收到的赞条目（/ajax/message/attitudes，主包实证形态）：
/// 条目带点赞者 user；赞微博时带 status，赞评论时带 comment，
/// comment 内再带它所属的 status。
class MessageLike {
  final String id;
  final WbUser? user;
  final String createdAtRaw;
  final WbStatus? status;
  final String commentText; // 非空 = 赞的是这条评论

  const MessageLike({
    required this.id,
    this.user,
    this.createdAtRaw = '',
    this.status,
    this.commentText = '',
  });

  factory MessageLike.fromJson(Map<String, dynamic> j) {
    final userMap = _mapOf(j['user']);
    final commentMap = _mapOf(j['comment']);
    var statusMap = _mapOf(j['status']);
    var commentText = '';
    if (commentMap.isNotEmpty) {
      commentText = stripHtml(_strOf(commentMap['text']));
      if (statusMap.isEmpty) statusMap = _mapOf(commentMap['status']);
    }
    return MessageLike(
      id: _strOf(j['idstr'] ?? j['id']),
      user: userMap.isEmpty ? null : WbUser.fromJson(userMap),
      createdAtRaw: _strOf(j['created_at']),
      status: statusMap.isEmpty ? null : WbStatus.fromJson(statusMap),
      commentText: commentText,
    );
  }
}

// ---------------- 私信（网页版聊天 / WebIM 子系统，api.weibo.com/webim） ----------------
// 依据：WEIBO_API.md「私信」小节（2026-11-12）——网页版聊天应用
// bundle（rea-probe raw/chat_app.js）调用点逐字实证的路径/参数/字段
// + 访客态探针（端点回 21301 鉴权错误，证明存在且登录必需）。
// 登录态真实返回未经真机实测，解析全部防御式：未知字段忽略、
// 结构对不上的条目跳过不崩。结构样本见 rea-probe
// samples/pc_chat_structure.json（bundle 字段整理，假数据）。

/// WebIM 时间字段宽容解析：可能是日期串（"Thu Nov 12 09:30:00
/// +0800 2026"，parseWbTime 同形态）、ISO 串、秒/毫秒 epoch
/// （数字或数字串）。都解不出返回 null，UI 退回不显示时间。
DateTime? parseDmTime(dynamic v) {
  if (v is num) return _epochToTime(v.toInt());
  final s = _strOf(v).trim();
  if (s.isEmpty) return null;
  final n = int.tryParse(s);
  if (n != null) return _epochToTime(n);
  return parseWbTime(s) ?? DateTime.tryParse(s);
}

DateTime? _epochToTime(int n) {
  if (n <= 0) return null;
  // 1e12 量级是毫秒、1e9 量级是秒
  final ms = n >= 100000000000 ? n : n * 1000;
  try {
    return DateTime.fromMillisecondsSinceEpoch(ms);
  } catch (_) {
    return null;
  }
}

/// type==499 的消息正文不在 text 而在 msg 字段的 JSON 里
/// （bundle 会话摘要处理原文：JSON.parse(msg).content1）。
/// 解不出就返回空串，调用方按占位文案处理。
String _dmTextOf(Map<String, dynamic> j) {
  var text = _strOf(j['text']);
  if (text.isEmpty && j['msg'] != null) {
    try {
      final decoded = jsonDecode(_strOf(j['msg']));
      if (decoded is Map) text = _strOf(decoded['content1']);
    } catch (_) {}
  }
  return text;
}

/// 私信会话（contacts / public/contacts 的一条）：对方用户 +
/// 最后一条消息摘要 + 未读数。isPublic=true 表示来自未关注人
/// （public 族）列表，打开时走 public/conversation。
class DmConversation {
  final WbUser user;

  /// contacts 里 user 对象自带的 type（bundle 实证：3 是「未关注人
  /// 消息」虚拟文件夹条目，服务层据此过滤，不进 1:1 会话列表）。
  final int userType;
  final String lastText;
  final int lastMid;
  final DateTime? lastTime;
  final int unreadCount;
  final bool isPublic;

  const DmConversation({
    required this.user,
    this.userType = 1,
    this.lastText = '',
    this.lastMid = 0,
    this.lastTime,
    this.unreadCount = 0,
    this.isPublic = false,
  });

  String get uid => '${user.id}';

  factory DmConversation.fromJson(
    Map<String, dynamic> j, {
    required bool isPublic,
  }) {
    final userMap = _mapOf(j['user']);
    final msg = _mapOf(j['message']);
    return DmConversation(
      user: WbUser.fromJson(userMap),
      userType: _intOf(userMap['type'] ?? 1),
      lastText: _dmTextOf(msg),
      lastMid: _intOf(msg['id']),
      lastTime: parseDmTime(msg['created_at'] ?? msg['time']),
      unreadCount: _intOf(j['unread_count']),
      isPublic: isPublic,
    );
  }
}

/// 本地发送状态（服务端消息恒为 normal；UI 乐观发送时用）。
enum DmSendState { normal, sending, failed }

/// 一条私信（conversation 的 direct_messages 一条）。
/// 服务端数组首元为最新，服务层翻转为时间升序后交给 UI。
class DmMessage {
  final int id; // 服务端 mid；本地待发/失败条为负数临时 id
  final int senderId;
  final String senderName;
  final int recipientId;
  final String text;
  final DateTime? createdAt;
  final int type; // bundle 条目 type（321 = 系统提示条目）
  final int mediaType; // 0 文本 / 1 图 / 5 文件 / 10 视频（bundle 实证）
  final DmSendState sendState;

  const DmMessage({
    required this.id,
    required this.senderId,
    this.senderName = '',
    this.recipientId = 0,
    required this.text,
    this.createdAt,
    this.type = 1,
    this.mediaType = 0,
    this.sendState = DmSendState.normal,
  });

  bool get isSystem => type == 321;

  bool isMineFrom(int myUid) => myUid > 0 && senderId == myUid;

  /// 展示文本：正文为空的非文本消息给占位（图片/文件/视频附件
  /// 本批不渲染原件，只占位，与 bundle 的 media_type 语义对齐）。
  String get displayText {
    if (text.isNotEmpty) return text;
    return switch (mediaType) {
      1 => '[图片]',
      5 => '[文件]',
      10 => '[视频]',
      _ => '[消息]',
    };
  }

  DmMessage copyWith({DmSendState? sendState, int? id, DateTime? createdAt}) {
    return DmMessage(
      id: id ?? this.id,
      senderId: senderId,
      senderName: senderName,
      recipientId: recipientId,
      text: text,
      createdAt: createdAt ?? this.createdAt,
      type: type,
      mediaType: mediaType,
      sendState: sendState ?? this.sendState,
    );
  }

  factory DmMessage.fromJson(Map<String, dynamic> j) {
    return DmMessage(
      id: _intOf(j['id'] ?? j['mid'] ?? j['dmid']),
      senderId: _intOf(j['sender_id'] ?? j['from_uid']),
      senderName: _strOf(j['sender_screen_name']),
      recipientId: _intOf(j['recipient_id']),
      text: _dmTextOf(j),
      createdAt: parseDmTime(j['created_at'] ?? j['time']),
      type: _intOf(j['type'] ?? 1),
      mediaType: _intOf(j['media_type']),
    );
  }
}
