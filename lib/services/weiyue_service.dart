import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/emoticons.dart';
import '../models/models.dart';
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

/// 微博双栈只读接口（依据 WEIBO_API.md 实测结论）。
/// PC 栈管热门/详情/资料/视频，m 栈管搜索/用户时间线/评论/点赞，两栈混用。
class WeiyueService {
  final VisitorService visitor;

  late final Dio _pc;
  late final Dio _m;

  /// [pcDio]/[mDio] 可注入（测试用假 adapter）。
  WeiyueService(this.visitor, {Dio? pcDio, Dio? mDio}) {
    _pc = pcDio ?? _makeDio();
    _m = mDio ?? _makeDio();
  }

  static Dio _makeDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: false,
        // 302/403 要自己判断（访客失效信号），不让 dio 抛错
        validateStatus: (s) => s != null && s < 500,
      ));

  static const _pcBase = 'https://weibo.com';
  static const _mBase = 'https://m.weibo.cn';

  /// 通用 GET：自动带访客 Cookie；遇 302 / ok:-100 / 403 时重换访客重试一次。
  Future<Map<String, dynamic>> _get(
    WbStack stack,
    String url, {
    Map<String, dynamic>? query,
    String? referer,
    bool retried = false,
  }) async {
    final identity = await visitor.ensure(stack);
    final dio = stack == WbStack.pc ? _pc : _m;
    final Response<dynamic> resp;
    try {
      resp = await dio.get<dynamic>(
        url,
        queryParameters: query,
        options: Options(headers: {
          'User-Agent': visitor.uaOf(stack),
          'Referer': referer ??
              (stack == WbStack.pc ? 'https://weibo.com/' : 'https://m.weibo.cn/'),
          'X-Requested-With': 'XMLHttpRequest',
          'Cookie': identity.cookie,
        }),
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
    final visitorExpired = status == 301 ||
        status == 302 ||
        status == 403 ||
        (json != null && json["ok"] == -100);
    if (visitorExpired && !retried) {
      await visitor.refresh(stack);
      return _get(stack, url, query: query, referer: referer, retried: true);
    }
    if (visitorExpired) {
      throw const WeiyueException('访客身份失效，重试后仍被拦截');
    }
    if (json == null) {
      throw WeiyueException('接口返回非 JSON（HTTP $status）');
    }
    return json;
  }

  /// 纯文本 GET（同 _get 的访客处理）：给返回 JSONP 的接口用
  /// （m container/getItem 的响应被括号包裹，dio 的 JSON 解码接不住）。
  Future<String> _getRaw(
    WbStack stack,
    String url, {
    Map<String, dynamic>? query,
    String? referer,
    bool retried = false,
  }) async {
    final identity = await visitor.ensure(stack);
    final dio = stack == WbStack.pc ? _pc : _m;
    final Response<dynamic> resp;
    try {
      resp = await dio.get<dynamic>(
        url,
        queryParameters: query,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': visitor.uaOf(stack),
            'Referer': referer ??
                (stack == WbStack.pc
                    ? 'https://weibo.com/'
                    : 'https://m.weibo.cn/'),
            'X-Requested-With': 'XMLHttpRequest',
            'Cookie': identity.cookie,
          },
        ),
      );
    } on DioException catch (e) {
      throw WeiyueException('网络错误：${e.message ?? e.type.name}');
    }
    final status = resp.statusCode ?? 0;
    final body = resp.data?.toString() ?? '';
    final visitorExpired = status == 301 || status == 302 || status == 403;
    if (visitorExpired && !retried) {
      await visitor.refresh(stack);
      return _getRaw(stack, url,
          query: query, referer: referer, retried: true);
    }
    if (visitorExpired) {
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
    WbChannel(gid: '102803600343', title: '实时', containerid: '102803_ctg1_600343_-_ctg1_600343'),
    WbChannel(gid: '102803600583', title: 'S16', containerid: '102803_ctg1_600583_-_ctg1_600583'),
    WbChannel(gid: '102803600169', title: '榜单', containerid: '102803_ctg1_600169_-_ctg1_600169'),
    WbChannel(gid: '1028034288', title: '明星', containerid: '102803_ctg1_4288_-_ctg1_4288'),
    WbChannel(gid: '1028034388', title: '搞笑', containerid: '102803_ctg1_4388_-_ctg1_4388'),
    WbChannel(gid: '1028031988', title: '情感', containerid: '102803_ctg1_1988_-_ctg1_1988'),
    WbChannel(gid: '102803600410', title: '短剧', containerid: '102803_ctg1_600410_-_ctg1_600410'),
    WbChannel(gid: '102803600311', title: '印像', containerid: '102803_ctg1_600311_-_ctg1_600311'),
    WbChannel(gid: '102803600195', title: '周末', containerid: '102803_ctg1_600195_-_ctg1_600195'),
    WbChannel(gid: '1028033288', title: '电影', containerid: '102803_ctg1_3288_-_ctg1_3288'),
    WbChannel(gid: '1028034188', title: '社会', containerid: '102803_ctg1_4188_-_ctg1_4188'),
    WbChannel(gid: '1028032488', title: '电视剧', containerid: '102803_ctg1_2488_-_ctg1_2488'),
    WbChannel(gid: '1028032688', title: '美食', containerid: '102803_ctg1_2688_-_ctg1_2688'),
    WbChannel(gid: '1028036288', title: '国际', containerid: '102803_ctg1_6288_-_ctg1_6288'),
    WbChannel(gid: '102803600155', title: '深度', containerid: '102803_ctg1_600155_-_ctg1_600155'),
  ];

  ({List<WbChannel> mine, List<WbChannel> recommended})? _channelsCache;

  Future<({List<WbChannel> mine, List<WbChannel> recommended})>
      getChannels() async {
    final cached = _channelsCache;
    if (cached != null) return cached;
    try {
      final json = await _get(WbStack.pc, '$_pcBase/ajax/feed/allGroups',
          query: {'is_new_segment': 1, 'fetch_hot': 1});
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
        return _channelsCache =
            (mine: mine, recommended: recommended);
      }
    } catch (_) {
      // 落回内置常量
    }
    return _channelsCache =
        (mine: fallbackChannels, recommended: const <WbChannel>[]);
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
      maxId: maxIdRaw is num ? maxIdRaw.toInt() : int.tryParse('$maxIdRaw') ?? 0,
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
    final json =
        await _get(WbStack.pc, '$_pcBase/ajax/statuses/$segment');
    final data = _asMap(json['data']);
    return _asList(data['band_list'])
        .map((e) => BandItem.fromJson(_asMap(e)))
        .where((b) => b.word.isNotEmpty)
        .toList();
  }

  // ---------------- 详情 / 评论 / 点赞 ----------------

  Future<WbStatus> getStatus(String id) async {
    final json = await _get(WbStack.pc, '$_pcBase/ajax/statuses/show',
        query: {'id': id}, referer: 'https://weibo.com/detail/$id');
    return WbStatus.fromJson(json);
  }

  /// 长文全文（纯文本）；失败返回空串
  Future<String> getLongText(String id) async {
    final json = await _get(WbStack.pc, '$_pcBase/ajax/statuses/longtext',
        query: {'id': id});
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
    final json = await _get(WbStack.m, '$_mBase/api/attitudes/show',
        query: {'id': id, 'page': page},
        referer: 'https://m.weibo.cn/detail/$id');
    final data = _asMap(json['data']);
    final items = _asList(data['data'])
        .map((e) => WbAttitude.fromJson(_asMap(e)))
        .toList();
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
    final json = await _get(WbStack.pc, '$_pcBase/ajax/profile/info',
        query: {'uid': uid}, referer: 'https://weibo.com/u/$uid');
    final data = _asMap(json['data']);
    return WbUser.fromJson(_asMap(data['user']));
  }

  /// profile/detail 原始 data（生日/注册时间/阳光信用/标签等），页面自行取行
  Future<Map<String, dynamic>> getProfileDetail(String uid) async {
    final json = await _get(WbStack.pc, '$_pcBase/ajax/profile/detail',
        query: {'uid': uid}, referer: 'https://weibo.com/u/$uid');
    return _asMap(json['data']);
  }

  /// m 容器泛型请求，返回 data
  Future<Map<String, dynamic>> _container(Map<String, dynamic> query,
      {String? referer}) async {
    final json = await _get(WbStack.m, '$_mBase/api/container/getIndex',
        query: query, referer: referer);
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
    final data = await _container(
      {'type': 'uid', 'value': uid, 'containerid': '107603$uid', 'page': page},
      referer: 'https://m.weibo.cn/u/$uid',
    );
    return _parseContainer(data);
  }

  Future<ContainerPage> getUserVideos(String uid, {int page = 1}) async {
    final data = await _container(
      {'type': 'uid', 'value': uid, 'containerid': '231567$uid', 'page': page},
      referer: 'https://m.weibo.cn/u/$uid',
    );
    return _parseContainer(data);
  }

  /// 相册：getImageWall 只给 mid 列表，逐条 show 取图（取前 limit 条）。
  Future<List<WbStatus>> getAlbumStatuses(String uid, {int limit = 9}) async {
    final json = await _get(WbStack.pc, '$_pcBase/ajax/profile/getImageWall',
        query: {'uid': uid}, referer: 'https://weibo.com/u/$uid');
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
    final json = await _get(WbStack.pc, '$_pcBase/ajax/profile/getVideoTab',
        query: {'uid': uid}, referer: 'https://weibo.com/u/$uid');
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
        WbStack.pc, '$_pcBase/ajax/profile/getprofilevideolist',
        query: {'uid': uid, 'cursor': cursor},
        referer: 'https://weibo.com/u/$uid');
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
    final json = await _get(WbStack.pc, '$_pcBase/ajax/profile/gettinyvideo',
        query: {'uid': uid, 'cursor': cursor, 'count': 20},
        referer: 'https://weibo.com/u/$uid');
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
    final data = await _container(
      {
        'containerid': '100103type=1&q=${Uri.encodeComponent(keyword)}&t=0',
        'page_type': 'searchall',
        'page': page,
      },
      referer: 'https://m.weibo.cn/search',
    );
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
    final json = await _get(WbStack.pc, '$_pcBase/ajax/side/search',
        query: {'q': q, 'page': 1});
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
    final data = await _container(
      {
        'containerid':
            '231522type=1&q=${Uri.encodeComponent('#$topic#')}',
        'page': page,
      },
      referer: 'https://m.weibo.cn/search',
    );
    return _parseContainer(data);
  }

  // ---------------- 主页精选 / 文章 ----------------

  final Map<String, String> _featuredItemIds = {};

  /// 精选容器 230283{uid} 根只回异步卡，须再用其 itemid 调 getItem
  /// （响应为 JSONP 括号包裹）。访客实测两步均可读。
  Future<ContainerPage> getUserFeatured(String uid, {int page = 1}) async {
    var itemid = _featuredItemIds[uid];
    if (itemid == null) {
      final data = await _container(
        {'type': 'uid', 'value': uid, 'containerid': '230283$uid', 'page': 1},
        referer: 'https://m.weibo.cn/u/$uid',
      );
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
    final body = await _getRaw(WbStack.m, '$_mBase/api/container/getItem',
        query: {'itemid': itemid, 'page': page},
        referer: 'https://m.weibo.cn/u/$uid');
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
    final data = await _container(
      {
        'type': 'uid',
        'value': uid,
        'containerid': '231912${uid}_-_ordinary',
        'page': page,
      },
      referer: 'https://m.weibo.cn/u/$uid',
    );
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
      final json =
          await _get(WbStack.pc, '$_pcBase/ajax/statuses/config');
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
      query: {
        'playlist_id': playlistId,
        if (cursor != 0) 'cursor': cursor,
      },
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
    final json = await _get(WbStack.pc, '$_pcBase/ajax/profile/albumlist',
        query: {'uid': uid});
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
    final data = await _container(
      {
        'containerid': pick.containerid,
        'background': 'ffffff',
        'page': 1,
      },
      referer: 'https://m.weibo.cn/u/$uid',
    );
    final groups = <List<WbPic>>[];
    void walk(Map<String, dynamic> card) {
      final picsRaw = _asList(card['pics']);
      if (picsRaw.isNotEmpty) {
        final pics = <WbPic>[];
        for (final p in picsRaw) {
          final pm = _asMap(p);
          String u(String k) => '${pm[k] ?? ''}'.replaceFirst('http://', 'https://');
          final big = u('pic_big');
          final original = u('pic_mw2000');
          pics.add(WbPic(
            pid: '${pm['pic_id'] ?? ''}',
            thumbnail: u('pic_small'),
            bmiddle: u('pic_middle'),
            large: big,
            original: original.isNotEmpty ? original : big,
          ));
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
}
