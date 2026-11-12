import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/screens/detail_screen.dart';
import 'package:weiyue/widgets/photo_gallery.dart';

import '../helpers/fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void _useView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 评论假服务：第一页带一条带图评论 + 一条带楼中楼的评论，
/// 记录每次 getComments 的 maxId 入参，供游标与计数断言。
class _CommentsFakeService extends FakeWeiyueService {
  final List<int> commentMaxIds = [];

  static const _pic = WbPic(
    pid: '008kUb0Qgy1iia5dex2wij30u0191ad1',
    thumbnail:
        'https://wx1.sinaimg.cn/thumbnail/008kUb0Qgy1iia5dex2wij30u0191ad1.jpg',
    bmiddle:
        'https://wx1.sinaimg.cn/bmiddle/008kUb0Qgy1iia5dex2wij30u0191ad1.jpg',
    large: 'https://wx1.sinaimg.cn/large/008kUb0Qgy1iia5dex2wij30u0191ad1.jpg',
    original:
        'https://wx1.sinaimg.cn/woriginal/008kUb0Qgy1iia5dex2wij30u0191ad1.jpg',
    width: 1080,
    height: 1621,
  );

  WbComment _comment(
    String id,
    String text, {
    String source = '来自 湖南',
    List<WbComment> replies = const [],
    WbPic? pic,
  }) => WbComment(
    id: id,
    user: makeStatus().user,
    text: text,
    createdAtRaw: 'Mon Oct 26 13:15:08 +0800 2026',
    source: source,
    likeCount: 1,
    replies: replies,
    pic: pic,
  );

  @override
  Future<({List<WbComment> comments, int total, int maxId})> getComments(
    String id, {
    required String authorUid,
    int maxId = 0,
  }) async {
    commentMaxIds.add(maxId);
    if (maxId == 0) {
      return (
        comments: [
          _comment('wp-1', '带图评论', pic: _pic),
          _comment(
            'wp-2',
            '带楼中楼的评论',
            replies: [
              _comment('wp-2-r1', '回复一', source: '来自 广东'),
              _comment('wp-2-r2', '回复二', source: '来自 北京'),
            ],
          ),
          for (var i = 0; i < 8; i++) _comment('p1-$i', '第一页评论 $i'),
        ],
        total: 15,
        maxId: 777,
      );
    }
    return (
      comments: [for (var i = 0; i < 5; i++) _comment('p2-$i', '第二页评论 $i')],
      total: 15,
      maxId: 0,
    );
  }
}

void main() {
  group('WbComment 配图/地区解析（fixture 按探针实证结构）', () {
    final raw =
        jsonDecode(
              File('test/fixtures/comments_with_pic.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final comments = (raw['data'] as List)
        .map((e) => WbComment.fromJson(e as Map<String, dynamic>))
        .toList();

    test('pic_num>0 的评论解析出配图（woriginal 归入 original）', () {
      final pic = comments[0].pic;
      expect(pic, isNotNull);
      expect(pic!.pid, '008kUb0Qgy1iia5dex2wij30u0191ad1');
      expect(pic.thumbnail, contains('/thumbnail/'));
      expect(pic.bmiddle, contains('/bmiddle/'));
      expect(pic.large, contains('/large/'));
      // 样本原图档键名是 woriginal，应落到 original
      expect(pic.original, contains('/woriginal/'));
      // 尺寸取 large 档（字符串数字也要解析）
      expect(pic.width, 1080);
      expect(pic.height, 1621);
    });

    test('pic_num=0 的回复不继承父评论的图，地区字段照常解析', () {
      final parent = comments[0];
      expect(parent.replies, hasLength(2));
      // 回复的 url_struct 里有父评论的 pic_infos，但自身 pic_num=0 → 无图
      expect(parent.replies[0].pic, isNull);
      expect(parent.replies[1].pic, isNull);
      expect(parent.replies[0].source, '来自 山东');
      expect(parent.replies[1].source, '来自 浙江');
      expect(parent.source, '来自 广东');
    });

    test('无图评论 pic 为 null', () {
      expect(comments[1].pic, isNull);
    });
  });

  testWidgets('DetailScreen 宽屏：评论滚到底自动续拉（无手动按钮、游标正确）', (tester) async {
    await mockNetworkImagesFor(() async {
      _useView(tester, const Size(1200, 900));
      final fake = _CommentsFakeService();
      final status = makeStatus(id: '9', text: '详情页原文', comments: 15);
      await tester.pumpWidget(
        wrapWithProviders(
          DetailScreen(status: status),
          weibo: fake,
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      expect(fake.commentMaxIds, [0]);
      // 手动翻页按钮已不存在
      expect(find.textContaining('加载更多评论'), findsNothing);

      // 在评论页签区域反复上滑到底：自动以游标 777 续拉第二页
      for (var i = 0; i < 6; i++) {
        await tester.dragFrom(
          tester.getCenter(find.byType(TabBarView)),
          const Offset(0, -600),
        );
        await _settle(tester);
      }
      expect(fake.commentMaxIds, [0, 777]);
      expect(
        find.textContaining('第二页评论 0', findRichText: true),
        findsOneWidget,
      );
    });
  });

  testWidgets('DetailScreen：楼中楼回复显示地区', (tester) async {
    await mockNetworkImagesFor(() async {
      _useView(tester, const Size(400, 800));
      final status = makeStatus(id: '9', text: '详情页原文', comments: 15);
      await tester.pumpWidget(
        wrapWithProviders(
          DetailScreen(status: status),
          weibo: _CommentsFakeService(),
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      // 把带楼中楼的评论滚进可视区
      await tester.ensureVisible(
        find.textContaining('带楼中楼的评论', findRichText: true),
      );
      await _settle(tester);
      // 回复元信息行应带地区（顶级评论的「来自 湖南」不算数，
      // 断言回复独有的广东/北京）
      expect(find.textContaining('来自 广东'), findsOneWidget);
      expect(find.textContaining('来自 北京'), findsOneWidget);
    });
  });

  testWidgets('DetailScreen：评论图缩略图出现且点击进图库，无图评论无图位', (tester) async {
    await mockNetworkImagesFor(() async {
      _useView(tester, const Size(400, 800));
      final status = makeStatus(id: '9', text: '详情页原文', comments: 15);
      await tester.pumpWidget(
        wrapWithProviders(
          DetailScreen(status: status),
          weibo: _CommentsFakeService(),
          session: FakeSessionService(loggedIn: true),
        ),
      );
      await _settle(tester);
      // 首屏 10 条评论里只有 1 条带图 → 恰好 1 个图位
      final picFinder = find.byKey(const ValueKey('comment-pic'));
      expect(picFinder, findsOneWidget);

      // 拖动评论区把图从视口下部挪到中部（不用 ensureVisible：它会把图
      // 顶到内层视口上沿、压在吸顶页签栏下，点不中；拖太多又会出缓存区）
      await tester.dragFrom(
        tester.getCenter(find.byType(TabBarView)),
        const Offset(0, -260),
      );
      await _settle(tester);
      await tester.tap(picFinder);
      await _settle(tester);
      expect(find.byType(PhotoGalleryScreen), findsOneWidget);
    });
  });
}
