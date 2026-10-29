import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/emoticons.dart';
import '../models/models.dart';
import 'session_service.dart';
import 'visitor_service.dart';

class WeiyueException implements Exception {
  final String message;
  const WeiyueException(this.message);
  @override
  String toString() => message;
}

Map<String, dynamic> _asMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry('$k', val));
  return const {};
}

List<dynamic> _asList(dynamic v) => v is List ? v : const [];

int _intOf(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.replaceAll(',', '')) ?? 0;
  return 0;
}

/// 微博双栈只读接口（依据 WEIBO_API.md 实测结论）。
/// PC 栈管热门/详情/资料/视频，m 栈管搜索/用户时间线/评论/点赞，两栈混用。
/// 身份优先级：有登录会话 Cookie 用登录态，否则走访客流程；
/// 登录态被服务端明确拒绝时标记过期并回退访客态完成当前请求。
class WeiyueService {
  final VisitorService visitor;

  /// 登录会话（WebView 收割的 Cookie）；未注入时为空会话（恒走访客态）。
  final SessionService session;

  late final Dio _pc;
  late final Dio _m;

  /// [pcDio]/[mDio] 可注入（测试用假 adapter）。
  WeiyueService(this.visitor, {Dio? pcDio, Dio? mDio, SessionService? session})
    : session = session ?? SessionService() {
    _pc = pcDio ?? _makeDio();
    _m = mDio ?? _makeDio();
  }

  static Dio _makeDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: false,
      // 302/403 要自己判断（访客失效信号），不让 dio 抛错
      validateStatus: (s) => s != null && s < 500,
    ),
  );

  static const _pcBase = 'https://weibo.com';
  static const _mBase = 'https://m.weibo.cn';

  /// 服务端「未登录」信号：ok:-100、403、跳登录/passport 的 30x、
  /// 或 HTTP 200 回登录页 HTML。访客失效与登录过期共用这套判定，
  /// 由调用方按当前身份决定刷新访客还是标记过期回退。
  static bool _notLoggedInSignal(
    int status,
    Map<String, dynamic>? json,
    String location,
    String rawBody,
  ) {
    if (json != null && json['ok'] == -100) return true;
    if (status == 403) return true;
    if (status == 301 || status == 302) {
      if (location.isEmpty) return true;
      final loc = location.toLowerCase();
      return loc.contains('passport') ||
          loc.contains('login') ||
          loc.contains('visitor') ||
          loc.contains('sso');
    }
    if (json == null && rawBody.contains('sso/signin')) return true;
    return false;
  }

  /// 决定本次请求用哪份 Cookie：登录会话优先；[sessionOnly] 时
  /// 只许登录态（探活用，不回退访客，避免把访客结果误判成登录解锁）。
  /// [retried] 表示已是回退重试，强制走访客，防止循环。
  Future<({String cookie, bool useSession})> _cookieFor(
    WbStack stack, {
    bool sessionOnly = false,
    bool retried = false,
  }) async {
    if (session.hasUsableCookie(stack) && (sessionOnly || !retried)) {
      return (cookie: session.cookieHeaderFor(stack)!, useSession: true);
    }
    if (sessionOnly) throw const WeiyueException('无登录会话');
    final identity = await visitor.ensure(stack);
    return (cookie: identity.cookie, useSession: false);
  }

  /// 组装请求头。PC 栈用登录 Cookie 时必须带 `X-Xsrf-Token` 头
  /// （值 = 会话里的 XSRF-TOKEN Cookie，网页端每个 ajax 请求都带）：
  /// 缺失时多个接口直接回 HTTP 400 非 JSON（真机实证：关注列表等）。
  /// 访客请求永不带、m 栈不带，保持既有行为不变。
  Map<String, String> _requestHeaders(
    WbStack stack, {
    required String cookie,
    required bool useSession,
    String? referer,
  }) {
    final headers = <String, String>{
      'User-Agent': visitor.uaOf(stack),
      'Referer':
          referer ??
          (stack == WbStack.pc ? 'https://weibo.com/' : 'https://m.weibo.cn/'),
      'X-Requested-With': 'XMLHttpRequest',
      'Cookie': cookie,
    };
    if (stack == WbStack.pc && useSession) {
      final xsrf = session.xsrfToken();
      if (xsrf != null && xsrf.isNotEmpty) {
        headers['X-Xsrf-Token'] = xsrf;
      }
    }
    return headers;
  }

  /// 通用 GET：身份处理见类注释；失效时只重试一次。
  /// [sessionOnly]=true 时不回退访客（登录探活专用）。
  Future<Map<String, dynamic>> _get(
    WbStack stack,
    String url, {
    Map<String, dynamic>? query,
    String? referer,
    bool retried = false,
    bool sessionOnly = false,
  }) async {
    final picked = await _cookieFor(
      stack,
      sessionOnly: sessionOnly,
      retried: retried,
    );
    final dio = stack == WbStack.pc ? _pc : _m;
    final Response<dynamic> resp;
    try {
      resp = await dio.get<dynamic>(
        url,
        queryParameters: query,
        options: Options(
          headers: _requestHeaders(
            stack,
            cookie: picked.cookie,
            useSession: picked.useSession,
            referer: referer,
          ),
        ),
      );
    } on DioException catch (e) {
      throw WeiyueException('网络错误：${e.message ?? e.type.name}');
    }
    final status = resp.statusCode ?? 0;
    final data = resp.data;
    Map<String, dynamic>? json;
    if (data is Map) {
      json = _asMap(data);
    }
    final location = resp.headers.value('location') ?? '';
    final rawBody = data is String ? data : '';
    final notLoggedIn = _notLoggedInSignal(status, json, location, rawBody);
    if (notLoggedIn) {
      if (sessionOnly) {
        throw const WeiyueException('登录态未生效（服务端未认）');
      }
      if (picked.useSession) {
        // 登录 Cookie 被拒：标记过期，回退访客态把当前请求做完
        session.markExpired();
        return _get(stack, url, query: query, referer: referer, retried: true);
      }
      if (!retried) {
        await visitor.refresh(stack);
        return _get(stack, url, query: query, referer: referer, retried: true);
      }
      throw const WeiyueException('访客身份失效，重试后仍被拦截');
    }
    if (json == null) {
      throw WeiyueException('接口返回非 JSON（HTTP $status）');
    }
    return json;
  }

  /// 纯文本 GET（同 _get 的身份处理）：给返回 JSONP 的接口用
  /// （m container/getItem 的响应被括号包裹，dio 的 JSON 解码接不住）。
  /// [sessionOnly]=true 时只许登录态（探活提取 uid 用，不回退访客）；
  /// [onResponse] 在拿到响应后回调一次（读 Set-Cookie 等响应头用）。
  Future<String> _getRaw(
    WbStack stack,
    String url, {
    Map<String, dynamic>? query,
    String? referer,
    bool retried = false,
    bool sessionOnly = false,
    void Function(Response<dynamic> resp)? onResponse,
  }) async {
    final picked = await _cookieFor(
      stack,
      retried: retried,
      sessionOnly: sessionOnly,
    );
    final dio = stack == WbStack.pc ? _pc : _m;
    final Response<dynamic> resp;
    try {
      resp = await dio.get<dynamic>(
        url,
        queryParameters: query,
        options: Options(
          responseType: ResponseType.plain,
          headers: _requestHeaders(
            stack,
            cookie: picked.cookie,
            useSession: picked.useSession,
            referer: referer,
          ),
        ),
      );
    } on DioException catch (e) {
      throw WeiyueException('网络错误：${e.message ?? e.type.name}');
    }
    onResponse?.call(resp);
    final status = resp.statusCode ?? 0;
    final body = resp.data?.toString() ?? '';
    final location = resp.headers.value('location') ?? '';
    final notLoggedIn = _notLoggedInSignal(status, null, location, body);
    if (notLoggedIn) {
      if (sessionOnly) {
        throw const WeiyueException('登录态未生效（服务端未认）');
      }
      if (picked.useSession) {
        session.markExpired();
        return _getRaw(
          stack,
          url,
          query: query,
          referer: referer,
          retried: true,
        );
      }
      if (!retried) {
        await visitor.refresh(stack);
        return _getRaw(
          stack,
          url,
          query: query,
          referer: referer,
          retried: true,
        );
      }
      throw const WeiyueException('访客身份失效，重试后仍被拦截');
    }
    return body;
  }

  /// 剥掉 JSONP 外层括号再解码（getItem 实测返回 `({...})`）。
  static Map<String, dynamic> _decodeJsonp(String body) {
    var t = body.trim();
    if (t.startsWith('(') && t.endsWith(')')) {
      t = t.substring(1, t.length - 1);
    }
    final d = jsonDecode(t);
    return d is Map ? _asMap(d) : const {};
  }

  // ---------------- 分类 ----------------

  /// 内置「我的频道」17 个（allGroups 失败时回退；码表见 WEIBO_API.md）
  static const List<WbChannel> fallbackChannels = [
    WbChannel(gid: '102803', title: '热门', containerid: '102803'),
    WbChannel(gid: '1028032222', title: '同城', containerid: '102803_2222'),
    WbChannel(
      gid: '102803600343',
      title: '实时',
      containerid: '102803_ctg1_600343_-_ctg1_600343',
    ),
    WbChannel(
      gid: '102803600583',
      title: 'S16',
      containerid: '102803_ctg1_600583_-_ctg1_600583',
    ),
    WbChannel(
      gid: '102803600169',
      title: '榜单',
      containerid: '102803_ctg1_600169_-_ctg1_600169',
    ),
    WbChannel(
      gid: '1028034288',
      title: '明星',
      containerid: '102803_ctg1_4288_-_ctg1_4288',
    ),
    WbChannel(
      gid: '1028034388',
      title: '搞笑',
      containerid: '102803_ctg1_4388_-_ctg1_4388',
    ),
    WbChannel(
      gid: '1028031988',
      title: '情感',
      containerid: '102803_ctg1_1988_-_ctg1_1988',
    ),
    WbChannel(
      gid: '102803600410',
      title: '短剧',
      containerid: '102803_ctg1_600410_-_ctg1_600410',
    ),
    WbChannel(
      gid: '102803600311',
      title: '印像',
      containerid: '102803_ctg1_600311_-_ctg1_600311',
    ),
    WbChannel(
      gid: '102803600195',
      title: '周末',
      containerid: '102803_ctg1_600195_-_ctg1_600195',
    ),
    WbChannel(
      gid: '1028033288',
      title: '电影',
      containerid: '102803_ctg1_3288_-_ctg1_3288',
    ),
    WbChannel(
      gid: '1028034188',
      title: '社会',
      containerid: '102803_ctg1_4188_-_ctg1_4188',
    ),
    WbChannel(
      gid: '1028032488',
      title: '电视剧',
      containerid: '102803_ctg1_2488_-_ctg1_2488',
    ),
    WbChannel(
      gid: '1028032688',
      title: '美食',
      containerid: '102803_ctg1_2688_-_ctg1_2688',
    ),
    WbChannel(
      gid: '1028036288',
      title: '国际',
      containerid: '102803_ctg1_6288_-_ctg1_6288',
    ),
    WbChannel(
      gid: '102803600155',
      title: '深度',
      containerid: '102803_ctg1_600155_-_ctg1_600155',
    ),
  ];

  ({List<WbChannel> mine, List<WbChannel> recommended})? _channelsCache;

  Future<({List<WbChannel> mine, List<WbChannel> recommended})>
  getChannels() async {
    final cached = _channelsCache;
    if (cached != null) return cached;
    try {
      final json = await _get(
        WbStack.pc,
        '$_pcBase/ajax/feed/allGroups',
        query: {'is_new_segment': 1, 'fetch_hot': 1},
      );
      List<WbChannel> pick(String title) {
        for (final g in _asList(json['groups'])) {
          final gm = _asMap(g);
          if (gm['title'] == title) {
            return _asList(gm['group'])
                .map((e) => WbChannel.fromJson(_asMap(e)))
                .where((c) => c.gid.isNotEmpty)
                .toList();
          }
        }
        return const [];
      }

      final mine = pick('我的频道');
      final recommended = pick('频道推荐');
      if (mine.isNotEmpty) {
        return _channelsCache = (mine: mine, recommended: recommended);
      }
    } catch (_) {
      // 落回内置常量
    }
    return _channelsCache = (
      mine: fallbackChannels,
      recommended: const <WbChannel>[],
    );
  }

  /// 按名找分类（视频页签用）：先查缓存/接口结果，再查内置表。
  Future<WbChannel?> channelByTitle(String title) async {
    final all = await getChannels();
    for (final c in [...all.mine, ...all.recommended]) {
      if (c.title == title) return c;
    }
    for (final c in fallbackChannels) {
      if (c.title == title) return c;
    }
    return null;
  }

  // ---------------- 热门流 ----------------

  Future<HotPage> getHotTimeline(
    WbChannel channel, {
    int maxId = 0,
    int freshIdx = 1,
  }) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/feed/hottimeline',
      query: {
        'fresh_idx': freshIdx,
        'group_id': channel.gid,
        'containerid': channel.containerid,
        'max_id': maxId,
        'count': 10,
        'extparam': 'discover|new_feed',
      },
      referer: 'https://weibo.com/hot/',
    );
    final statuses = _asList(json['statuses'])
        .map((e) => WbStatus.fromJson(_asMap(e)))
        .where((s) => s.id.isNotEmpty)
        .toList();
    final maxIdRaw = json['max_id'];
    return HotPage(
      statuses: statuses,
      maxId: maxIdRaw is num
          ? maxIdRaw.toInt()
          : int.tryParse('$maxIdRaw') ?? 0,
      freshIdx: freshIdx,
    );
  }

  // ---------------- 热搜 / band ----------------

  Future<({HotWord? gov, List<HotWord> words})> getHotSearch() async {
    final json = await _get(WbStack.pc, '$_pcBase/ajax/side/hotSearch');
    final data = _asMap(json['data']);
    final govMap = _asMap(data['hotgov']);
    final words = _asList(data['realtime'])
        .map((e) => HotWord.fromJson(_asMap(e)))
        .where((w) => w.word.isNotEmpty)
        .toList();
    return (
      gov: govMap.isEmpty ? null : HotWord.fromJson(govMap),
      words: words,
    );
  }

  /// band 分类词榜：segment ∈ entertainment/life/social/technology/sport/acg
  Future<List<BandItem>> getBand(String segment) async {
    final json = await _get(WbStack.pc, '$_pcBase/ajax/statuses/$segment');
    final data = _asMap(json['data']);
    return _asList(data['band_list'])
        .map((e) => BandItem.fromJson(_asMap(e)))
        .where((b) => b.word.isNotEmpty)
        .toList();
  }

  // ---------------- 详情 / 评论 / 点赞 ----------------

  Future<WbStatus> getStatus(String id) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/statuses/show',
      query: {'id': id},
      referer: 'https://weibo.com/detail/$id',
    );
    return WbStatus.fromJson(json);
  }

  /// 长文全文（纯文本）；失败返回空串
  Future<String> getLongText(String id) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/statuses/longtext',
      query: {'id': id},
    );
    final data = _asMap(json['data']);
    final content = data['longTextContent']?.toString() ?? '';
    return cleanWbText(content);
  }

  Future<({List<WbComment> comments, int total, int maxId})> getComments(
    String id, {
    required String authorUid,
    int maxId = 0,
  }) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/statuses/buildComments',
      query: {
        'is_reload': 1,
        'id': id,
        'is_show_bulletin': 2,
        'is_mix': 0,
        'count': 20,
        'uid': authorUid,
        'fetch_level': 0,
        'locale': 'zh-CN',
        if (maxId > 0) 'max_id': maxId,
      },
      referer: 'https://weibo.com/detail/$id',
    );
    final comments = _asList(json['data'])
        .map((e) => WbComment.fromJson(_asMap(e)))
        .where((c) => c.id.isNotEmpty)
        .toList();
    final totalRaw = json['total_number'];
    final maxRaw = json['max_id'];
    return (
      comments: comments,
      total: totalRaw is num ? totalRaw.toInt() : 0,
      maxId: maxRaw is num ? maxRaw.toInt() : 0,
    );
  }

  Future<({List<WbAttitude> items, int total})> getAttitudes(
    String id, {
    int page = 1,
  }) async {
    final json = await _get(
      WbStack.m,
      '$_mBase/api/attitudes/show',
      query: {'id': id, 'page': page},
      referer: 'https://m.weibo.cn/detail/$id',
    );
    final data = _asMap(json['data']);
    final items = _asList(
      data['data'],
    ).map((e) => WbAttitude.fromJson(_asMap(e))).toList();
    final totalRaw = data['total_number'];
    return (
      items: items,
      total: totalRaw is num ? totalRaw.toInt() : items.length,
    );
  }

  Future<List<WbStatus>> getRelatedVideos(String mid, {int page = 1}) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/multimedia/relatedVideoList',
      query: {'scene': 'feed', 'mid': mid, 'page': page},
      referer: 'https://weibo.com/detail/$mid',
    );
    final data = _asMap(json['data']);
    return _asList(data['list'])
        .map((e) => WbStatus.fromJson(_asMap(e)))
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  // ---------------- 用户 ----------------

  Future<WbUser> getProfileInfo(String uid) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/profile/info',
      query: {'uid': uid},
      referer: 'https://weibo.com/u/$uid',
    );
    final data = _asMap(json['data']);
    return WbUser.fromJson(_asMap(data['user']));
  }

  /// profile/detail 原始 data（生日/注册时间/阳光信用/标签等），页面自行取行
  Future<Map<String, dynamic>> getProfileDetail(String uid) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/profile/detail',
      query: {'uid': uid},
      referer: 'https://weibo.com/u/$uid',
    );
    return _asMap(json['data']);
  }

  /// 本人完整资料（登录后补全用）：profile/info 的 user 对象为主，
  /// 再合并 profile/detail 的扩展字段（gender 性别、birthday 生日——
  /// 文档 detail 结构明确，两者 info 里不一定有）。detail 拉取失败
  /// 不影响主资料返回。
  /// uid 为空直接抛错：空参请求必被服务端回 400 非 JSON（真机实证），
  /// 还会污染诊断失败记录，不如本地拦下并给出可操作提示。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
  Future<WbUser> getMyProfile(String uid) async {
    if (uid.trim().isEmpty) {
      throw const WeiyueException('缺少用户 ID，请先点「修复登录态」或重新检测');
    }
    try {
      var user = await getProfileInfo(uid);
      try {
        final detail = await getProfileDetail(uid);
        final gender = '${detail['gender'] ?? ''}';
        final birthday = '${detail['birthday'] ?? ''}';
        user = user.copyWith(
          gender: gender.isNotEmpty ? gender : user.gender,
          birthday: birthday.isNotEmpty ? birthday : user.birthday,
        );
      } catch (_) {
        // detail 失败只少两个扩展字段，主资料照常
      }
      return user;
    } catch (e) {
      session.recordLoginFailure('/ajax/profile/info', '$e');
      rethrow;
    }
  }

  /// m 容器泛型请求，返回 data
  Future<Map<String, dynamic>> _container(
    Map<String, dynamic> query, {
    String? referer,
  }) async {
    final json = await _get(
      WbStack.m,
      '$_mBase/api/container/getIndex',
      query: query,
      referer: referer,
    );
    return _asMap(json['data']);
  }

  ContainerPage _parseContainer(Map<String, dynamic> data) {
    final info = _asMap(data['cardlistInfo']);
    final statuses = <WbStatus>[];
    final seen = <String>{};
    // 话题/文章等容器把 mblog 放在 card_type 11 的 card_group 里，递归收集
    void walk(Map<String, dynamic> card) {
      final mblog = _asMap(card['mblog']);
      if (mblog.isNotEmpty) {
        final s = WbStatus.fromJson(mblog);
        if (s.id.isNotEmpty && seen.add(s.id)) statuses.add(s);
      }
      for (final g in _asList(card['card_group'])) {
        walk(_asMap(g));
      }
    }

    for (final card in _asList(data['cards'])) {
      walk(_asMap(card));
    }
    final totalRaw = info['total'];
    final pageRaw = info['page'];
    return ContainerPage(
      statuses: statuses,
      total: totalRaw is num ? totalRaw.toInt() : statuses.length,
      nextPage: pageRaw is num ? pageRaw.toInt() : 0,
    );
  }

  Future<ContainerPage> getUserStatuses(String uid, {int page = 1}) async {
    final data = await _container({
      'type': 'uid',
      'value': uid,
      'containerid': '107603$uid',
      'page': page,
    }, referer: 'https://m.weibo.cn/u/$uid');
    return _parseContainer(data);
  }

  Future<ContainerPage> getUserVideos(String uid, {int page = 1}) async {
    final data = await _container({
      'type': 'uid',
      'value': uid,
      'containerid': '231567$uid',
      'page': page,
    }, referer: 'https://m.weibo.cn/u/$uid');
    return _parseContainer(data);
  }

  /// 相册：getImageWall 只给 mid 列表，逐条 show 取图（取前 limit 条）。
  Future<List<WbStatus>> getAlbumStatuses(String uid, {int limit = 9}) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/profile/getImageWall',
      query: {'uid': uid},
      referer: 'https://weibo.com/u/$uid',
    );
    final data = _asMap(json['data']);
    final mids = <String>[];
    for (final item in _asList(data['list'])) {
      final im = _asMap(item);
      final mid = im['mid']?.toString() ?? '';
      if (mid.isNotEmpty && im['type'] == 'pic') mids.add(mid);
      if (mids.length >= limit) break;
    }
    final result = <WbStatus>[];
    for (final mid in mids) {
      try {
        final s = await getStatus(mid);
        if (s.pics.isNotEmpty) result.add(s);
      } catch (_) {
        // 单条失败跳过
      }
    }
    return result;
  }

  Future<List<WbPlaylist>> getVideoTab(String uid) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/profile/getVideoTab',
      query: {'uid': uid},
      referer: 'https://weibo.com/u/$uid',
    );
    final data = _asMap(json['data']);
    return _asList(data['playlists'])
        .map((e) => WbPlaylist.fromJson(_asMap(e)))
        .where((p) => p.name.isNotEmpty)
        .toList();
  }

  /// 用户长视频（cursor 游标，首拉 0，next_cursor=-1 结束）
  Future<({List<WbStatus> statuses, int nextCursor})> getProfileVideoList(
    String uid, {
    int cursor = 0,
  }) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/profile/getprofilevideolist',
      query: {'uid': uid, 'cursor': cursor},
      referer: 'https://weibo.com/u/$uid',
    );
    final data = _asMap(json['data']);
    final statuses = <WbStatus>[];
    for (final item in _asList(data['list'])) {
      final vo = _asMap(_asMap(item)['video_detail_vo']);
      if (vo.isNotEmpty) {
        final s = WbStatus.fromJson(vo);
        if (s.id.isNotEmpty) statuses.add(s);
      }
    }
    final curRaw = data['next_cursor'];
    return (
      statuses: statuses,
      nextCursor: curRaw is num ? curRaw.toInt() : -1,
    );
  }

  /// 用户小视频（竖屏短视频）
  Future<({List<WbStatus> statuses, int nextCursor})> getTinyVideos(
    String uid, {
    int cursor = 0,
  }) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/profile/gettinyvideo',
      query: {'uid': uid, 'cursor': cursor, 'count': 20},
      referer: 'https://weibo.com/u/$uid',
    );
    final data = _asMap(json['data']);
    final statuses = _asList(data['list'])
        .map((e) => WbStatus.fromJson(_asMap(e)))
        .where((s) => s.id.isNotEmpty)
        .toList();
    final curRaw = data['next_cursor'];
    return (
      statuses: statuses,
      nextCursor: curRaw is num ? curRaw.toInt() : -1,
    );
  }

  // ---------------- 搜索（m container） ----------------

  /// 综合搜索一页。实测 cards 结构（raw/m_search.json）：
  /// - card_type=9 顶层卡：mblog 微博
  /// - card_type=11 分组卡：card_group 内 card_type=10 带 user 对象=用户卡，
  ///   card_type=9 带 mblog=微博卡，card_type=6 是「更多热门微博」链接卡（忽略）
  Future<SearchResult> search(String keyword, {int page = 1}) async {
    final data = await _container({
      'containerid': '100103type=1&q=${Uri.encodeComponent(keyword)}&t=0',
      'page_type': 'searchall',
      'page': page,
    }, referer: 'https://m.weibo.cn/search');
    final users = <WbUser>[];
    final statuses = <WbStatus>[];
    final seenUsers = <int>{};
    final seenStatuses = <String>{};
    void addUser(Map<String, dynamic> um) {
      final u = WbUser.fromJson(um);
      if (u.id > 0 && seenUsers.add(u.id)) users.add(u);
    }

    void addStatus(Map<String, dynamic> mm) {
      final s = WbStatus.fromJson(mm);
      if (s.id.isNotEmpty && seenStatuses.add(s.id)) statuses.add(s);
    }

    void walk(Map<String, dynamic> card) {
      final mblog = _asMap(card['mblog']);
      if (mblog.isNotEmpty) addStatus(mblog);
      final user = _asMap(card['user']);
      if (user.isNotEmpty) addUser(user);
      for (final g in _asList(card['card_group'])) {
        walk(_asMap(g));
      }
    }

    for (final card in _asList(data['cards'])) {
      walk(_asMap(card));
    }
    return SearchResult(users: users, statuses: statuses);
  }

  // ---------------- 搜索建议 ----------------

  /// PC /ajax/side/search：hotquery 联想词 + users 推荐用户（访客实测可读）。
  Future<SearchSuggest> getSearchSuggest(String q) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/side/search',
      query: {'q': q, 'page': 1},
    );
    final data = _asMap(json['data']);
    final queries = <String>[];
    for (final e in _asList(data['hotquery'])) {
      final s = '${_asMap(e)['suggestion'] ?? ''}'.trim();
      if (s.isNotEmpty && s != 'null' && !queries.contains(s)) queries.add(s);
    }
    final users = <WbUser>[];
    for (final e in _asList(data['users'])) {
      final u = WbUser.fromJson(_asMap(e));
      if (u.id > 0) users.add(u);
      if (users.length >= 5) break;
    }
    return SearchSuggest(queries: queries, users: users);
  }

  // ---------------- 话题页 ----------------

  /// m 话题容器 231522type=1&q=#话题#（访客实测可读，cardlistInfo.page 翻页，
  /// 与用户时间线同一套容器翻页规则）。
  Future<ContainerPage> getTopicStatuses(String topic, {int page = 1}) async {
    final data = await _container({
      'containerid': '231522type=1&q=${Uri.encodeComponent('#$topic#')}',
      'page': page,
    }, referer: 'https://m.weibo.cn/search');
    return _parseContainer(data);
  }

  // ---------------- 主页精选 / 文章 ----------------

  final Map<String, String> _featuredItemIds = {};

  /// 精选容器 230283{uid} 根只回异步卡，须再用其 itemid 调 getItem
  /// （响应为 JSONP 括号包裹）。访客实测两步均可读。
  Future<ContainerPage> getUserFeatured(String uid, {int page = 1}) async {
    var itemid = _featuredItemIds[uid];
    if (itemid == null) {
      final data = await _container({
        'type': 'uid',
        'value': uid,
        'containerid': '230283$uid',
        'page': 1,
      }, referer: 'https://m.weibo.cn/u/$uid');
      for (final c in _asList(data['cards'])) {
        final cm = _asMap(c);
        final iid = '${cm['itemid'] ?? ''}';
        if (iid.isNotEmpty && iid != 'null' && cm['async_api'] != null) {
          itemid = iid;
          break;
        }
      }
      if (itemid == null) return const ContainerPage();
      _featuredItemIds[uid] = itemid;
    }
    final body = await _getRaw(
      WbStack.m,
      '$_mBase/api/container/getItem',
      query: {'itemid': itemid, 'page': page},
      referer: 'https://m.weibo.cn/u/$uid',
    );
    final data = _asMap(_decodeJsonp(body)['data']);
    final statuses = <WbStatus>[];
    final seen = <String>{};
    void walk(Map<String, dynamic> card) {
      final mblog = _asMap(card['mblog']);
      if (mblog.isNotEmpty) {
        final s = WbStatus.fromJson(mblog);
        if (s.id.isNotEmpty && seen.add(s.id)) statuses.add(s);
      }
      for (final g in _asList(card['card_group'])) {
        walk(_asMap(g));
      }
    }

    walk(data);
    final totalRaw = data['total'];
    return ContainerPage(
      statuses: statuses,
      total: totalRaw is num ? totalRaw.toInt() : statuses.length,
      nextPage: statuses.isEmpty ? 0 : page + 1,
    );
  }

  /// 文章容器 231912{uid}_-_ordinary：mblog 在 card_type 11 的 card_group 里，
  /// 正文在 mblog.text（HTML），通用解析已处理（访客实测可读）。
  Future<ContainerPage> getUserArticles(String uid, {int page = 1}) async {
    final data = await _container({
      'type': 'uid',
      'value': uid,
      'containerid': '231912${uid}_-_ordinary',
      'page': page,
    }, referer: 'https://m.weibo.cn/u/$uid');
    return _parseContainer(data);
  }

  // ---------------- 表情 ----------------

  static const _emoticonCacheKey = 'weiyue_emoticon_map_v1';
  Map<String, String>? _emoticonMem;

  /// 表情映射：内存 → SharedPreferences 落盘缓存 → 拉 statuses/config 解析。
  /// config 全量约 747KB，解析后的映射只有几百条，只落盘小映射。
  /// 任何失败返回空映射（正文保持 [泪] 原文显示），不抛错。
  Future<Map<String, String>> getEmoticonMap() async {
    final mem = _emoticonMem;
    if (mem != null) return mem;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_emoticonCacheKey);
      if (cached != null && cached.isNotEmpty) {
        final decoded = jsonDecode(cached);
        if (decoded is Map && decoded.isNotEmpty) {
          final map = decoded.map((k, v) => MapEntry('$k', '$v'));
          _emoticonMem = map;
          return map;
        }
      }
    } catch (_) {
      // 落盘缓存损坏则当作无缓存，继续走网络
    }
    try {
      final json = await _get(WbStack.pc, '$_pcBase/ajax/statuses/config');
      final map = parseEmoticonMap(_asMap(json['data']));
      if (map.isNotEmpty) {
        _emoticonMem = map;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_emoticonCacheKey, jsonEncode(map));
        } catch (_) {}
        return map;
      }
    } catch (_) {}
    return const {};
  }

  /// 启动后异步调用：装入表情映射并通知正文刷新（失败静默）。
  Future<void> loadEmoticons() async {
    try {
      Emoticons.install(await getEmoticonMap());
    } catch (_) {}
  }

  // ---------------- 视频合集详情 ----------------

  /// 合集详情（访客实测，仅 playlist_id 一种参数形状成立）：
  /// /ajax/profile/videoalbumdetail?playlist_id= → data.list 为完整帖子对象
  /// （个别条目可能包在 video_detail_vo 里，一并解包），next_cursor 游标翻页。
  Future<({List<WbStatus> statuses, int nextCursor})> getVideoAlbum(
    String playlistId, {
    int cursor = 0,
  }) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/profile/videoalbumdetail',
      query: {'playlist_id': playlistId, if (cursor != 0) 'cursor': cursor},
    );
    final data = _asMap(json['data']);
    final statuses = <WbStatus>[];
    for (final item in _asList(data['list'])) {
      final im = _asMap(item);
      final vo = _asMap(im['video_detail_vo']);
      final s = WbStatus.fromJson(vo.isNotEmpty ? vo : im);
      if (s.id.isNotEmpty) statuses.add(s);
    }
    final nc = data['next_cursor'];
    return (
      statuses: statuses,
      // 实测 next_cursor 是字符串形态，数字/字符串都接
      nextCursor: nc is num
          ? nc.toInt()
          : (nc is String ? int.tryParse(nc) ?? -1 : -1),
    );
  }

  // ---------------- 相册（正规接口） ----------------

  /// 相册列表（访客实测可读）。getAlbumDetail 实测对访客恒返回空，
  /// 照片走 albumlist 给出的 m 容器（containerid 内嵌 background 参数）。
  Future<List<WbAlbum>> getAlbums(String uid) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/profile/albumlist',
      query: {'uid': uid},
    );
    return _asList(json['data'])
        .map((e) => WbAlbum.fromJson(_asMap(e)))
        .where((a) => a.containerid.isNotEmpty)
        .toList();
  }

  /// 相册照片：优先「原创」相册（containerid 含 camera_-_0），容器卡里
  /// card_type 47 的 pics 数组即照片（small/middle/big/mw2000 四档）。
  /// 返回按卡分组的照片列表；拿不到相册/照片时返回空，调用方回退旧逻辑。
  Future<List<List<WbPic>>> getAlbumPhotoGroups(String uid) async {
    final albums = await getAlbums(uid);
    if (albums.isEmpty) return const [];
    final pick = albums.firstWhere(
      (a) => a.containerid.contains('camera_-_0'),
      orElse: () => albums.firstWhere(
        (a) => a.containerid.contains('photo'),
        orElse: () => albums.first,
      ),
    );
    final data = await _container({
      'containerid': pick.containerid,
      'background': 'ffffff',
      'page': 1,
    }, referer: 'https://m.weibo.cn/u/$uid');
    final groups = <List<WbPic>>[];
    void walk(Map<String, dynamic> card) {
      final picsRaw = _asList(card['pics']);
      if (picsRaw.isNotEmpty) {
        final pics = <WbPic>[];
        for (final p in picsRaw) {
          final pm = _asMap(p);
          String u(String k) =>
              '${pm[k] ?? ''}'.replaceFirst('http://', 'https://');
          final big = u('pic_big');
          final original = u('pic_mw2000');
          pics.add(
            WbPic(
              pid: '${pm['pic_id'] ?? ''}',
              thumbnail: u('pic_small'),
              bmiddle: u('pic_middle'),
              large: big,
              original: original.isNotEmpty ? original : big,
            ),
          );
        }
        pics.removeWhere((p) => p.large.isEmpty && p.thumbnail.isEmpty);
        if (pics.isNotEmpty) groups.add(pics);
      }
      for (final g in _asList(card['card_group'])) {
        walk(_asMap(g));
      }
    }

    for (final c in _asList(data['cards'])) {
      walk(_asMap(c));
    }
    return groups;
  }

  // ---------------- 直播 ----------------

  /// 直播流地址：/ajax/multimedia/getLiveInfo?live_id={object_id}。
  /// ⚠️ 未实测：访客态找不到任何直播/回放帖样本，响应结构未知。
  /// 这里只做防御性提取——在返回 JSON 里找形似流地址的字段，
  /// 找不到/失败一律返回 null，调用方保持现状（不影响普通帖子）。
  Future<String?> getLiveStreamUrl(String liveId) async {
    try {
      final json = await _get(
        WbStack.pc,
        '$_pcBase/ajax/multimedia/getLiveInfo',
        query: {'live_id': liveId},
      );
      final data = _asMap(json['data']);
      return _findStreamUrl(data.isNotEmpty ? data : json);
    } catch (_) {
      return null;
    }
  }

  static String? _findStreamUrl(dynamic node, {int depth = 0}) {
    if (node == null || depth > 6) return null;
    if (node is Map) {
      for (final k in const [
        'stream_url',
        'flv_url',
        'hls_url',
        'live_url',
        'replay_url',
        'play_url',
        'pull_url',
        'url',
      ]) {
        final v = node[k];
        if (v is String && v.contains('://')) {
          return v.replaceFirst('http://', 'https://');
        }
      }
      for (final v in node.values) {
        final r = _findStreamUrl(v, depth: depth + 1);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findStreamUrl(v, depth: depth + 1);
        if (r != null) return r;
      }
    } else if (node is String &&
        node.contains('://') &&
        RegExp(r'\.(flv|m3u8)(\?|$)').hasMatch(node)) {
      return node.replaceFirst('http://', 'https://');
    }
    return null;
  }

  // ---------------- 登录探活 ----------------

  /// 从 setting/getBasicInfo 或 profile/info 的响应里防御式提取当前用户：
  /// 依次找 data.user / data 本人（带 screen_name）/ 顶层 user。
  static WbUser? _parseCurrentUser(Map<String, dynamic> json) {
    final data = _asMap(json['data']);
    for (final candidate in [
      _asMap(data['user']),
      data,
      _asMap(json['user']),
    ]) {
      if (candidate.isEmpty) continue;
      final u = WbUser.fromJson(candidate);
      if (u.id > 0 || u.screenName.isNotEmpty) return u;
    }
    return null;
  }

  static final _uidAssignRe = RegExp(
    r"""\[\s*['"]uid['"]\s*\]\s*=\s*['"](\d{3,15})['"]""",
  );
  static final _uidKeyRe = RegExp(
    r"""['"]uid['"]\s*:\s*['"]?(\d{3,15})['"]?""",
  );

  /// 从桌面首页 HTML 里提取当前登录用户的 uid（探活主路径）。
  ///
  /// 登录态首页的内嵌配置带有本人 uid，形态有二：
  /// `$CONFIG['uid']='123456'`（赋值式）与配置对象里的 `"uid":"123456"`
  /// （键值式）。先逐个在 `$CONFIG` 段落附近（其后 4096 字符内）找，
  /// 避免误匹配页面里其他用户的 id；段落里没有再退到全文第一个
  /// `"uid"` 键。只认纯数字、排除全 0；提取不到返回 null（不抛）。
  static String? extractSelfUidFromHomepage(String html) {
    String? pick(String s) {
      for (final re in [_uidAssignRe, _uidKeyRe]) {
        final m = re.firstMatch(s);
        if (m != null) {
          final v = m.group(1)!;
          if (!RegExp(r'^0+$').hasMatch(v)) return v;
        }
      }
      return null;
    }

    var idx = 0;
    while (true) {
      final at = html.indexOf(r'$CONFIG', idx);
      if (at < 0) break;
      final end = at + 4096 > html.length ? html.length : at + 4096;
      final found = pick(html.substring(at, end));
      if (found != null) return found;
      idx = at + 7;
    }
    return pick(html);
  }

  /// 探活主路径：用登录 Cookie 拉桌面首页 HTML 并提取本人 uid。
  /// sessionOnly 不回退访客——访客/未登录首页的配置里没有本人 uid。
  /// 顺带收下响应 Set-Cookie 里的 XSRF-TOKEN 存入会话：该令牌由页面
  /// 响应下发，WebView 收割的时机/域名覆盖常拿不到（真机实证恒「无」），
  /// 而它正是首页这类页面响应才发的。异常向上抛，由探活处记录。
  Future<String?> _fetchSelfUid() async {
    String? xsrf;
    final html = await _getRaw(
      WbStack.pc,
      '$_pcBase/',
      sessionOnly: true,
      onResponse: (resp) {
        final setCookies = resp.headers.map['set-cookie'];
        if (setCookies == null) return;
        for (final raw in setCookies) {
          final m = RegExp(r'^\s*XSRF-TOKEN=([^;]*)').firstMatch(raw);
          final v = (m?.group(1) ?? '').trim();
          if (v.isNotEmpty) xsrf = v;
        }
      },
    );
    final token = xsrf;
    if (token != null && token != session.xsrfToken()) {
      await session.saveHarvest([
        HarvestedCookie(name: 'XSRF-TOKEN', value: token, domain: 'weibo.com'),
      ]);
    }
    return extractSelfUidFromHomepage(html);
  }

  /// 登录探活（收割 Cookie 后调用）：全部走 sessionOnly 请求，
  /// 不回退访客——访客能读的接口成功不代表登录解锁。
  /// - PC 本人 uid（主路径）：拉桌面首页 HTML 从内嵌配置提取 uid，
  ///   再 /ajax/profile/info?uid= 拿当前用户。v0.1.8 真机诊断实证：
  ///   无参 profile/info 与空 uid 的 friendships/friends 均回 HTTP 400
  ///   非 JSON，uid 拿不到则名称/头像/关注全卡住，故此路优先。
  /// - PC 兜底：/ajax/setting/getBasicInfo、无参 profile/info 依次试，
  ///   都拿不到用户时用 friendstimeline 不被挡（访客恒 403）判解锁。
  /// - m 栈：/api/statuses/repostTimeline 访客固定回 ok:-100（文档实测），
  ///   登录态回任何正常 JSON 即算解锁（用哑 id 探，不取真实数据）。
  /// 诊断快照在 finally 里无条件写：任何一步异常都不许让快照停在旧时间。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
  Future<({WbUser? user, bool pcUnlocked, bool mUnlocked})>
  probeSession() async {
    WbUser? user;
    var pcOk = false;
    var mOk = false;
    try {
      try {
        final uid = await _fetchSelfUid();
        if (uid != null && uid.isNotEmpty) {
          final info = await getProfileInfo(uid);
          if (info.id > 0 || info.screenName.isNotEmpty) {
            user = info;
            pcOk = true;
          }
        }
      } catch (e) {
        session.recordLoginFailure('weibo.com 首页', '$e');
      }
      if (user == null) {
        try {
          final json = await _get(
            WbStack.pc,
            '$_pcBase/ajax/setting/getBasicInfo',
            sessionOnly: true,
          );
          user = _parseCurrentUser(json);
          pcOk = user != null;
        } catch (e) {
          session.recordLoginFailure('/ajax/setting/getBasicInfo', '$e');
        }
      }
      if (user == null) {
        try {
          final json = await _get(
            WbStack.pc,
            '$_pcBase/ajax/profile/info',
            sessionOnly: true,
          );
          user = _parseCurrentUser(json);
          pcOk = user != null;
        } catch (e) {
          session.recordLoginFailure('/ajax/profile/info', '$e');
        }
      }
      if (!pcOk) {
        try {
          await _get(
            WbStack.pc,
            '$_pcBase/ajax/feed/friendstimeline',
            query: {'list_id': 10001, 'refresh': 4, 'since_id': 0, 'count': 3},
            sessionOnly: true,
          );
          pcOk = true;
        } catch (e) {
          session.recordLoginFailure('/ajax/feed/friendstimeline', '$e');
        }
      }
      try {
        await _get(
          WbStack.m,
          '$_mBase/api/statuses/repostTimeline',
          query: {'id': '0', 'page': 1},
          sessionOnly: true,
        );
        mOk = true;
      } catch (e) {
        session.recordLoginFailure('/api/statuses/repostTimeline', '$e');
      }
      // 探活末尾顺带补拉本人完整资料并持久化（资料头展示用）；
      // 补拉失败不影响探活结论，账号区回退简版展示后可再自动/手动重拉。
      if (user != null && user.id > 0) {
        try {
          final full = await getMyProfile('${user.id}');
          await session.saveProfile(full);
        } catch (_) {}
      }
    } finally {
      session.recordProbeResult(
        pcUnlocked: pcOk,
        mUnlocked: mOk,
        hasUid: user != null && user.id > 0,
      );
    }
    return (user: user, pcUnlocked: pcOk, mUnlocked: mOk);
  }

  // ---------------- 登录态只读解锁 ----------------

  /// 关注流（登录后可用，访客 403）：/ajax/feed/friendstimeline。
  /// 响应结构未实测登录态，防御解析：statuses 依次找顶层 statuses /
  /// data.list / data.statuses；游标 since_id 顶层与 data 内都找，
  /// 原样回传续拉（可能为数字或 JSON 串）。
  Future<({List<WbStatus> statuses, String sinceId})> getFriendsTimeline({
    String sinceId = '0',
    int count = 20,
  }) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/feed/friendstimeline',
      query: {
        'list_id': 10001,
        'refresh': 4,
        'since_id': sinceId,
        'count': count,
      },
      referer: 'https://weibo.com/',
    );
    final data = _asMap(json['data']);
    var raw = _asList(json['statuses']);
    if (raw.isEmpty) raw = _asList(data['list']);
    if (raw.isEmpty) raw = _asList(data['statuses']);
    final statuses = raw
        .map((e) => WbStatus.fromJson(_asMap(e)))
        .where((s) => s.id.isNotEmpty)
        .toList();
    var sid = '${json['since_id'] ?? data['since_id'] ?? ''}';
    if (sid == 'null') sid = '';
    return (statuses: statuses, sinceId: sid);
  }

  /// 转发列表（登录后可用）：/ajax/statuses/repostTimeline。
  /// 访客固定回 `{data: [], total_number: 0, empty_tip: "…请登录后使用"}`；
  /// 登录态 data 为帖子对象数组，page/max_page 分页（文档结构）。
  Future<({List<WbStatus> items, int total, int maxPage})> getReposts(
    String id, {
    int page = 1,
  }) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/statuses/repostTimeline',
      query: {'id': id, 'page': page, 'moduleID': 'feed', 'feature': 0},
      referer: 'https://weibo.com/detail/$id',
    );
    final items = _asList(json['data'])
        .map((e) => WbStatus.fromJson(_asMap(e)))
        .where((s) => s.id.isNotEmpty)
        .toList();
    return (
      items: items,
      total: _intOf(json['total_number']),
      maxPage: _intOf(json['max_page']),
    );
  }

  /// 我的收藏（登录后可用）：/ajax/favorites/all_fav（文档 favorites 族）。
  /// 登录态真实结构未经实测，解析尽量加宽：条目依次找 data 直接为数组 /
  /// data.fav_list / data.statuses / data.list / 顶层 favorites / 顶层 list；
  /// 单条解包依次试 status / fav / mblog 子对象，否则按帖子对象直接解析。
  /// 服务端带错误信息回空（ok=0 或 msg/error）时把消息抛给收藏页展示，
  /// 不再静默吞成空列表；真空收藏（无错误信息）仍返回空列表走空态。
  Future<({List<WbStatus> items, int total})> getFavorites({
    int page = 1,
  }) async {
    try {
      final json = await _get(
        WbStack.pc,
        '$_pcBase/ajax/favorites/all_fav',
        query: {'page': page},
      );
      final data = _asMap(json['data']);
      var raw = _asList(json['data']);
      if (raw.isEmpty) raw = _asList(data['fav_list']);
      if (raw.isEmpty) raw = _asList(data['statuses']);
      if (raw.isEmpty) raw = _asList(data['list']);
      if (raw.isEmpty) raw = _asList(json['favorites']);
      if (raw.isEmpty) raw = _asList(json['list']);
      final items = <WbStatus>[];
      for (final e in raw) {
        final em = _asMap(e);
        var inner = _asMap(em['status']);
        if (inner.isEmpty) inner = _asMap(em['fav']);
        if (inner.isEmpty) inner = _asMap(em['mblog']);
        final s = WbStatus.fromJson(inner.isNotEmpty ? inner : em);
        if (s.id.isNotEmpty) items.add(s);
      }
      if (items.isEmpty) {
        final msg = _firstErrorText([
          json['msg'],
          json['error'],
          data['msg'],
          data['error'],
        ]);
        final okVal = json['ok'];
        if (okVal == 0 || okVal == '0' || msg.isNotEmpty) {
          throw WeiyueException(msg.isNotEmpty ? msg : '收藏接口返回错误（ok=0）');
        }
      }
      final totalRaw =
          data['total_number'] ??
          json['total_number'] ??
          data['total'] ??
          json['total'];
      final total = _intOf(totalRaw);
      return (items: items, total: total > 0 ? total : items.length);
    } catch (e) {
      session.recordLoginFailure('/ajax/favorites/all_fav', '$e');
      rethrow;
    }
  }

  /// 取第一个非空、非 'null' 的错误文案。
  static String _firstErrorText(List<dynamic> values) {
    for (final v in values) {
      final s = '${v ?? ''}'.trim();
      if (s.isNotEmpty && s != 'null') return s;
    }
    return '';
  }

  /// 我关注的博主列表（登录后可用，访客回 `{}`）：
  /// GET /ajax/friendships/friends?uid=&relate=follows&count=&page=
  /// （WEIBO_API.md 被挡清单记载的确切路径；relate=fans 为粉丝列表）。
  /// 登录态响应结构未实测，防御解析：用户数组依次找 data.users /
  /// 顶层 users，总数依次找 data.total_number / 顶层 total_number。
  /// uid 为空直接抛错（同 getMyProfile：空参必 400，不发请求）。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
  Future<({List<WbUser> users, int total})> getMyFollowing(
    String uid, {
    int page = 1,
    int count = 20,
  }) async {
    if (uid.trim().isEmpty) {
      throw const WeiyueException('缺少用户 ID，请先点「修复登录态」或重新检测');
    }
    try {
      final json = await _get(
        WbStack.pc,
        '$_pcBase/ajax/friendships/friends',
        query: {'uid': uid, 'relate': 'follows', 'count': count, 'page': page},
        referer: 'https://weibo.com/u/$uid',
      );
      final data = _asMap(json['data']);
      var raw = _asList(data['users']);
      if (raw.isEmpty) raw = _asList(json['users']);
      final users = raw
          .map((e) => WbUser.fromJson(_asMap(e)))
          .where((u) => u.id > 0)
          .toList();
      final totalRaw = data['total_number'] ?? json['total_number'];
      return (users: users, total: _intOf(totalRaw));
    } catch (e) {
      session.recordLoginFailure('/ajax/friendships/friends', '$e');
      rethrow;
    }
  }

  // ---------------- 消息中心（登录态只读，/ajax/message 族） ----------------
  // 依据：WEIBO_API.md「登录与写接口」节静态确认路径 + PC 网页端主包
  // （raw/pc_index.js）消息页组件实证：页签配置（tagMessage）、双游标
  // 分页（请求 max_id+sinceId，响应 data.next_cursor/data.nextId）、
  // 信封（data[<类型键>] 为条目数组）、各类型条目字段。登录态真实
  // 返回未经真机实测，解析全部防御式，失败记入登录诊断。

  /// 消息族列表信封解包。[typeKey] 为该接口的条目键
  /// （list/statuses/comments/attitudes）。防御顺序：data[typeKey] →
  /// data 的 list/statuses/comments/attitudes/data → data 本身为数组 →
  /// 顶层同名键。终止判据（主包实证）：list 型看 nextId==0，其余看
  /// next_cursor==0；本页为空也终止。某一游标缺失时退回看另一游标。
  ({List<dynamic> raw, String maxId, String sinceId, bool hasMore})
  _messageEnvelope(Map<String, dynamic> json, String typeKey) {
    final data = _asMap(json['data']);
    var raw = _asList(data[typeKey]);
    if (raw.isEmpty) {
      for (final k in const [
        'list',
        'statuses',
        'comments',
        'attitudes',
        'data',
      ]) {
        raw = _asList(data[k]);
        if (raw.isNotEmpty) break;
      }
    }
    if (raw.isEmpty) raw = _asList(json['data']);
    if (raw.isEmpty) {
      for (final k in [
        typeKey,
        'list',
        'statuses',
        'comments',
        'attitudes',
      ]) {
        raw = _asList(json[k]);
        if (raw.isNotEmpty) break;
      }
    }
    String cursorOf(dynamic v) {
      final s = '${v ?? ''}'.trim();
      return (s.isEmpty || s == 'null') ? '' : s;
    }

    final nextMaxId = cursorOf(data['next_cursor'] ?? json['next_cursor']);
    final nextSinceId = cursorOf(
      data['nextId'] ?? data['next_id'] ?? json['nextId'],
    );
    var hasMore = raw.isNotEmpty;
    if (hasMore) {
      bool live(String c) => c.isNotEmpty && c != '0';
      if (typeKey == 'list') {
        hasMore = nextSinceId.isNotEmpty
            ? live(nextSinceId)
            : live(nextMaxId);
      } else {
        hasMore = nextMaxId.isNotEmpty ? live(nextMaxId) : live(nextSinceId);
      }
    }
    return (raw: raw, maxId: nextMaxId, sinceId: nextSinceId, hasMore: hasMore);
  }

  /// 消息族列表通用拉取：双游标透传，失败记诊断后原样上抛。
  Future<MessagePage<dynamic>> _messageList(
    String path,
    String typeKey, {
    Map<String, dynamic> extra = const {},
    String maxId = '',
    String sinceId = '',
  }) async {
    try {
      final json = await _get(
        WbStack.pc,
        '$_pcBase$path',
        query: {
          ...extra,
          'max_id': maxId.isEmpty ? 0 : maxId,
          if (sinceId.isNotEmpty) 'sinceId': sinceId,
        },
        referer: 'https://weibo.com/messages',
      );
      final env = _messageEnvelope(json, typeKey);
      return (
        items: env.raw,
        maxId: env.maxId,
        sinceId: env.sinceId,
        hasMore: env.hasMore,
      );
    } catch (e) {
      session.recordLoginFailure(path, '$e');
      rethrow;
    }
  }

  /// 全部消息（近 24 小时混合流）：GET /ajax/message/msgList?type=all。
  /// ⚠️ 主包实证语义是「24 小时全部」混合流（状态/评论/赞按 msg_type
  /// 混排），不是私信会话列表——网页端私信走独立 chat 子系统，
  /// 不在 message 族内（见报告）。
  Future<MessagePage<MessageFeedItem>> getMessageFeed({
    String maxId = '',
    String sinceId = '',
  }) async {
    final page = await _messageList(
      '/ajax/message/msgList',
      'list',
      extra: const {'type': 'all'},
      maxId: maxId,
      sinceId: sinceId,
    );
    return (
      items: page.items
          .map((e) => MessageFeedItem.fromJson(_asMap(e)))
          .where((it) => it.hasContent)
          .toList(),
      maxId: page.maxId,
      sinceId: page.sinceId,
      hasMore: page.hasMore,
    );
  }

  /// @我的微博：GET /ajax/statuses/mentions（主包 atMe 页签实证；
  /// filter_by_author=1 只看关注的人，filter_by_type=1 只看原创）。
  Future<MessagePage<WbStatus>> getMentions({
    String maxId = '',
    String sinceId = '',
    bool onlyFollowed = false,
    bool onlyOriginal = false,
  }) async {
    final page = await _messageList(
      '/ajax/statuses/mentions',
      'statuses',
      extra: {
        if (onlyFollowed) 'filter_by_author': 1,
        if (onlyOriginal) 'filter_by_type': 1,
      },
      maxId: maxId,
      sinceId: sinceId,
    );
    return (
      items: page.items
          .map((e) => WbStatus.fromJson(_asMap(e)))
          .where((s) => s.id.isNotEmpty)
          .toList(),
      maxId: page.maxId,
      sinceId: page.sinceId,
      hasMore: page.hasMore,
    );
  }

  /// @我的评论：GET /ajax/comments/mentions（主包 atMe 页签实证）。
  Future<MessagePage<MessageComment>> getMentionComments({
    String maxId = '',
    String sinceId = '',
    bool onlyFollowed = false,
  }) async {
    final page = await _messageList(
      '/ajax/comments/mentions',
      'comments',
      extra: {if (onlyFollowed) 'filter_by_author': 1},
      maxId: maxId,
      sinceId: sinceId,
    );
    return (
      items: page.items
          .map((e) => MessageComment.fromJson(_asMap(e)))
          .where((c) => c.comment.id.isNotEmpty)
          .toList(),
      maxId: page.maxId,
      sinceId: page.sinceId,
      hasMore: page.hasMore,
    );
  }

  /// 收到的评论：GET /ajax/message/cmt（filter_by_author=1 只看
  /// 关注的人，主包 cmt 页签实证）。
  Future<MessagePage<MessageComment>> getCommentsToMe({
    String maxId = '',
    String sinceId = '',
    bool onlyFollowed = false,
  }) async {
    final page = await _messageList(
      '/ajax/message/cmt',
      'comments',
      extra: {if (onlyFollowed) 'filter_by_author': 1},
      maxId: maxId,
      sinceId: sinceId,
    );
    return (
      items: page.items
          .map((e) => MessageComment.fromJson(_asMap(e)))
          .where((c) => c.comment.id.isNotEmpty)
          .toList(),
      maxId: page.maxId,
      sinceId: page.sinceId,
      hasMore: page.hasMore,
    );
  }

  /// 我发出的评论：GET /ajax/message/myCmt（主包 cmt 页签子项实证，
  /// 与收到的评论同页签切换）。
  Future<MessagePage<MessageComment>> getMyComments({
    String maxId = '',
    String sinceId = '',
  }) async {
    final page = await _messageList(
      '/ajax/message/myCmt',
      'comments',
      maxId: maxId,
      sinceId: sinceId,
    );
    return (
      items: page.items
          .map((e) => MessageComment.fromJson(_asMap(e)))
          .where((c) => c.comment.id.isNotEmpty)
          .toList(),
      maxId: page.maxId,
      sinceId: page.sinceId,
      hasMore: page.hasMore,
    );
  }

  /// 收到的赞：GET /ajax/message/attitudes。
  Future<MessagePage<MessageLike>> getLikesToMe({
    String maxId = '',
    String sinceId = '',
  }) async {
    final page = await _messageList(
      '/ajax/message/attitudes',
      'attitudes',
      maxId: maxId,
      sinceId: sinceId,
    );
    return (
      items: page.items
          .map((e) => MessageLike.fromJson(_asMap(e)))
          .where((l) => l.user != null || l.status != null)
          .toList(),
      maxId: page.maxId,
      sinceId: page.sinceId,
      hasMore: page.hasMore,
    );
  }

  /// 消息未读汇总：GET /ajax/message/unreadHint + /ajax/message/summary
  /// 多形态防御提取。本方法不抛错（徽标拉取失败只记诊断、返回已提取
  /// 部分或全零），避免拖垮「我的」页与消息中心页签渲染。
  ///
  /// 依据等级：unreadHint 的 groups 形态（[{键: 数}]）与 summary 的
  /// {summary:{topUsers/followers/field}} 形态为主包实证，但 summary
  /// 那三个数是 24 小时互动量、不是分类未读，不往分类上映射；
  /// 分类键名（mention_status/all_mention_cmt/cmt/attitude）为主包
  /// 未读状态表实证，其数值在主包里来自独立的 remind 接口——
  /// 期待它出现在 unreadHint/summary 响应里属推测防御，取不到即全零。
  Future<MessageUnread> getMessageSummary() async {
    final merged = <String, int>{};
    void absorb(Map<String, dynamic> m) {
      for (final e in m.entries) {
        final v = _intOf(e.value);
        if (v > 0) merged[e.key] = v;
      }
      for (final g in _asList(m['groups'])) {
        absorb(_asMap(g));
      }
      absorb(_asMap(m['unread']));
    }

    try {
      final hint = await _get(
        WbStack.pc,
        '$_pcBase/ajax/message/unreadHint',
        referer: 'https://weibo.com/messages',
      );
      absorb(_asMap(hint['data']));
      absorb(hint);
    } catch (e) {
      session.recordLoginFailure('/ajax/message/unreadHint', '$e');
    }
    try {
      final sum = await _get(
        WbStack.pc,
        '$_pcBase/ajax/message/summary',
        referer: 'https://weibo.com/messages',
      );
      absorb(_asMap(sum['data']));
      absorb(_asMap(sum['summary']));
      absorb(sum);
    } catch (e) {
      session.recordLoginFailure('/ajax/message/summary', '$e');
    }
    int pick(List<String> keys) {
      for (final k in keys) {
        final v = merged[k];
        if (v != null && v > 0) return v;
      }
      return 0;
    }

    return MessageUnread(
      mentionStatuses: pick(['mention_status']),
      mentionComments: pick(['all_mention_cmt', 'mention_cmt']),
      commentsToMe: pick(['cmt']),
      likesToMe: pick(['attitude', 'attitudes']),
      directMessages: pick(['dm_total', 'dm']),
      serverTotal: pick(['messages', 'total']),
    );
  }

  // ---------------- 互动写操作（登录态） ----------------

  /// 通用 POST（写操作专用）：身份规则与 _get 相反——**只许登录态**。
  /// - 无可用登录 Cookie：直接抛「请先登录」，绝不回退访客、
  ///   绝不把写请求发给访客身份（一个字节都不发出去）；
  /// - PC 栈必须带 `X-Xsrf-Token` 头（网页端写接口的硬性要求，
  ///   文档「登录与写接口」节静态确认）：会话里没有令牌时抛可读错误，
  ///   提示先修复登录态；
  /// - 表单编码 application/x-www-form-urlencoded（与网页端一致）。
  /// 成功判据：HTTP 200 且 ok 不为 0、且无 error/error_code 错误字段。
  /// 失败时把服务端的 msg/error 文案原样提出来抛 WeiyueException，
  /// 并记入登录诊断（recordLoginFailure，路径+消息）。
  Future<Map<String, dynamic>> _post(
    WbStack stack,
    String url, {
    required Map<String, dynamic> form,
    String? referer,
  }) async {
    final path = Uri.parse(url).path;
    if (!session.hasUsableCookie(stack)) {
      session.recordLoginFailure(path, '请先登录');
      throw const WeiyueException('请先登录');
    }
    if (stack == WbStack.pc) {
      final xsrf = session.xsrfToken();
      if (xsrf == null || xsrf.isEmpty) {
        const msg = '缺少 XSRF 令牌，请先点「修复登录态」或重新登录';
        session.recordLoginFailure(path, msg);
        throw const WeiyueException(msg);
      }
    }
    final cookie = session.cookieHeaderFor(stack)!;
    final dio = stack == WbStack.pc ? _pc : _m;
    final Response<dynamic> resp;
    try {
      resp = await dio.post<dynamic>(
        url,
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: _requestHeaders(
            stack,
            cookie: cookie,
            useSession: true,
            referer: referer,
          ),
        ),
      );
    } on DioException catch (e) {
      final msg = '网络错误：${e.message ?? e.type.name}';
      session.recordLoginFailure(path, msg);
      throw WeiyueException(msg);
    }
    final status = resp.statusCode ?? 0;
    final data = resp.data;
    Map<String, dynamic>? json;
    if (data is Map) json = _asMap(data);
    final location = resp.headers.value('location') ?? '';
    final rawBody = data is String ? data : '';
    if (_notLoggedInSignal(status, json, location, rawBody)) {
      session.markExpired();
      const msg = '登录态已失效，请重新登录';
      session.recordLoginFailure(path, msg);
      throw const WeiyueException(msg);
    }
    if (json == null) {
      final msg = '接口返回非 JSON（HTTP $status）';
      session.recordLoginFailure(path, msg);
      throw WeiyueException(msg);
    }
    final dataMap = _asMap(json['data']);
    final errText = _firstErrorText([
      json['msg'],
      json['error'],
      json['error_msg'],
      dataMap['msg'],
      dataMap['error'],
    ]);
    final okVal = json['ok'];
    final okFailed = okVal == 0 || okVal == '0' || okVal == false;
    final errVal = json['error'];
    final hasErrField =
        (errVal is String && errVal.trim().isNotEmpty) ||
        json['error_code'] != null;
    if (okFailed || hasErrField || status != 200) {
      final msg = errText.isNotEmpty ? errText : '请求失败（HTTP $status）';
      session.recordLoginFailure(path, msg);
      throw WeiyueException(msg);
    }
    return json;
  }

  String _detailReferer(String id) => 'https://weibo.com/detail/$id';

  /// 点赞：POST /ajax/statuses/setLike（文档写接口清单原文），参数 id。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
  Future<void> likeStatus(String id) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/setLike',
      form: {'id': id},
      referer: _detailReferer(id),
    );
  }

  /// 取消点赞：POST /ajax/statuses/cancelLike（文档清单原文），参数 id。
  Future<void> unlikeStatus(String id) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/cancelLike',
      form: {'id': id},
      referer: _detailReferer(id),
    );
  }

  /// 发评论：POST /ajax/comments/create（文档清单原文），
  /// 参数 id（帖子）+ comment（正文）。成功响应可能是评论对象本体
  /// （顶层或 data 内），能解析出评论就返回，解析不到返回 null
  ///（调用方以刷新评论列表为准，不依赖此返回值）。
  Future<WbComment?> createComment(String statusId, String text) async {
    final json = await _post(
      WbStack.pc,
      '$_pcBase/ajax/comments/create',
      form: {'id': statusId, 'comment': text},
      referer: _detailReferer(statusId),
    );
    return _parseCreatedComment(json);
  }

  /// 回复评论：POST /ajax/comments/reply（文档清单原文），
  /// 参数 cid（被回复的评论 id）+ id（帖子）+ comment（正文）。
  Future<WbComment?> replyComment({
    required String statusId,
    required String commentId,
    required String text,
  }) async {
    final json = await _post(
      WbStack.pc,
      '$_pcBase/ajax/comments/reply',
      form: {'cid': commentId, 'id': statusId, 'comment': text},
      referer: _detailReferer(statusId),
    );
    return _parseCreatedComment(json);
  }

  /// 从评论写接口的响应里防御式提取新建评论：依次找 data 本体 /
  /// data.comment / 顶层本体 / 顶层 comment；id 与 text 都缺的视为无。
  static WbComment? _parseCreatedComment(Map<String, dynamic> json) {
    final data = _asMap(json['data']);
    for (final candidate in [
      data,
      _asMap(data['comment']),
      json,
      _asMap(json['comment']),
    ]) {
      if (candidate.isEmpty) continue;
      final c = WbComment.fromJson(candidate);
      if (c.id.isNotEmpty) return c;
    }
    return null;
  }

  /// 转发：POST /ajax/statuses/repost（文档清单原文；同族另有
  /// normal_repost，清单未区分语义，带转发语的对话框形态取 repost），
  /// 参数 id + comment（转发语，可空串=无语转发）。
  Future<void> repostStatus(String id, {String comment = ''}) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/repost',
      form: {'id': id, 'comment': comment},
      referer: _detailReferer(id),
    );
  }

  /// 收藏（创建）：POST /ajax/favorites/create，参数 id。
  /// ⚠️ **推测实现**：文档 favorites 族只列了 all_fav|show|tags，
  /// 创建路径不在清单内；按族名+老 API 惯例推测为 favorites/create。
  /// 调用收敛在此单点，路径若不对只改这一处。
  Future<void> createFavorite(String id) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/favorites/create',
      form: {'id': id},
      referer: _detailReferer(id),
    );
  }

  /// 取消收藏：POST /ajax/statuses/destoryFavorites
  ///（文档原文拼写就是 destory），参数 id。
  Future<void> destroyFavorite(String id) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/destoryFavorites',
      form: {'id': id},
      referer: _detailReferer(id),
    );
  }

  /// 关注：POST /ajax/friendships/create（文档清单原文）。
  /// 参数名清单未给：卡片关注按钮抓包参数为 uid、网页端惯例为
  /// friend_id，两者同发（服务端忽略多余参数），收敛此单点便于修正。
  Future<void> followUser(String uid) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/friendships/create',
      form: {'friend_id': uid, 'uid': uid},
      referer: 'https://weibo.com/u/$uid',
    );
  }

  /// 取关：POST /ajax/friendships/destory（文档原文拼写），参数同关注。
  Future<void> unfollowUser(String uid) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/friendships/destory',
      form: {'friend_id': uid, 'uid': uid},
      referer: 'https://weibo.com/u/$uid',
    );
  }
}
