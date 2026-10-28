import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/models/models.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('视频帖 pics 混入封面/视频帧过滤（实证结构）', () {
    test('图文+视频混合帖：只保留 pic_ids 内的真图片，视频帧条目剔除', () {
      // fixture 按访客实证的真实结构构造（m 搜索容器/m show 一致）：
      // page_info 为 video，pics 5 条——3 条 pid 在 pic_ids 内（图文图片），
      // 2 条不在（与 page_pic 同批次的视频帧，geo 192x480 → 高宽比 2.5）。
      final s = WbStatus.fromJson(fixture('m_mixed_video.json'));
      expect(s.hasVideo, isTrue);
      expect(s.video!.cover, contains('006f8wK2ly1iiiu4blrl9j6'));
      expect(s.pics.map((p) => p.pid), [
        '006f8wK2ly1iiiu3piu4wj60j60asn0j02',
        '006f8wK2ly1iiiu3pijvgj60j60aswi302',
        '006f8wK2ly1iiiu3pjgi6j60j60aswi302',
      ]);
      // 剔除的正是会被误判长图的帧条目（192x480，比 2.5）
      expect(s.pics.any((p) => p.isLongImage), isFalse);
      expect(s.pics.any((p) => p.pid.contains('iu4a')), isFalse);
    });

    test('纯视频帖 pics 混入封面且无 pic_ids：整组丢弃', () {
      final s = WbStatus.fromJson({
        'id': '9001',
        'text_raw': '竖屏视频帖',
        'page_info': {
          'type': 'video',
          'object_type': 11,
          'page_pic': {
            'pid': 'coverPid1',
            'url': 'https://img/cover.jpg',
            'width': '1080',
            'height': '2700',
          },
          'media_info': {
            'stream_url': 'https://v.example.com/x.mp4',
            'duration': 12,
          },
        },
        'pics': [
          {
            'pid': 'coverPid1',
            'url': 'https://img/orj.jpg',
            'large': {'url': 'https://img/large.jpg'},
            'geo': {'width': 192, 'height': 480},
          },
        ],
        'user': {'id': 3, 'screen_name': '视频号'},
      });
      expect(s.hasVideo, isTrue);
      expect(s.pics, isEmpty);
    });

    test('普通长图帖不受影响：pics 原样保留且长图判定成立', () {
      final s = WbStatus.fromJson({
        'id': '9002',
        'text_raw': '长图帖',
        'pic_ids': ['longPid'],
        'pics': [
          {
            'pid': 'longPid',
            'url': 'https://img/orj.jpg',
            'large': {'url': 'https://img/large.jpg'},
            'geo': {'width': 200, 'height': 900},
          },
        ],
        'user': {'id': 4, 'screen_name': '图主'},
      });
      expect(s.hasVideo, isFalse);
      expect(s.pics, hasLength(1));
      expect(s.pics.single.isLongImage, isTrue);
    });

    test('非媒体帖 pics 与 pic_ids 对不上也不过滤（过滤只针对媒体帖）', () {
      final s = WbStatus.fromJson({
        'id': '9003',
        'text_raw': '普通图文帖',
        'pic_ids': ['otherPid'],
        'pics': [
          {
            'pid': 'somePid',
            'url': 'https://img/orj.jpg',
            'large': {'url': 'https://img/large.jpg'},
            'geo': {'width': 800, 'height': 600},
          },
        ],
        'user': {'id': 5, 'screen_name': '图主'},
      });
      expect(s.hasVideo, isFalse);
      expect(s.pics, hasLength(1));
      expect(s.pics.single.pid, 'somePid');
    });
  });
}
