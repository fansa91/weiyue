import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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

  /// 非 JSON 响应正文指纹（纯函数）：服务端回网页（HTML）而非接口
  /// JSON 时，从正文里提取人类可读线索，让报错与诊断记录能直接
  /// 看出「那页是什么」。优先 <title> 文本；无 title 时按关键词
  /// 归类（登录/验证/安全/微博）；都没有回 'HTML'，空正文回
  /// '空正文'。指纹只来自服务端公开错误页文本，绝不含请求数据、
  /// Cookie 或令牌；文本做控制字符清洗、空白折叠与 40 字截断。
  static String bodyFingerprint(String body) {
    if (body.trim().isEmpty) return '空正文';
    final title = RegExp(
      r'<title[^>]*>([\s\S]*?)</title>',
      caseSensitive: false,
    ).firstMatch(body);
    if (title != null) {
      final text = _cleanFingerprintText(
        title.group(1)!.replaceAll(RegExp(r'<[^>]*>'), ' '),
      );
      if (text.isNotEmpty) return '网页标题：$text';
    }
    final lower = body.toLowerCase();
    const keywordGroups = <List<String>>[
      ['登录', 'login', 'passport', 'sso'],
      ['验证', 'captcha', 'verify'],
      ['安全', 'security'],
      ['微博', 'weibo'],
    ];
    const labels = ['登录', '验证', '安全', '微博'];
    for (var i = 0; i < keywordGroups.length; i++) {
      if (keywordGroups[i].any(lower.contains)) {
        return '关键词：${labels[i]}';
      }
    }
    return 'HTML';
  }

  /// 指纹文本清洗：去控制字符、折叠空白、按 rune 截断 40 字。
  static String _cleanFingerprintText(String s) {
    final noCtrl = s.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');
    final collapsed = noCtrl.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = collapsed.runes;
    if (runes.length <= 40) return collapsed;
    return String.fromCharCodes(runes.take(40));
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
  ///
  /// PC 栈还必须带 `Accept: application/json, text/plain, */*`
  /// （网页端 axios 的默认值，dio 默认不发 Accept）：消息族的
  /// /ajax/message/msgList 与 /ajax/message/summary 按 Accept 做
  /// 内容协商，缺此头（或只有 */*）时服务端回 HTTP 200 的通用
  /// HTML 404 页（<title>404错误</title>）而非 JSON——2026-11-10
  /// 真机消息中心全页签报「非 JSON（网页标题 404）」即此故；
  /// 2026-11-11 线上对照实证（访客 Cookie + Referer 不变，只变
  /// Accept：带 → 回 JSON，不带 → 回 404 网页；同族 cmt /
  /// attitudes / mentions 不协商、与此头无关）。现行主包
  /// （weibo-pro-next）消息模块与 2026-10 捕获逐字一致，调用点
  /// 未变，差异只在此头。
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
    if (stack == WbStack.pc) {
      headers['Accept'] = 'application/json, text/plain, */*';
    }
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
      throw WeiyueException(
        '接口返回非 JSON（HTTP $status，${bodyFingerprint(rawBody)}）',
      );
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
  /// 解码失败（服务端回了网页 HTML 等）抛带正文指纹的
  /// WeiyueException，不再让裸 FormatException 冒出去。
  static Map<String, dynamic> _decodeJsonp(String body) {
    var t = body.trim();
    if (t.startsWith('(') && t.endsWith(')')) {
      t = t.substring(1, t.length - 1);
    }
    final dynamic d;
    try {
      d = jsonDecode(t);
    } on FormatException {
      throw WeiyueException('接口返回非 JSON（${bodyFingerprint(body)}）');
    }
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

  /// 关注分组 gid 缓存（unreadHint 的 group_ids 参数用）：会话内
  /// 成功拉到一次即缓存；失败/为空不缓存，下次调用可重试。
  List<String>? _followGroupGidsCache;

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

  /// 取关注分组 gid 列表（unreadHint 的 group_ids 参数来源）：
  /// GET /ajax/feed/allGroups 的 groups 分段中，group_type==0 的是
  /// 登录侧关注分组段（默认分组/我的分组/订阅分组，样本
  /// pc_allGroups 实证），group_type==1 的两段是频道（我的频道/
  /// 频道推荐）；取舍按段类型走，再以条目 type!=8888 双保险，
  /// 频道 gid 绝不混入。段缺 group_type 时靠条目 type 兜底判断。
  Future<List<String>> _followGroupGids() async {
    final cached = _followGroupGidsCache;
    if (cached != null) return cached;
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/feed/allGroups',
      query: {'is_new_segment': 1, 'fetch_hot': 1},
    );
    final gids = <String>[];
    final seen = <String>{};
    for (final seg in _asList(json['groups'])) {
      final sm = _asMap(seg);
      final gt = sm['group_type'];
      if (gt != null && _intOf(gt) != 0) continue; // 频道段整段跳过
      for (final item in _asList(sm['group'])) {
        final im = _asMap(item);
        if ('${im['type'] ?? ''}' == '8888') continue; // 频道条目双保险
        final gid = '${im['gid'] ?? ''}'.trim();
        if (gid.isEmpty || gid == 'null' || !seen.add(gid)) continue;
        gids.add(gid);
      }
    }
    if (gids.isNotEmpty) _followGroupGidsCache = gids;
    return gids;
  }

  /// 关注分组缓存（分组流入口用，含组名）：同 [_followGroupGids]
  /// 的取舍规则（group_type==0 段、条目 type!=8888），会话内成功
  /// 拉到一次即缓存；失败/为空不缓存，下次可重试。
  List<WbFollowGroup>? _followGroupsCache;

  /// 关注分组列表（首页分组流入口）：allGroups 关注分组段的条目，
  /// 每条 {gid, title}。其中「全部关注」（gid 前缀 10001）与首页
  /// 既有「关注」频道同源（friendstimeline list_id=10001），
  /// 不重复列出。未登录/无分组/拉取失败都返回空列表（入口不出现）。
  Future<List<WbFollowGroup>> getFollowGroups() async {
    final cached = _followGroupsCache;
    if (cached != null) return cached;
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax/feed/allGroups',
      query: {'is_new_segment': 1, 'fetch_hot': 1},
    );
    final groups = <WbFollowGroup>[];
    final seen = <String>{};
    for (final seg in _asList(json['groups'])) {
      final sm = _asMap(seg);
      final gt = sm['group_type'];
      if (gt != null && _intOf(gt) != 0) continue; // 频道段整段跳过
      for (final item in _asList(sm['group'])) {
        final im = _asMap(item);
        if ('${im['type'] ?? ''}' == '8888') continue; // 频道条目双保险
        final gid = '${im['gid'] ?? ''}'.trim();
        if (gid.isEmpty || gid == 'null' || !seen.add(gid)) continue;
        if (gid.startsWith('10001')) continue; // 全部关注：与关注频道同源
        final title = '${im['title'] ?? ''}'.trim();
        groups.add(
          WbFollowGroup(gid: gid, title: title.isEmpty ? '分组' : title),
        );
      }
    }
    if (groups.isNotEmpty) _followGroupsCache = groups;
    return groups;
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

  /// 分类搜索一页（2026-11-12 访客探针实证，见 WEIBO_API「搜索分类页签
  /// 探针」）：与综合同一容器形态，只换 containerid 的 type 值。
  /// - 实时(61)/图片(63)：纯 card_type=9 微博卡，递归 walk 收集 mblog；
  /// - 视频(64)：分组卡里的 card_type=9 子卡（带 page_info 可播视频）+
  ///   顶层微博卡；86/42 等专卡/标题卡没有 mblog，自然跳过；
  /// - 用户(3)：分组卡内 card_type=10 的完整 user 对象；
  /// - 话题(38)/超话(98)：分组卡内 card_type=8 条目。
  /// 分页：cardlistInfo.page 是下一页序号；访客态专属分类第 2 页会被
  /// 302 跳登录（_get 抛非 JSON 异常），调用方应静默按没有更多处理。
  Future<SearchCategoryPage> searchCategory(
    String keyword,
    SearchCategory category, {
    int page = 1,
  }) async {
    final data = await _container({
      'containerid':
          '100103type=${category.type}&q=${Uri.encodeComponent(keyword)}&t=0',
      'page_type': 'searchall',
      'page': page,
    }, referer: 'https://m.weibo.cn/search');
    final info = _asMap(data['cardlistInfo']);
    final users = <WbUser>[];
    final statuses = <WbStatus>[];
    final topics = <WbTopicEntry>[];
    final seenUsers = <int>{};
    final seenStatuses = <String>{};

    void walk(Map<String, dynamic> card) {
      final typeRaw = card['card_type'];
      final cardType = typeRaw is num
          ? typeRaw.toInt()
          : int.tryParse('$typeRaw') ?? 0;
      if (category.isTopicLike && cardType == 8) {
        final entry = WbTopicEntry.fromJson(card);
        if (entry.title.isNotEmpty) topics.add(entry);
      }
      final mblog = _asMap(card['mblog']);
      if (mblog.isNotEmpty) {
        final s = WbStatus.fromJson(mblog);
        if (s.id.isNotEmpty && seenStatuses.add(s.id)) statuses.add(s);
      }
      final user = _asMap(card['user']);
      if (user.isNotEmpty) {
        final u = WbUser.fromJson(user);
        if (u.id > 0 && seenUsers.add(u.id)) users.add(u);
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
    return SearchCategoryPage(
      statuses: statuses,
      users: users,
      topics: topics,
      total: totalRaw is num ? totalRaw.toInt() : 0,
      nextPage: pageRaw is num ? pageRaw.toInt() : 0,
    );
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

  // ---------------- 超话 ----------------

  /// 超话帖子流：m 容器 100808{page_id}（page_id 整串即容器 id，
  /// 与搜索超话条目 scheme 的 containerid 同值），翻页规则同话题页。
  Future<ContainerPage> getSuperTopicStatuses(
    String pageId, {
    int page = 1,
  }) async {
    final data = await _container({
      'containerid': pageId,
      'page': page,
    }, referer: 'https://m.weibo.cn/p/index?containerid=$pageId');
    return _parseContainer(data);
  }

  /// 超话页状态：GET /ajax_proxy/chaohua/page/extend（2026-11-12
  /// 主包 chaohua 模块 fetchExtendData 逐字实证：参数 {page_id,
  /// show_recommend:1}，响应字段 is_followed / follow_btn_text /
  /// is_checked 直接挂在响应体上）。访客态字段可能缺失，按未关注/
  /// 未签到防御解析；失败原样上抛，调用方决定是否展示按钮区。
  Future<SuperTopicState> getSuperTopicState(String pageId) async {
    final json = await _get(
      WbStack.pc,
      '$_pcBase/ajax_proxy/chaohua/page/extend',
      query: {'page_id': pageId, 'show_recommend': 1},
      referer: 'https://weibo.com/p/$pageId',
    );
    final data = _asMap(json['data']);
    final src = (json['is_followed'] != null || json['is_checked'] != null)
        ? json
        : data;
    return SuperTopicState(
      isFollowed: src['is_followed'] == true,
      followBtnText: '${src['follow_btn_text'] ?? ''}',
      isChecked: src['is_checked'] == true,
    );
  }

  /// chaohua 族表单 POST（关注/取关/签到共用）：主包模块以裸 axios
  /// 直发 form（Content-Type + X-Requested-With 逐字），响应是
  /// {code, msg, ...} 码信封而非 ok 信封，故不走 _post。
  /// code "100003"（msg「请先登录」）→ 标记过期抛登录失效；
  /// 其余码原样返回由各方法按成功码判定。
  Future<Map<String, dynamic>> _chaohuaPost(
    String path,
    Map<String, String> form,
  ) async {
    if (!session.hasUsableCookie(WbStack.pc)) {
      session.recordLoginFailure(path, '请先登录');
      throw const WeiyueException('请先登录');
    }
    final Response<dynamic> resp;
    try {
      resp = await _pc.post<dynamic>(
        '$_pcBase$path',
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: _requestHeaders(
            WbStack.pc,
            cookie: session.cookieHeaderFor(WbStack.pc)!,
            useSession: true,
            referer: 'https://weibo.com/',
          ),
        ),
      );
    } on DioException catch (e) {
      final msg = '网络错误：${e.message ?? e.type.name}';
      session.recordLoginFailure(path, msg);
      throw WeiyueException(msg);
    }
    final data = resp.data;
    if (data is! Map) {
      final rawBody = data is String ? data : '';
      final msg =
          '接口返回非 JSON（HTTP ${resp.statusCode ?? 0}，${bodyFingerprint(rawBody)}）';
      session.recordLoginFailure(path, msg);
      throw WeiyueException(msg);
    }
    final json = _asMap(data);
    final code = '${json['code'] ?? ''}';
    final msg = _firstErrorText([json['msg']]);
    if (code == '100003' || msg == '请先登录') {
      session.markExpired();
      const m = '登录态已失效，请重新登录';
      session.recordLoginFailure(path, m);
      throw const WeiyueException(m);
    }
    return json;
  }

  /// 关注超话：POST /ajax_proxy/chaohua/page/follow（主包 chaohua
  /// 模块 pn() 逐字：表单只有 {page_id}，成功 code==100000，
  /// 回 follow_btn_text）。返回服务端给的按钮文案（可能为空）。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
  Future<String> followSuperTopic(String pageId) async {
    final json = await _chaohuaPost('/ajax_proxy/chaohua/page/follow', {
      'page_id': pageId,
    });
    if ('${json['code'] ?? ''}' != '100000') {
      throw WeiyueException(
        _firstErrorText([json['msg'], '关注失败']),
      );
    }
    return '${json['follow_btn_text'] ?? ''}';
  }

  /// 取关超话：POST /ajax_proxy/chaohua/page/unfollow（同上，
  /// 成功 code==10000——与 follow 不同码，主包逐字）。
  Future<String> unfollowSuperTopic(String pageId) async {
    final json = await _chaohuaPost('/ajax_proxy/chaohua/page/unfollow', {
      'page_id': pageId,
    });
    if ('${json['code'] ?? ''}' != '10000') {
      throw WeiyueException(
        _firstErrorText([json['msg'], '取消关注失败']),
      );
    }
    return '${json['follow_btn_text'] ?? ''}';
  }

  /// 超话签到：POST /ajax_proxy/chaohua/page/checkin（主包 chaohua
  /// 模块 nn() 逐字：表单 {scene_id:"pc_checkin", page_id, timezone,
  /// lang, plat, ua}；成功 code==100000 回 title/sub_title）。
  /// timezone/lang/plat/ua 是浏览器环境描述：客户端以本机时区名、
  /// zh-CN 与系统名尽力填充（ua 无对应物留空），核心参数
  /// scene_id/page_id 逐字。
  Future<({String title, String subTitle})> checkinSuperTopic(
    String pageId,
  ) async {
    final json = await _chaohuaPost('/ajax_proxy/chaohua/page/checkin', {
      'scene_id': 'pc_checkin',
      'page_id': pageId,
      'timezone': DateTime.now().timeZoneName,
      'lang': 'zh-CN',
      'plat': '',
      'ua': '',
    });
    if ('${json['code'] ?? ''}' != '100000') {
      throw WeiyueException(
        _firstErrorText([json['msg'], '签到失败']),
      );
    }
    return (
      title: '${json['title'] ?? ''}'.isEmpty ? '签到成功' : '${json['title']}',
      subTitle: '${json['sub_title'] ?? ''}',
    );
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

  /// 分组时间线（登录后可用）：单个关注分组的微博流。
  /// 路径与参数为 2026-11-12 主包调用点实证（formatGroup 选 api +
  /// 时间线加载器拼参）：gid 前缀 ∈ {11000,11001,11002}（最新微博等
  /// 系统分组）走 /ajax/feed/friendstimeline，参数
  /// {list_id, refresh:4, since_id, max_id, count, fid: gid}；
  /// 其余自定义分组走 /ajax/feed/groupstimeline，参数
  /// {list_id, refresh:4, max_id, fast_refresh:1, count}（无 since_id）。
  /// 响应与 friendstimeline 同形态（statuses + max_id_str/since_id
  /// 双游标），解析口径与 [getFriendsTimeline] 一致，游标原样回传。
  Future<({List<WbStatus> statuses, String maxId, String sinceId})>
  getGroupTimeline({
    required String gid,
    String maxId = '',
    String sinceId = '',
    int count = 20,
  }) async {
    final prefix = gid.length >= 5 ? gid.substring(0, 5) : gid;
    final friendsFamily = const {'11000', '11001', '11002'}.contains(prefix);
    final json = await _get(
      WbStack.pc,
      friendsFamily
          ? '$_pcBase/ajax/feed/friendstimeline'
          : '$_pcBase/ajax/feed/groupstimeline',
      query: friendsFamily
          ? {
              'list_id': gid,
              'refresh': 4,
              'since_id': sinceId,
              'max_id': maxId,
              'count': count,
              'fid': gid,
            }
          : {
              'list_id': gid,
              'refresh': 4,
              'max_id': maxId,
              'fast_refresh': 1,
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
    String cursorOf(dynamic v) {
      final s = '${v ?? ''}'.trim();
      return (s.isEmpty || s == 'null') ? '' : s;
    }

    return (
      statuses: statuses,
      maxId: cursorOf(
        json['max_id_str'] ?? data['max_id_str'] ?? json['max_id'],
      ),
      sinceId: cursorOf(json['since_id'] ?? data['since_id']),
    );
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

  /// 我赞过的（登录后可用）：GET /ajax/profile/getLikeList
  /// （2026-11-12 主包主页瀑布流调用点实证：pageType=like 时
  /// $http.get(getLikeList, {params:{uid, cursor}})），响应
  /// {ok, data:{list:[帖子对象], next_cursor, attitude_privacy,
  /// is_owner}}，cursor 从 0 起、next_cursor=-1 表示到底。
  /// 条目就是完整帖子对象（与瀑布流同解析，含 mix_media_info，
  /// WbStatus.fromJson 已覆盖）。uid 为空直接抛错（同 getMyFollowing：
  /// 空参必 400，不发请求）。服务端带错误信息回空时抛给页面展示。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
  Future<({List<WbStatus> items, int nextCursor})> getLikeList(
    String uid, {
    int cursor = 0,
  }) async {
    if (uid.trim().isEmpty) {
      throw const WeiyueException('缺少用户 ID，请先点「修复登录态」或重新检测');
    }
    try {
      final json = await _get(
        WbStack.pc,
        '$_pcBase/ajax/profile/getLikeList',
        query: {'uid': uid, 'cursor': cursor},
        referer: 'https://weibo.com/u/$uid',
      );
      final data = _asMap(json['data']);
      var raw = _asList(data['list']);
      if (raw.isEmpty) raw = _asList(json['data']);
      if (raw.isEmpty) raw = _asList(data['statuses']);
      final items = raw
          .map((e) => WbStatus.fromJson(_asMap(e)))
          .where((s) => s.id.isNotEmpty)
          .toList();
      if (items.isEmpty) {
        final msg = _firstErrorText([
          json['msg'],
          json['error'],
          data['msg'],
          data['error'],
        ]);
        final okVal = json['ok'];
        if (okVal == 0 || okVal == '0' || msg.isNotEmpty) {
          throw WeiyueException(msg.isNotEmpty ? msg : '赞列表接口返回错误（ok=0）');
        }
      }
      final nextRaw = data['next_cursor'] ?? json['next_cursor'];
      return (
        items: items,
        nextCursor: nextRaw == null
            ? -1
            : (nextRaw is num
                  ? nextRaw.toInt()
                  : int.tryParse('$nextRaw') ?? -1),
      );
    } catch (e) {
      session.recordLoginFailure('/ajax/profile/getLikeList', '$e');
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
      for (final k in [typeKey, 'list', 'statuses', 'comments', 'attitudes']) {
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
        hasMore = nextSinceId.isNotEmpty ? live(nextSinceId) : live(nextMaxId);
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

  /// 消息未读汇总：GET /ajax/message/unreadHint（必带 group_ids）
  /// + /ajax/message/summary 多形态防御提取。本方法不抛错（徽标
  /// 拉取失败只记诊断、返回已提取部分或全零），避免拖垮「我的」页
  /// 与消息中心页签渲染。
  ///
  /// unreadHint 必带参数 group_ids（关注分组 gid 逗号拼接）：网页端
  /// 主包调用点实证（2026-11-10，主包原码 $http.get(unreadHint,
  /// {params:{group_ids: gids.join(",")}})，gid 来源为 allGroups
  /// 关注分组段）；缺参时服务端回 HTTP 200 的网页 HTML 非 JSON
  /// （真机实证）。分组经 [_followGroupGids] 取（会话内缓存）；
  /// 分组拉取失败或无 gid 时跳过 unreadHint 这一路——不调、
  /// 不记失败，summary 那一路照旧。
  ///
  /// 依据等级：unreadHint 的 groups 形态（[{键: 数}]）与 summary 的
  /// {summary:{topUsers/followers/field}} 形态为主包实证，但 summary
  /// 那三个数是 24 小时互动量、不是分类未读，不往分类上映射；
  /// 分类键名（mention_status/all_mention_cmt/cmt/attitude）为主包
  /// 未读状态表实证，其数值在主包里来自独立的 remind 接口——
  /// 期待它出现在 unreadHint/summary 响应里属推测防御，取不到即全零。
  ///
  /// 2026-11-12 起接入分类未读的真实来源（主包顶栏调用点实证）：
  /// jsonp GET https://rm.api.weibo.com/2/remind/push_count.json
  /// （参数与主包逐字一致，含 source=339644097），响应
  /// {code:1, data:{mention_status, all_mention_cmt, cmt, attitude,
  /// dm_total, chat_group_client, dm_pub_total, remind_settings…}}，
  /// 主包 calcMessageBadge/calcChatProUnread 即消费此 data。
  /// 本方法在既有两路吸收之后最后吸收 push_count（absorb 对正值
  /// 覆盖写，故 push_count 对同名键优先）；它失败/code!=1/无会话时
  /// 静默跳过，徽标完全回退既有逻辑，不记登录失败。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
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
      // 只在 unread 真是 Map 时才下钻：原先无条件 absorb(_asMap(null))
      // 会对空 Map 无限递归抛 Stack Overflow（被外层 catch 吞掉并误记
      // 一条失败记录，分类值因先行吸收才没受影响）。
      final unread = m['unread'];
      if (unread is Map) absorb(_asMap(unread));
    }

    List<String> gids;
    try {
      gids = await _followGroupGids();
    } catch (_) {
      gids = const []; // 分组拉取失败：跳过 unreadHint，不记失败
    }
    if (gids.isNotEmpty) {
      try {
        final hint = await _get(
          WbStack.pc,
          '$_pcBase/ajax/message/unreadHint',
          query: {'group_ids': gids.join(',')},
          referer: 'https://weibo.com/messages',
        );
        absorb(_asMap(hint['data']));
        absorb(hint);
      } catch (e) {
        session.recordLoginFailure('/ajax/message/unreadHint', '$e');
      }
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
    // 真实未读来源 push_count 最后吸收（同名键以它为准）；
    // 静默失败：拿不到就用上面两路的防御结果，徽标不消失。
    final pushData = await _pushCountData();
    if (pushData != null) absorb(pushData);
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

  /// push_count 未读数据（rm.api.weibo.com 跨域 JSONP，主包顶栏
  /// 调用点实证，2026-11-12）：参数与主包逐字一致。只许登录态
  /// （sessionOnly：不回退访客、不触发过期标记）；响应可能是
  /// 纯 JSON 或 `callback({...})` 包裹，两种都解。code==1 才认
  /// data；任何失败/异常都返回 null（调用方静默回退，不记诊断）。
  Future<Map<String, dynamic>?> _pushCountData() async {
    if (!session.hasUsableCookie(WbStack.pc)) return null;
    try {
      final body = await _getRaw(
        WbStack.pc,
        'https://rm.api.weibo.com/2/remind/push_count.json',
        query: const {
          'trim_null': 1,
          'with_dm_group': 1,
          'with_reminding': 1,
          'with_settings': 1,
          'exclude_attitude': 1,
          'with_chat_group_notice': 1,
          'source': 339644097,
          'with_chat_group': 1,
          'with_dm_unread': 1,
        },
        referer: 'https://weibo.com/',
        sessionOnly: true,
      );
      final json = _decodeJsonpLoose(body);
      if (json == null) return null;
      final code = json['code'];
      if (code != 1 && code != '1') return null;
      final data = _asMap(json['data']);
      return data.isEmpty ? null : data;
    } catch (_) {
      return null;
    }
  }

  /// 宽容 JSONP 解码：纯 JSON 直接解；`name({...})` / `({...})`
  /// 包裹时剥壳再解；解不出返回 null（不抛错，与 _decodeJsonp 的
  /// 报错口径区分：push_count 是可有可无的增强来源）。
  static Map<String, dynamic>? _decodeJsonpLoose(String body) {
    var t = body.trim();
    if (!t.startsWith('{')) {
      final open = t.indexOf('(');
      final close = t.lastIndexOf(')');
      if (open < 0 || close <= open) return null;
      t = t.substring(open + 1, close).trim();
    }
    try {
      final d = jsonDecode(t);
      return d is Map ? _asMap(d) : null;
    } on FormatException {
      return null;
    }
  }

  // ---------------- 私信（WebIM 子系统，api.weibo.com/webim） ----------------
  // 依据 WEIBO_API.md「私信」小节（2026-11-12）：网页版聊天应用
  // bundle（raw/chat_app.js）调用点逐字实证 + 访客探针。与主站
  // /ajax 族的关键差异：主机是 api.weibo.com；鉴权只靠 .weibo.com
  // 域登录 Cookie，不带 XSRF、不带 source；失败信封是
  // {error, error_code}（HTTP 200 也可能带），其中
  // error_code 21301 = 鉴权未过（访客探针实测原文
  // "auth by Null spi!"）。全部方法只许登录态：无会话直接抛
  // 「请先登录」，绝不回退访客（私信没有访客形态）。
  static const _webimBase = 'https://api.weibo.com';

  Map<String, String> _webimHeaders() => {
    'User-Agent': visitor.uaOf(WbStack.pc),
    'Referer': 'https://api.weibo.com/chat/',
    'Accept': 'application/json, text/plain, */*',
    'X-Requested-With': 'XMLHttpRequest',
    'Cookie': session.cookieHeaderFor(WbStack.pc)!,
  };

  /// WebIM 响应统一处理：解出 JSON 并把 {error} 信封翻译成
  /// WeiyueException；21301/auth 类先标记登录过期（Cookie 已被
  /// 服务端拒）。非 JSON 回正文指纹异常，与 _get 同口径。
  Map<String, dynamic> _webimJson(Response<dynamic> resp) {
    final status = resp.statusCode ?? 0;
    final data = resp.data;
    if (data is! Map) {
      final rawBody = data is String ? data : '';
      throw WeiyueException(
        '接口返回非 JSON（HTTP $status，${bodyFingerprint(rawBody)}）',
      );
    }
    final json = _asMap(data);
    final errVal = json['error'];
    final err = errVal == null ? '' : '$errVal'.trim();
    if (err.isNotEmpty) {
      final code = _intOf(json['error_code']);
      if (code == 21301 || err.toLowerCase().contains('auth')) {
        session.markExpired();
        throw const WeiyueException('登录态已失效，请重新登录');
      }
      throw WeiyueException(err);
    }
    return json;
  }

  Future<Map<String, dynamic>> _webimGet(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!session.hasUsableCookie(WbStack.pc)) {
      throw const WeiyueException('请先登录');
    }
    final Response<dynamic> resp;
    try {
      resp = await _pc.get<dynamic>(
        '$_webimBase$path',
        queryParameters: query,
        options: Options(headers: _webimHeaders()),
      );
    } on DioException catch (e) {
      throw WeiyueException('网络错误：${e.message ?? e.type.name}');
    }
    return _webimJson(resp);
  }

  /// WebIM 表单 POST（发送/标记已读）：与 _post 的差异是不要求
  /// XSRF（chat bundle 的 axios 直发表单、无此头，硬套会误伤）；
  /// 失败同样记登录诊断，与其他写操作一致。
  Future<Map<String, dynamic>> _webimPost(
    String path, {
    required Map<String, String> form,
  }) async {
    if (!session.hasUsableCookie(WbStack.pc)) {
      session.recordLoginFailure(path, '请先登录');
      throw const WeiyueException('请先登录');
    }
    final Response<dynamic> resp;
    try {
      resp = await _pc.post<dynamic>(
        '$_webimBase$path',
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: _webimHeaders(),
        ),
      );
    } on DioException catch (e) {
      final msg = '网络错误：${e.message ?? e.type.name}';
      session.recordLoginFailure(path, msg);
      throw WeiyueException(msg);
    }
    try {
      return _webimJson(resp);
    } on WeiyueException catch (e) {
      session.recordLoginFailure(path, e.message);
      rethrow;
    }
  }

  List<DmConversation> _parseDmContacts(
    Map<String, dynamic> json, {
    required bool isPublic,
    bool dropVirtual = false,
  }) {
    final out = <DmConversation>[];
    for (final e in _asList(json['contacts'])) {
      if (e is! Map) continue;
      final c = DmConversation.fromJson(_asMap(e), isPublic: isPublic);
      if (c.user.id <= 0) continue;
      // type==3 是「未关注人消息」虚拟文件夹条目：其会话内容由
      // public 族单独成列，混进 1:1 列表会点开一个假用户。
      if (dropVirtual && c.userType == 3) continue;
      out.add(c);
    }
    return out;
  }

  /// 私信会话列表：主列表（contacts）+ 未关注人列表
  /// （public/contacts）。路径/参数与 chat bundle 调用点逐字
  /// 一致（special_source=3 在路径里，count 取 50 单发；
  /// bundle 的 chatlistcount 是分段递增的组件状态，客户端简化）。
  /// public 族失败静默为空（主列表已成立时不被拖累），与
  /// getMessageSummary 的防御口径一致。
  Future<({List<DmConversation> chats, List<DmConversation> strangers})>
  getDmConversations() async {
    final json = await _webimGet(
      '/webim/2/direct_messages/contacts.json?special_source=3',
      query: const {
        'add_virtual_user': '3,4',
        'refresh_user_count': 1,
        'need_back': '0,0',
        'count': 50,
        'is_include_folder': 1,
      },
    );
    final chats = _parseDmContacts(json, isPublic: false, dropVirtual: true);
    var strangers = const <DmConversation>[];
    try {
      final pub = await _webimGet(
        '/webim/2/direct_messages/public/contacts.json',
      );
      strangers = _parseDmContacts(pub, isPublic: true);
    } catch (_) {}
    return (chats: chats, strangers: strangers);
  }

  /// 私信历史：服务端 direct_messages 首元为最新（bundle 取 [0]
  /// 作最新消息实证），这里翻转成时间升序（旧→新）返回。
  /// maxId=0 取最新一页；续拉更早传已加载最旧一条的 id。
  /// hasMore 以「整页返回」粗判，翻页回空/重复由 UI 去重兜底。
  /// notice_messages 的系统提示不进列表（网页端是把 biz_id=5
  /// 的 tip 拼成条目，形态未全证，跳过不崩）。
  Future<({List<DmMessage> messages, bool hasMore})> getDmHistory(
    String uid, {
    int maxId = 0,
    bool isPublic = false,
    int count = 20,
  }) async {
    final json = await _webimGet(
      isPublic
          ? '/webim/2/direct_messages/public/conversation.json'
          : '/webim/2/direct_messages/conversation.json',
      query: {
        'convert_emoji': 1,
        'count': count,
        'max_id': maxId,
        'uid': uid,
        'is_include_group': 0,
        'from_contacts': 1,
      },
    );
    final raw = _asList(json['direct_messages']);
    final msgs = <DmMessage>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final m = DmMessage.fromJson(_asMap(e));
      if (m.id <= 0 && m.text.isEmpty && !m.isSystem) continue;
      msgs.add(m);
    }
    return (messages: msgs.reversed.toList(), hasMore: raw.length >= count);
  }

  /// 发送私信文本：POST /webim/2/direct_messages/new.json。
  /// 表单取 chat bundle 基础发送函数（tocontact）的最小集原文
  /// {text, uid, extensions, is_encoded:0, decodetime:1}——
  /// extensions 里的 clientid 是 comet 连接层维护的运行时标识
  /// （初始空串、握手后赋值），本端不接长连接，恒传空串（与
  /// 网页端连接建立前的状态一致）。成功回新消息对象；回执
  /// 字段不全时以本地发送内容补齐正文与时间。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
  Future<DmMessage> sendDm(String uid, String text) async {
    final json = await _webimPost(
      '/webim/2/direct_messages/new.json',
      form: {
        'text': text,
        'uid': uid,
        'extensions': '{"clientid":""}',
        'is_encoded': '0',
        'decodetime': '1',
      },
    );
    final m = DmMessage.fromJson(json);
    if (m.text.isNotEmpty && m.createdAt != null) return m;
    return DmMessage(
      id: m.id,
      senderId: m.senderId,
      senderName: m.senderName,
      recipientId: m.recipientId,
      text: m.text.isNotEmpty ? m.text : text,
      createdAt: m.createdAt ?? DateTime.now(),
      type: m.type,
      mediaType: m.mediaType,
    );
  }

  /// 标记会话已读：POST set_unread_count（名字是 set，语义是清
  /// 该会话未读；bundle 在聚焦收消息时的调用点原文
  /// {type:2, uid, is_include_group:0}）。未关注人会话走
  /// public 同名接口。
  Future<void> markDmRead(String uid, {bool isPublic = false}) async {
    await _webimPost(
      isPublic
          ? '/webim/2/direct_messages/public/set_unread_count.json'
          : '/webim/2/direct_messages/set_unread_count.json',
      form: {'type': '2', 'uid': uid, 'is_include_group': '0'},
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
      final msg = '接口返回非 JSON（HTTP $status，${bodyFingerprint(rawBody)}）';
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

  /// 评论点赞：POST /ajax/statuses/updateLike（2026-11-12 主包
  /// 评论组件点赞动作实证：likeType=comment 时 body 为
  /// {object_id: 评论 idstr, object_type: "comment"}，评论的已赞
  /// 状态由其对象上的 liked/like_counts 字段表达）。
  Future<void> likeComment(String commentId) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/updateLike',
      form: {'object_id': commentId, 'object_type': 'comment'},
      referer: 'https://weibo.com/',
    );
  }

  /// 评论取消赞：POST /ajax/statuses/destroyLike（同上，同一
  /// object_id/object_type 表单）。
  Future<void> unlikeComment(String commentId) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/destroyLike',
      form: {'object_id': commentId, 'object_type': 'comment'},
      referer: 'https://weibo.com/',
    );
  }

  // ---------------- 投票 ----------------

  /// 投票/撤票的回执：新投票对象（服务端回的 vote_object），
  /// 及它自带的 error_msg（主包语义：ok>0 时 error_msg 只弹警告，
  /// vote_object 照常生效）。vote 解析不到为 null，调用方保留旧态。
  ({WbVote? vote, String? errorMsg}) _voteReceipt(Map<String, dynamic> json) {
    final obj = _asMap(json['vote_object']);
    final err = _firstErrorText([obj['error_msg']]);
    return (
      vote: obj.isEmpty ? null : WbVote.tryParse(obj),
      errorMsg: err.isEmpty ? null : err,
    );
  }

  /// 投票：POST /ajax/statuses/setVote（2026-11-12 主包 FeedVote 组件
  /// setVote 逐字实证：表单 {id: voteObject.id, vote_items: 选项 id
  /// 数组 toString（逗号拼接）, ext: "4"}；成功 ok>0 且回 vote_object）。
  /// 单选传一个 id，多选传勾选的全部 id。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
  Future<({WbVote? vote, String? errorMsg})> setVote(
    int voteId,
    List<int> itemIds,
  ) async {
    final json = await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/setVote',
      form: {
        'id': voteId,
        'vote_items': itemIds.join(','),
        'ext': '4',
      },
      referer: 'https://weibo.com/',
    );
    return _voteReceipt(json);
  }

  /// 撤回投票：POST /ajax/statuses/cancelVote（同上组件 cancelVote
  /// 逐字实证：表单只有 {id}，成功同样回 vote_object）。
  Future<({WbVote? vote, String? errorMsg})> cancelVote(int voteId) async {
    final json = await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/cancelVote',
      form: {'id': voteId},
      referer: 'https://weibo.com/',
    );
    return _voteReceipt(json);
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

  /// 收藏（创建）：POST /ajax/statuses/createFavorites，参数 id。
  /// 2026-11-10 主包调用点实证（setFavorited）：创建/取消同族，
  /// 按 newFavorited 在 createFavorites/destoryFavorites 间切换、同发 {id}。
  /// 此前推测的 /ajax/favorites/create 不存在（真机回非 JSON HTTP 200）。
  Future<void> createFavorite(String id) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/createFavorites',
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
  /// 参数 2026-11-10 主包调用点实证：只发 {friend_uid: 对方uid字符串}
  /// （page/followcardid/mark 为可选附加项，不发）。此前同发
  /// friend_id+uid 真机回非 JSON HTTP 400。
  Future<void> followUser(String uid) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/friendships/create',
      form: {'friend_uid': uid},
      referer: 'https://weibo.com/u/$uid',
    );
  }

  /// 取关：POST /ajax/friendships/destory（文档原文拼写）。
  /// 参数 2026-11-10 主包调用点实证：只发 {uid: 对方uid字符串}。
  Future<void> unfollowUser(String uid) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/friendships/destory',
      form: {'uid': uid},
      referer: 'https://weibo.com/u/$uid',
    );
  }

  /// 删自己的评论：POST /ajax/statuses/destroyComment（文档清单原文）。
  /// 参数 2026-11-10 主包调用点实证：{cid: 评论id}（主包同发的一个
  /// filter 是评论列表的筛选视图状态，与删除语义无关，不发）。
  Future<void> deleteComment(String cid) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/destroyComment',
      form: {'cid': cid},
    );
  }

  /// 屏蔽/拉黑用户：POST /ajax/statuses/filterUser（2026-11-12
  /// 主包六处调用点实证，参数逐字：{uid, status, interact, follow}
  /// 三个 0/1 开关，个别调用点另带 screen_name）。主包对话框口径：
  /// 「设置对@昵称 的屏蔽范围，全选即为拉黑用户」——status=不看TA
  /// 的微博、interact=禁止TA与我互动、follow=禁止TA关注我，
  /// 三项默认全开；成功（ok>0）后主包提示「已拉黑」（全开时）或
  /// 「已屏蔽」并置本地 block=true。本方法不做取消屏蔽（主包解除
  /// 走设置页列表批量接口，形态不同，未实证到单用户解除调用）。
  Future<void> filterUser({
    required String uid,
    String screenName = '',
    bool blockStatuses = true,
    bool blockInteract = true,
    bool blockFollow = true,
  }) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/filterUser',
      form: {
        'uid': uid,
        if (screenName.isNotEmpty) 'screen_name': screenName,
        'status': blockStatuses ? 1 : 0,
        'interact': blockInteract ? 1 : 0,
        'follow': blockFollow ? 1 : 0,
      },
      referer: 'https://weibo.com/u/$uid',
    );
  }

  /// 删自己的帖子：POST /ajax/statuses/destroy（文档清单原文）。
  /// 参数 {id}（主包 destroyWB 调用点实证：{id: idstr/ori_mid}）。
  Future<void> deleteStatus(String id) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/destroy',
      form: {'id': id},
      referer: _detailReferer(id),
    );
  }

  /// 发帖（纯文字/带图）：POST /ajax/statuses/update，走 _post 写通道。
  /// 表单逐字对齐主包发布器 toolbarPublish 的组装
  /// （`{content, pic_id: handlePic(), visible, share_id, media, vote}`
  /// 经 qs.stringify 表单编码）：无媒体/投票/分享时 media/vote/share_id
  /// 恒为空串、visible 恒 0（公开）；
  /// pic_id 无图时为空串，有图时是 handlePic 的 JSON 串——数组元素
  /// `{type, media_id, pid, short_url, media_group_id}`，其中普通上传图
  /// 只有 type（文件 MIME）与 pid 有值，其余键在网页端为 undefined
  /// 被 JSON.stringify 丢弃，故这里只组装 type+pid 两键（顺序同主包）。
  /// ⚠️ 登录态行为未经真实账号实测，待用户真机验证。
  Future<void> publishStatus(
    String content, {
    List<({String pid, String type})> pics = const [],
  }) async {
    await _post(
      WbStack.pc,
      '$_pcBase/ajax/statuses/update',
      form: {
        'content': content,
        'pic_id': pics.isEmpty
            ? ''
            : jsonEncode([
                for (final p in pics) {'type': p.type, 'pid': p.pid},
              ]),
        'visible': 0,
        'share_id': '',
        'media': '',
        'vote': '',
      },
      referer: 'https://weibo.com/',
    );
  }

  /// 标准 CRC32（IEEE 多项式，与主包 b_crc32 同算法：初值/终值
  /// 0xFFFFFFFF，结果取无符号 32 位整数）。上传参数 cs 用它的
  /// 十进制字符串形态（主包把返回值直接交给 qs.stringify）。
  static int crc32OfBytes(List<int> bytes) {
    final table = _crc32Table ??= _buildCrc32Table();
    var c = 0xFFFFFFFF;
    for (final b in bytes) {
      c = (c >>> 8) ^ table[(c ^ b) & 0xFF];
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static List<int>? _crc32Table;

  static List<int> _buildCrc32Table() {
    final table = List<int>.filled(256, 0);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      table[n] = c & 0xFFFFFFFF;
    }
    return table;
  }

  /// picupload 上传失败 errno → 文案（主包 UploadExpection 错误表原文，
  /// 取常见项；未列出的只报编号）。
  static const _uploadErrnoMessages = <int, String>{
    1: '用户未登录',
    2: '上传数据无效',
    3: '回调地址无效',
    4: '未找到上传文件',
    5: '无权上传',
    6: '上传uid无效',
    7: '未指定返回信息类型',
    8: '上传数据出错',
    9: '上传MIME类型不支持',
    10: '上传文件大小无效',
    11: '存储出错',
    12: '上传EXIF信息过长',
    13: '上传回调出错',
    14: '回调返回出错',
    15: '错误的请求',
    -1: '没有登录',
    -2: '没有收到POST数据',
    -3: '没有指定cb参数',
    -4: '没有发现提交上传文件',
    -5: '该app没有开放图片上传服务',
    -6: 'uid非法',
    -7: '参数s值不支持',
    -8: '数据上传失败',
    -9: '文件mime类型不支持',
    -10: '文件字节数超过限制',
    -11: '存储错误',
    -12: '图片exif信息超长(2k)',
  };

  static const _picUploadUrl =
      'https://picupload.weibo.com/interface/upload.php';

  /// 图片上传（发帖配图）：返回服务端 pid。
  ///
  /// 形态逐字对齐主包 uploadWithFile$3 在发布器图片组件的调用
  /// （`uploadWithFile$3(file, {pri: 0}, /*分流标志*/ 1, /*source*/ 1)`，
  /// 走 upload.php 分支）：
  /// - POST https://picupload.weibo.com/interface/upload.php，
  ///   查询参数（顺序同主包对象字面量）：file_source=1、
  ///   cs=图片字节的 CRC32（无符号十进制）、ent=miniblog、
  ///   appid=339644097、uid=当前登录 uid、raw_md5=字节 MD5 十六进制、
  ///   ori=1、pri=0、request_id=毫秒时间戳、file_size=字节数；
  ///   主包另在用户开启水印时带 mpos/nick（取自页面配置的水印设置，
  ///   本端无从得知，不带）；
  /// - 请求体是图片原始字节，Content-Type: application/octet-stream；
  /// - 网页端为此另起 axios 实例：**显式删掉 X-Requested-With、
  ///   不带 X-Xsrf-Token**（xsrfCookieName 置空），只靠 Cookie 登录态
  ///   ——故本方法不复用 _post/_requestHeaders，只组装 Cookie/UA/
  ///   Referer 三个头；无登录会话时与 _post 同口径本地拦截不发请求，
  ///   但不要求 XSRF 令牌（上传链路本身不用它）；
  /// - 成功响应 `{ret: 真值, pic: {pid}}` 取 pid；失败
  ///   `{ret: false, errno}` 按主包错误表抛「上传图片失败：…（errno）」。
  /// ⚠️ 登录态上传无法在本机实测（纪律：不用真实账号），待真机验证。
  Future<String> uploadPicture(List<int> bytes) async {
    const path = '/interface/upload.php';
    if (!session.hasUsableCookie(WbStack.pc)) {
      session.recordLoginFailure(path, '请先登录');
      throw const WeiyueException('请先登录');
    }
    final uid = session.uid;
    final query = <String, String>{
      'file_source': '1',
      'cs': '${crc32OfBytes(bytes)}',
      'ent': 'miniblog',
      'appid': '339644097',
      if (uid.isNotEmpty) 'uid': uid,
      'raw_md5': md5.convert(bytes).toString(),
      'ori': '1',
      'pri': '0',
      'request_id': '${DateTime.now().millisecondsSinceEpoch}',
      'file_size': '${bytes.length}',
    };
    final url = Uri.parse(_picUploadUrl).replace(queryParameters: query);
    final Response<dynamic> resp;
    try {
      resp = await _pc.post<dynamic>(
        url.toString(),
        data: Uint8List.fromList(bytes),
        options: Options(
          contentType: 'application/octet-stream',
          sendTimeout: const Duration(minutes: 2),
          receiveTimeout: const Duration(minutes: 2),
          headers: {
            'User-Agent': visitor.uaOf(WbStack.pc),
            'Referer': 'https://weibo.com/',
            'Cookie': session.cookieHeaderFor(WbStack.pc)!,
          },
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
    if (data is Map) {
      json = _asMap(data);
    } else if (data is String && data.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) json = _asMap(decoded);
      } on FormatException {
        json = null;
      }
    }
    final location = resp.headers.value('location') ?? '';
    final rawBody = data is String ? data : '';
    if (_notLoggedInSignal(status, json, location, rawBody)) {
      session.markExpired();
      const msg = '登录态已失效，请重新登录';
      session.recordLoginFailure(path, msg);
      throw const WeiyueException(msg);
    }
    if (json == null) {
      final msg = '接口返回非 JSON（HTTP $status，${bodyFingerprint(rawBody)}）';
      session.recordLoginFailure(path, msg);
      throw WeiyueException(msg);
    }
    final ret = json['ret'];
    if (ret == false || ret == 0 || ret == 'false') {
      final errno = _intOf(json['errno']);
      final text = _uploadErrnoMessages[errno];
      final msg = text != null ? '上传图片失败：$text（$errno）' : '上传图片失败（错误码 $errno）';
      session.recordLoginFailure(path, msg);
      throw WeiyueException(msg);
    }
    final pic = _asMap(json['pic']);
    final pid = '${pic['pid'] ?? ''}';
    if (pid.isEmpty) {
      const msg = '上传图片失败：服务器未返回图片 id';
      session.recordLoginFailure(path, msg);
      throw const WeiyueException(msg);
    }
    return pid;
  }
}
