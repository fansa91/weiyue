import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/models/models.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('WbStatus PC structures (statuses/show)', () {
    test('解析真实样本：话题文本/视频多档/作者/时间', () {
      final s = WbStatus.fromJson(fixture('pc_status.json'));
      expect(s.id, '5358256479801810');
      expect(s.mblogid, 'Rorw3F7TI');
      expect(s.text, contains('#二十届五中全会#'));
      expect(s.text, contains('旗帜'));
      expect(s.user?.screenName, '新华社');
      expect(s.user?.verified, isTrue);
      expect(s.user?.verifiedType, 3);
      expect(s.createdAt?.year, 2026);
      expect(s.createdAt?.month, 10);
      expect(s.createdAt?.day, 26);
      expect(s.source, '微博视频号');
      expect(s.hasVideo, isTrue);
      final v = s.video!;
      expect(v.durationSec, 703);
      expect(v.onlineUsers, '15.4万次观看');
      // playbackList 按高度降序
      final heights = v.playbackList.map((p) => p.height).toList();
      expect(heights, [1080, 720, 480, 180]); // 含 180p 预览档
      // 默认档 = <=720p 最高 = 720
      expect(v.defaultPlayback?.height, 720);
      expect(v.defaultPlayback?.url, contains('f.video.weibocdn.com'));
      expect(v.cover, contains('sinaimg'));
    });

    test('字段类型飘忽：数字字符串与「万」计数、pic_infos、转发展开', () {
      final s = WbStatus.fromJson({
        'id': '999',
        'idstr': '999',
        'mblogid': 'ZZZ999',
        'text': '<a href="/n/某人">@某人</a> 正文&nbsp;内容',
        'text_raw': '@某人 正文 内容',
        'created_at': 'Mon Oct 26 13:09:19 +0800 2026',
        'source': '<a href="https://app.weibo.com/t/feed/x">微博视频号</a>',
        'reposts_count': '269',
        'comments_count': 122,
        'attitudes_count': '1.2万',
        'pic_ids': ['aa11', 'bb22'],
        'pic_infos': {
          'aa11': {
            'thumbnail': {'url': 'https://img/t1.jpg'},
            'bmiddle': {'url': 'https://img/m1.jpg'},
            'large': {'url': 'https://img/l1.jpg'},
            'original': {'url': 'https://img/o1.jpg'},
          },
          'bb22': {
            'bmiddle': {'url': 'https://img/m2.jpg'},
            'large': {'url': 'https://img/l2.jpg'},
          },
        },
        'isLongText': true,
        'retweeted_status': {
          'id': '888',
          'mblogid': 'YYY888',
          'text_raw': '被转发的原文',
          'user': {'id': 7, 'screen_name': '原作者'},
        },
        'user': {'id': '42', 'screen_name': '字符串id用户'},
      });
      expect(s.repostsCount, 269);
      expect(s.commentsCount, 122);
      expect(s.attitudesCount, 12000);
      expect(s.text, '@某人 正文 内容'); // text_raw 优先
      expect(s.source, '微博视频号');
      expect(s.isLongText, isTrue);
      expect(s.pics.length, 2);
      expect(s.pics[0].large, 'https://img/l1.jpg');
      expect(s.pics[0].original, 'https://img/o1.jpg');
      expect(s.pics[1].bestMiddle, 'https://img/m2.jpg');
      expect(s.retweeted?.id, '888');
      expect(s.retweeted?.user?.screenName, '原作者');
      expect(s.user?.id, 42);
    });

    test('text 只有 HTML 时剥标签回退', () {
      final s = WbStatus.fromJson({
        'id': '1',
        'text': '只有<a href="/x">链接文字</a>没有 raw<br>第二行',
        'user': {'id': 1, 'screen_name': 'u'},
      });
      expect(s.text, '只有链接文字没有 raw\n第二行');
    });

    test('空/缺字段不抛错', () {
      final s = WbStatus.fromJson(const {});
      expect(s.id, '');
      expect(s.pics, isEmpty);
      expect(s.hasVideo, isFalse);
      expect(s.retweeted, isNull);
    });
  });

  group('WbStatus m 栈 mblog 结构', () {
    test('解析 m container 的 mblog', () {
      final s = WbStatus.fromJson(fixture('m_mblog.json'));
      expect(s.user?.screenName, '新华社');
      expect(s.text, contains('公益性慢火车'));
      expect(s.id, '5358668493358832');
    });

    test('m pics 数组结构（url/large）', () {
      final s = WbStatus.fromJson({
        'id': '5',
        'text_raw': '带图微博',
        'pics': [
          {
            'pid': 'p1',
            'url': 'https://img/orj.jpg',
            'large': {'url': 'https://img/large.jpg'},
          },
        ],
        'user': {'id': 3, 'screen_name': '图主'},
      });
      expect(s.pics.length, 1);
      expect(s.pics[0].large, 'https://img/large.jpg');
      expect(s.pics[0].bmiddle, 'https://img/orj.jpg');
    });
  });

  group('其他模型', () {
    test('WbUser from profile/info', () {
      final data = fixture('profile_info.json')['data'] as Map<String, dynamic>;
      final user = WbUser.fromJson(data['user'] as Map<String, dynamic>);
      expect(user.screenName, '新华社');
      expect(user.id, 1699432410);
      expect(user.verifiedType, 3);
      expect(user.followersCount, 114118609);
      expect(user.friendsCount, 3029);
      expect(user.statusesCount, 207112);
      expect(user.avatar, contains('sinaimg'));
    });

    test('WbComment from buildComments', () {
      final j = fixture('comments.json');
      final c = WbComment.fromJson(
          (j['data'] as List).first as Map<String, dynamic>);
      expect(c.text, contains('旗帜'));
      expect(c.user?.screenName, '真爱和自由_New');
      expect(c.likeCount, 12);
      expect(c.source, contains('湖南'));
    });

    test('WbChannel from allGroups 两组', () {
      final j = fixture('all_groups.json');
      final groups = (j['groups'] as List).cast<Map<String, dynamic>>();
      final mine = groups.firstWhere((g) => g['title'] == '我的频道');
      final rec = groups.firstWhere((g) => g['title'] == '频道推荐');
      final mineChannels = (mine['group'] as List)
          .map((e) => WbChannel.fromJson(e as Map<String, dynamic>))
          .toList();
      final recChannels = (rec['group'] as List)
          .map((e) => WbChannel.fromJson(e as Map<String, dynamic>))
          .toList();
      expect(mineChannels.length, 17);
      expect(mineChannels.first.title, '热门');
      expect(mineChannels.first.gid, '102803');
      expect(mineChannels.first.containerid, '102803');
      expect(mineChannels[1].title, '同城');
      expect(mineChannels[1].containerid, '102803_2222');
      expect(recChannels.length, 41);
      // 推荐组里含综艺/游戏（短剧/电影/电视剧不在 allGroups 两组内，
      // VideoTabScreen 对其用文档规律拼的硬编码兜底）
      final variety = recChannels.firstWhere((c) => c.title == '综艺');
      expect(variety.containerid, '102803_ctg1_4688_-_ctg1_4688');
      final game = recChannels.firstWhere((c) => c.title == '游戏');
      expect(game.containerid, '102803_ctg1_4888_-_ctg1_4888');
    });

    test('BandItem from band_list', () {
      final j = fixture('band.json');
      final item = BandItem.fromJson(
          (j['data']['band_list'] as List).first as Map<String, dynamic>);
      expect(item.word, '肖战伴手礼17斤');
      expect(item.num, 1233572);
      expect(item.realpos, 1);
      expect(item.category, '剧集');
    });

    test('HotWord from hotSearch realtime（热度为字符串）', () {
      final j = fixture('hot_search.json');
      final data = j['data'] as Map<String, dynamic>;
      final gov =
          HotWord.fromJson(data['hotgov'] as Map<String, dynamic>);
      expect(gov.word, contains('总书记说这样的苹果'));
      final first = HotWord.fromJson(
          (data['realtime'] as List).first as Map<String, dynamic>);
      expect(first.word, '姆巴佩深知被羞辱的滋味却不懂尊重');
      expect(first.num, 11742305);
      expect(first.label, '爆');
    });

    test('WbPlaylist from getVideoTab', () {
      final j = fixture('videotab.json');
      final p = WbPlaylist.fromJson(
          (j['data']['playlists'] as List).first as Map<String, dynamic>);
      expect(p.id, '4617749025193999');
      expect(p.name, '国务院联防联控机制');
      expect(p.itemCount, 36);
    });

    test('WbAttitude from m attitudes', () {
      final j = fixture('attitudes.json');
      // m attitudes 结构：data.data[] 才是列表
      final a = WbAttitude.fromJson(((j['data']
              as Map<String, dynamic>)['data'] as List)
          .first as Map<String, dynamic>);
      expect(a.user?.screenName, '哭D包W');
      expect(a.source, '荣耀X50');
    });
  });
}
