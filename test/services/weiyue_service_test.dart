import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/visitor_service.dart';
import 'package:weiyue/services/weiyue_service.dart';

import '../helpers/fakes.dart';

/// 计数版假 Visitor：ensure 直回固定身份，refresh 计数。
class CountingVisitor extends VisitorService {
  int refreshCalls = 0;
  static const _id = VisitorIdentity('VSUB', 'VSUBP', 1793000000000);

  @override
  Future<VisitorIdentity> ensure(WbStack stack, {bool force = false}) async =>
      _id;

  @override
  Future<VisitorIdentity> refresh(WbStack stack) async {
    refreshCalls++;
    return _id;
  }
}

Dio _dio(FakeAdapter adapter) {
  final dio = Dio(BaseOptions(
    followRedirects: false,
    validateStatus: (s) => s != null && s < 500,
    responseType: ResponseType.json,
  ));
  dio.httpClientAdapter = adapter;
  return dio;
}

const _channel = WbChannel(
  gid: '1028034188',
  title: '社会',
  containerid: '102803_ctg1_4188_-_ctg1_4188',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hottimeline 参数拼装：group_id/containerid/分页', () async {
    final visitor = CountingVisitor();
    final adapter = FakeAdapter((opt) async => jsonBody({
          'ok': 1,
          'statuses': [
            {
              'id': '11',
              'text_raw': '社会新闻一则',
              'user': {'id': 1, 'screen_name': '某报'},
            },
          ],
          'max_id': 555,
          'fresh_idx': 2,
        }));
    final svc = WeiyueService(visitor, pcDio: _dio(adapter));

    final page = await svc.getHotTimeline(_channel, maxId: 3, freshIdx: 4);

    expect(page.statuses.length, 1);
    expect(page.statuses.first.text, '社会新闻一则');
    expect(page.maxId, 555);
    final q = adapter.requests.single.queryParameters;
    expect(adapter.requests.single.uri.path, '/ajax/feed/hottimeline');
    expect(q['group_id'], '1028034188');
    expect(q['containerid'], '102803_ctg1_4188_-_ctg1_4188');
    expect(q['max_id'], 3);
    expect(q['fresh_idx'], 4);
    expect(q['count'], 10);
    expect(q['extparam'], 'discover|new_feed');
    // Cookie 头已带上访客
    final cookie = adapter.requests.single.headers.entries
        .firstWhere((e) => e.key.toLowerCase() == 'cookie')
        .value;
    expect(cookie, 'SUB=VSUB; SUBP=VSUBP');
    expect(visitor.refreshCalls, 0);
  });

  test('m 搜索参数拼装与 cards 解析（真实 fixture 回放）', () async {
    final visitor = CountingVisitor();
    final searchJson =
        File('test/fixtures/m_search.json').readAsStringSync();
    final adapter = FakeAdapter((opt) async => jsonBody(searchJson));
    final svc = WeiyueService(visitor, mDio: _dio(adapter));

    final result = await svc.search('新华社');

    final q = adapter.requests.single.queryParameters;
    expect(adapter.requests.single.uri.path, '/api/container/getIndex');
    expect(q['containerid'], contains('100103type=1'));
    expect(q['containerid'], contains('q=%E6%96%B0%E5%8D%8E%E7%A4%BE'));
    expect(q['page_type'], 'searchall');
    // card_group 用户 1（新华社），微博多条
    expect(result.users.length, 1);
    expect(result.users.first.screenName, '新华社');
    expect(result.statuses.length, greaterThanOrEqualTo(3));
    expect(result.statuses.first.user?.screenName, '新华社');
    expect(visitor.refreshCalls, 0);
  });

  test('ok=-100 时重换访客并重试成功', () async {
    final visitor = CountingVisitor();
    var calls = 0;
    final adapter = FakeAdapter((opt) async {
      calls++;
      if (calls == 1) return jsonBody({'ok': -100, 'msg': 'need login'});
      return jsonBody({
        'ok': 1,
        'data': {
          'cards': [
            {
              'card_type': 9,
              'mblog': {
                'id': '77',
                'text_raw': '重试后的微博',
                'user': {'id': 2, 'screen_name': '重试君'},
              },
            },
          ],
        },
      });
    });
    final svc = WeiyueService(visitor, mDio: _dio(adapter));

    final result = await svc.search('重试');
    expect(result.statuses.single.text, '重试后的微博');
    expect(visitor.refreshCalls, 1);
    expect(calls, 2);
  });

  test('访客持续失效：重试一次后抛 WeiyueException', () async {
    final visitor = CountingVisitor();
    final adapter =
        FakeAdapter((opt) async => jsonBody({'ok': -100, 'msg': 'blocked'}));
    final svc = WeiyueService(visitor, mDio: _dio(adapter));

    await expectLater(svc.search('x'), throwsA(isA<WeiyueException>()));
    expect(visitor.refreshCalls, 1);
    expect(adapter.requests.length, 2);
  });

  test('PC 302（未登录跳转）触发重换访客重试', () async {
    final visitor = CountingVisitor();
    var calls = 0;
    final adapter = FakeAdapter((opt) async {
      calls++;
      if (calls == 1) {
        return ResponseBody.fromString('', 302, headers: {
          'location': ['https://passport.weibo.com/visitor/visitor'],
        });
      }
      return jsonBody({
        'ok': 1,
        'statuses': [
          {
            'id': '21',
            'text_raw': '302 后成功',
            'user': {'id': 3, 'screen_name': '跳转侠'},
          },
        ],
      });
    });
    final svc = WeiyueService(visitor, pcDio: _dio(adapter));

    final page = await svc.getHotTimeline(_channel);
    expect(page.statuses.single.text, '302 后成功');
    expect(visitor.refreshCalls, 1);
    expect(calls, 2);
  });

  test('搜索建议：side/search 的 hotquery + users 解析（真实 fixture）', () async {
    final visitor = CountingVisitor();
    final body = File('test/fixtures/side_search.json').readAsStringSync();
    final adapter = FakeAdapter((opt) async => jsonBody(body));
    final svc = WeiyueService(visitor, pcDio: _dio(adapter));

    final s = await svc.getSearchSuggest('周星驰');
    expect(adapter.requests.single.uri.path, '/ajax/side/search');
    expect(adapter.requests.single.queryParameters['q'], '周星驰');
    expect(s.queries.length, 1);
    expect(s.queries.first, '新华社出图');
    expect(s.users.length, 1);
    expect(s.users.first.id, greaterThan(0));
  });

  test('话题容器：231522 解析含 card_group 内 mblog（真实 fixture）', () async {
    final visitor = CountingVisitor();
    final body = File('test/fixtures/topic_container.json').readAsStringSync();
    final adapter = FakeAdapter((opt) async => jsonBody(body));
    final svc = WeiyueService(visitor, mDio: _dio(adapter));

    final page = await svc.getTopicStatuses('国庆');
    final q = adapter.requests.single.queryParameters;
    expect('${q['containerid']}', startsWith('231522type=1&q='));
    expect(page.statuses.length, greaterThanOrEqualTo(3));
    expect(page.statuses.every((s) => s.id.isNotEmpty), isTrue);
  });

  test('文章容器：231912 group 内 mblog 解析（真实 fixture）', () async {
    final visitor = CountingVisitor();
    final body =
        File('test/fixtures/articles_container.json').readAsStringSync();
    final adapter = FakeAdapter((opt) async => jsonBody(body));
    final svc = WeiyueService(visitor, mDio: _dio(adapter));

    final page = await svc.getUserArticles('1699432410');
    expect(adapter.requests.single.queryParameters['containerid'],
        '2319121699432410_-_ordinary');
    expect(page.statuses.length, 2);
    expect(page.statuses.first.text, isNotEmpty);
  });

  test('精选：230283 异步卡 → getItem JSONP 剥壳解析（真实 fixture）', () async {
    final visitor = CountingVisitor();
    final jsonp =
        File('test/fixtures/featured_item_jsonp.txt').readAsStringSync();
    final adapter = FakeAdapter((opt) async {
      if (opt.uri.path == '/api/container/getItem') {
        return ResponseBody.fromString(jsonp, 200, headers: {
          Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
        });
      }
      return jsonBody({
        'ok': 1,
        'data': {
          'cards': [
            {
              'card_type': 11,
              'itemid': '2306181699432410_-_HOTMBLOG',
              'async_api':
                  '/api/container/getItem?itemid=2306181699432410_-_HOTMBLOG&download=',
            },
          ],
          'cardlistInfo': {'page': 1, 'total': 100},
        },
      });
    });
    final svc = WeiyueService(visitor, mDio: _dio(adapter));

    final page = await svc.getUserFeatured('1699432410');
    expect(adapter.requests.length, 2);
    expect(adapter.requests[1].uri.path, '/api/container/getItem');
    expect(adapter.requests[1].queryParameters['itemid'],
        '2306181699432410_-_HOTMBLOG');
    expect(page.statuses.length, 2);
    expect(page.total, 100);
  });

  test('表情映射：config 拉取解析 + 内存缓存只拉一次', () async {
    SharedPreferences.setMockInitialValues({});
    final visitor = CountingVisitor();
    final body =
        File('test/fixtures/emoticon_config.json').readAsStringSync();
    var calls = 0;
    final adapter = FakeAdapter((opt) async {
      calls++;
      return jsonBody(body);
    });
    final svc = WeiyueService(visitor, pcDio: _dio(adapter));

    final map = await svc.getEmoticonMap();
    expect(adapter.requests.single.uri.path, '/ajax/statuses/config');
    expect(map.length, 5);
    expect(map['[泪]'], startsWith('https://'));
    final again = await svc.getEmoticonMap();
    expect(again, same(map));
    expect(calls, 1);
  });

  test('视频合集：videoalbumdetail playlist_id 解析（真实 fixture）', () async {
    final visitor = CountingVisitor();
    final body = File('test/fixtures/videoalbum.json').readAsStringSync();
    final adapter = FakeAdapter((opt) async => jsonBody(body));
    final svc = WeiyueService(visitor, pcDio: _dio(adapter));

    final r = await svc.getVideoAlbum('4617749025193999');
    expect(adapter.requests.single.uri.path,
        '/ajax/profile/videoalbumdetail');
    expect(adapter.requests.single.queryParameters['playlist_id'],
        '4617749025193999');
    expect(r.statuses.length, 2);
    expect(r.statuses.first.text, isNotEmpty);
    expect(r.nextCursor, greaterThan(0));
  });

  test('相册：albumlist 解析 + 容器照片（原创相册优先，真实 fixture）',
      () async {
    final visitor = CountingVisitor();
    final albumsBody = File('test/fixtures/albumlist.json').readAsStringSync();
    final photosBody =
        File('test/fixtures/album_photos_container.json').readAsStringSync();
    final pcAdapter = FakeAdapter((opt) async => jsonBody(albumsBody));
    RequestOptions? containerReq;
    final mAdapter = FakeAdapter((opt) async {
      containerReq = opt;
      return jsonBody(photosBody);
    });
    final svc = WeiyueService(visitor,
        pcDio: _dio(pcAdapter), mDio: _dio(mAdapter));

    final albums = await svc.getAlbums('1699432410');
    expect(albums.length, 5);
    expect(albums.first.title, '赞过');
    expect(albums.first.containerid, isNot(contains('&')));

    final groups = await svc.getAlbumPhotoGroups('1699432410');
    expect('${containerReq?.queryParameters['containerid']}',
        contains('camera_-_0'));
    expect(containerReq?.queryParameters['background'], 'ffffff');
    expect(groups.length, 2);
    expect(groups.first.length, 2);
    expect(groups.first.first.large, startsWith('https://'));
    expect(groups.first.first.original, isNotEmpty);
  });

  test('直播取流（未实测接口）：防御性提取 stream_url，无则返回 null',
      () async {
    final visitor = CountingVisitor();
    final withStream = FakeAdapter((opt) async => jsonBody({
          'ok': 1,
          'data': {
            'live_info': {'stream_url': 'http://pull.example.com/live.flv'},
          },
        }));
    final svc1 = WeiyueService(visitor, pcDio: _dio(withStream));
    expect(await svc1.getLiveStreamUrl('L123'),
        'https://pull.example.com/live.flv');
    expect(withStream.requests.single.uri.path,
        '/ajax/multimedia/getLiveInfo');
    expect(withStream.requests.single.queryParameters['live_id'], 'L123');

    final empty = FakeAdapter((opt) async => jsonBody({'ok': 1, 'data': {}}));
    final svc2 = WeiyueService(visitor, pcDio: _dio(empty));
    expect(await svc2.getLiveStreamUrl('L123'), isNull);
  });

  test('fixture 解码 sanity：all_groups 两组 17+41', () {
    final j = jsonDecode(File('test/fixtures/all_groups.json').readAsStringSync())
        as Map<String, dynamic>;
    final groups = (j['groups'] as List).cast<Map<String, dynamic>>();
    expect(groups.length, 2);
    expect((groups[0]['group'] as List).length, 17);
    expect((groups[1]['group'] as List).length, 41);
  });
}
