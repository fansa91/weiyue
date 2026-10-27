import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/models/models.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('parseEmoticonMap：config 多分类短码→URL（真实裁剪 fixture）', () {
    final data = _fixture('emoticon_config.json')['data'] as Map<String, dynamic>;
    final map = parseEmoticonMap(data);
    expect(map.length, 5);
    expect(map['[泪]'], startsWith('https://'));
    expect(map['[心]'], startsWith('https://'));
    expect(map.keys.every((k) => k.startsWith('[') && k.endsWith(']')), isTrue);
  });

  test('WbStatus 直播帖解析：isLive/object_id/page_pic，两形态 page_pic', () {
    final s = WbStatus.fromJson({
      'id': '9001',
      'text_raw': '直播中',
      'page_info': {
        'type': 'live',
        'object_type': 'live',
        'object_id': 'L123456',
        'page_pic': 'http://wx.example.com/live.jpg',
      },
    });
    expect(s.isLive, isTrue);
    expect(s.pageObjectId, 'L123456');
    expect(s.pagePic, 'https://wx.example.com/live.jpg');
    // object_type==live 也进 media 解析（无 media_info 时 video 有对象但无可播流）
    expect(s.hasVideo, isFalse);

    final mForm = WbStatus.fromJson({
      'id': '9002',
      'text': '直播回放',
      'page_info': {
        'type': 'live',
        'object_type': 11,
        'object_id': 'L999',
        'page_pic': {'url': 'https://wx.example.com/replay.jpg'},
      },
    });
    expect(mForm.isLive, isTrue);
    expect(mForm.pageObjectId, 'L999');
    expect(mForm.pagePic, 'https://wx.example.com/replay.jpg');
  });

  test('WbStatus m 端视频解析：object_type=11 + type=video 也取到流', () {
    final s = WbStatus.fromJson({
      'id': '9003',
      'text': 'm 端视频帖',
      'page_info': {
        'type': 'video',
        'object_type': 11,
        'page_pic': {'url': 'https://wx.example.com/cover.jpg'},
        'media_info': {
          'duration': 12,
          'playback_list': [
            {
              'play_info': {
                'label': 'mp4_hd',
                'width': 852,
                'height': 480,
                'url': 'http://f.example.com/v.mp4',
              },
              'meta': {'label': 'mp4_hd'},
            },
          ],
        },
      },
    });
    expect(s.isLive, isFalse);
    expect(s.hasVideo, isTrue);
    expect(s.video!.cover, 'https://wx.example.com/cover.jpg');
    expect(s.video!.playbackList.single.url, 'https://f.example.com/v.mp4');
  });

  test('WbAlbum.fromJson：containerid 剥掉 &background 后缀', () {
    final a = WbAlbum.fromJson({
      'pic_title': '原创',
      'pic': 'http://wx.example.com/a.jpg',
      'containerid': '2318261699432410_-_x&background=ffffff',
    });
    expect(a.title, '原创');
    expect(a.cover, 'https://wx.example.com/a.jpg');
    expect(a.containerid, '2318261699432410_-_x');
  });

  test('WbStatus.copyWith：只换 video/text，其余字段（含直播标记）保留', () {
    final s = WbStatus.fromJson({
      'id': '9004',
      'text_raw': '原文',
      'page_info': {
        'type': 'live',
        'object_type': 'live',
        'object_id': 'L1',
        'page_pic': 'https://wx.example.com/l.jpg',
      },
    });
    final c = s.copyWith(
      video: const WbVideo(cover: 'c', fallbackUrl: 'https://x/live.flv'),
    );
    expect(c.hasVideo, isTrue);
    expect(c.isLive, isTrue);
    expect(c.pageObjectId, 'L1');
    expect(c.pagePic, 'https://wx.example.com/l.jpg');
    expect(c.text, '原文');
  });
}
