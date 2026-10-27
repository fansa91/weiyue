import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:weiyue/core/theme.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/settings_service.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

/// 构造测试用 WbStatus
WbStatus makeStatus({
  String id = '1001',
  String text = '这是一条测试微博',
  String authorName = '测试博主',
  int authorId = 42,
  int pics = 0,
  bool video = false,
  bool isLongText = false,
  WbStatus? retweeted,
  int reposts = 3,
  int comments = 5,
  int attitudes = 9,
}) {
  return WbStatus(
    id: id,
    mblogid: 'AbC$id',
    user: WbUser(
      id: authorId,
      screenName: authorName,
      avatar: 'https://example.com/avatar.jpg',
      verified: true,
      verifiedType: 0,
      followersCount: 12345,
      friendsCount: 100,
      statusesCount: 999,
      description: '简介一句话',
      coverImagePhone: 'https://example.com/cover.jpg',
    ),
    text: text,
    createdAt: DateTime(2026, 10, 26, 13, 9),
    createdAtRaw: 'Mon Oct 26 13:09:19 +0800 2026',
    source: '测试客户端',
    repostsCount: reposts,
    commentsCount: comments,
    attitudesCount: attitudes,
    pics: [
      for (var i = 0; i < pics; i++)
        WbPic(
          pid: 'pid$i',
          thumbnail: 'https://example.com/t$i.jpg',
          bmiddle: 'https://example.com/m$i.jpg',
          large: 'https://example.com/l$i.jpg',
        ),
    ],
    video: video
        ? const WbVideo(
            cover: 'https://example.com/vcover.jpg',
            durationSec: 703,
            onlineUsers: '15.4万次观看',
            playbackList: [
              WbPlayback(
                  label: 'mp4_720p',
                  width: 1280,
                  height: 720,
                  url: 'https://example.com/v720.mp4',
                  bitrate: 1158368),
              WbPlayback(
                  label: 'mp4_hd',
                  width: 852,
                  height: 480,
                  url: 'https://example.com/v480.mp4',
                  bitrate: 605066),
            ],
          )
        : null,
    isLongText: isLongText,
    retweeted: retweeted,
  );
}

class FakeVisitorService extends VisitorService {
  bool has;
  int refreshCalls = 0;
  FakeVisitorService({this.has = true});

  static const _identity = VisitorIdentity('TESTSUB', 'TESTSUBP', 1793000000000);

  @override
  VisitorIdentity? identityOf(WbStack stack) => has ? _identity : null;

  @override
  bool hasIdentity(WbStack stack) => has;

  @override
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async =>
      _identity;

  @override
  Future<VisitorIdentity> refresh(WbStack stack) async {
    refreshCalls++;
    return _identity;
  }

  @override
  Future<void> refreshAll() async {}
}

class FakeWeiyueService extends WeiyueService {
  FakeWeiyueService() : super(FakeVisitorService());

  bool failFeed = false;
  List<WbStatus> feedItems = [
    makeStatus(id: '1', text: '热门第一条'),
    makeStatus(id: '2', text: '热门第二条带图', pics: 2),
  ];

  @override
  Future<({List<WbChannel> mine, List<WbChannel> recommended})>
      getChannels() async => (
            mine: const [
              WbChannel(gid: '102803', title: '热门', containerid: '102803'),
              WbChannel(
                  gid: '1028034188',
                  title: '社会',
                  containerid: '102803_ctg1_4188_-_ctg1_4188'),
              WbChannel(
                  gid: '1028032088',
                  title: '科技',
                  containerid: '102803_ctg1_2088_-_ctg1_2088'),
            ],
            recommended: const <WbChannel>[],
          );

  @override
  Future<HotPage> getHotTimeline(WbChannel channel,
      {int maxId = 0, int freshIdx = 1}) async {
    if (failFeed) throw const WeiyueException('网络错误：连接超时');
    return HotPage(statuses: feedItems, maxId: 0, freshIdx: freshIdx);
  }

  @override
  Future<({HotWord? gov, List<HotWord> words})> getHotSearch() async => (
        gov: const HotWord(word: '#置顶话题#', num: 99999, label: '热'),
        words: const [
          HotWord(word: '热搜第一条', num: 11459803, realpos: 1, label: '爆'),
          HotWord(word: '热搜第二条', num: 2175539, realpos: 2, label: ''),
        ],
      );

  @override
  Future<List<BandItem>> getBand(String segment) async => const [
        BandItem(word: '娱乐热词一', num: 1233572, realpos: 1, category: '剧集'),
      ];

  @override
  Future<WbStatus> getStatus(String id) async =>
      makeStatus(id: id, text: '详情全文内容', comments: 122, attitudes: 881);

  @override
  Future<String> getLongText(String id) async => '';

  @override
  Future<({List<WbComment> comments, int total, int maxId})> getComments(
          String id,
          {required String authorUid,
          int maxId = 0}) async =>
      (
        comments: [
          WbComment(
            id: 'c1',
            user: makeStatus().user,
            text: '这是一条热评',
            createdAtRaw: 'Mon Oct 26 13:15:08 +0800 2026',
            source: '来自 湖南',
            likeCount: 12,
          ),
        ],
        total: 122,
        maxId: 0,
      );

  @override
  Future<({List<WbAttitude> items, int total})> getAttitudes(String id,
          {int page = 1}) async =>
      (
        items: [
          WbAttitude(id: 'a1', user: makeStatus().user, createdAtRaw: '刚刚'),
        ],
        total: 881,
      );

  @override
  Future<List<WbStatus>> getRelatedVideos(String mid, {int page = 1}) async =>
      const [];

  @override
  Future<WbUser> getProfileInfo(String uid) async => WbUser(
        id: int.tryParse(uid) ?? 42,
        screenName: '测试博主',
        avatar: 'https://example.com/avatar.jpg',
        verified: true,
        verifiedType: 0,
        description: '简介一句话',
        followersCount: 12345,
        friendsCount: 100,
        statusesCount: 999,
        coverImagePhone: 'https://example.com/cover.jpg',
      );

  @override
  Future<Map<String, dynamic>> getProfileDetail(String uid) async => const {};

  @override
  Future<ContainerPage> getUserStatuses(String uid, {int page = 1}) async =>
      ContainerPage(
          statuses: page == 1 ? [makeStatus(id: 'u1', text: '主页微博一')] : [],
          total: 999,
          nextPage: page + 1);

  @override
  Future<ContainerPage> getUserVideos(String uid, {int page = 1}) async =>
      ContainerPage(
          statuses:
              page == 1 ? [makeStatus(id: 'v1', text: '主页视频一', video: true)] : [],
          total: 10,
          nextPage: page + 1);

  @override
  Future<List<WbStatus>> getAlbumStatuses(String uid, {int limit = 9}) async =>
      const [];

  @override
  Future<List<WbPlaylist>> getVideoTab(String uid) async => const [
        WbPlaylist(id: 'p1', name: '测试合集', itemCount: 36),
      ];

  @override
  Future<SearchSuggest> getSearchSuggest(String q) async =>
      const SearchSuggest();

  @override
  Future<ContainerPage> getTopicStatuses(String topic, {int page = 1}) async =>
      ContainerPage(
          statuses:
              page == 1 ? [makeStatus(id: 't1', text: '话题帖子一')] : const [],
          total: 100,
          nextPage: page + 1);

  @override
  Future<ContainerPage> getUserFeatured(String uid, {int page = 1}) async =>
      ContainerPage(
          statuses:
              page == 1 ? [makeStatus(id: 'f1', text: '精选帖子一')] : const [],
          total: 100,
          nextPage: page + 1);

  @override
  Future<ContainerPage> getUserArticles(String uid, {int page = 1}) async =>
      ContainerPage(
          statuses:
              page == 1 ? [makeStatus(id: 'a1', text: '文章帖子一')] : const [],
          total: 5,
          nextPage: page + 1);

  @override
  Future<({List<WbStatus> statuses, int nextCursor})> getVideoAlbum(
          String playlistId,
          {int cursor = 0}) async =>
      (
        statuses: [makeStatus(id: 'e1', text: '合集单集一', video: true)],
        nextCursor: -1,
      );

  @override
  Future<List<WbAlbum>> getAlbums(String uid) async => const [];

  @override
  Future<List<List<WbPic>>> getAlbumPhotoGroups(String uid) async => const [];

  @override
  Future<String?> getLiveStreamUrl(String liveId) async => null;

  @override
  Future<Map<String, String>> getEmoticonMap() async => const {};
}

/// 假 Dio adapter：记录请求并按 handler 返回。
class FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final Future<ResponseBody> Function(RequestOptions options) handler;

  FakeAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final opt = options;
    requests.add(opt);
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    return handler(opt);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object body, {int status = 200}) {
  return ResponseBody.fromString(
    body is String ? body : jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );
}

/// 测试用 MaterialApp 包裹：注入假服务 + SettingsService + 模板主题。
Widget wrapWithProviders(
  Widget child, {
  FakeWeiyueService? weibo,
  FakeVisitorService? visitor,
  SettingsService? settings,
}) {
  final wb = weibo ?? FakeWeiyueService();
  final vs = visitor ?? FakeVisitorService();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<VisitorService>.value(value: vs),
      Provider<WeiyueService>.value(value: wb),
      ChangeNotifierProvider<SettingsService>(
          create: (_) => settings ?? SettingsService()),
    ],
    child: MaterialApp(
      theme: buildTheme(
          brightness: Brightness.light, seedColor: const Color(0xFFE6162D)),
      home: child,
    ),
  );
}
