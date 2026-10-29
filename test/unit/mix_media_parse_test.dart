import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/core/long_image.dart';
import 'package:weiyue/models/models.dart';

Map<String, dynamic> _loadFixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('mix_media_info 解析（2026-10-29 访客实证结构）', () {
    test('图文+视频混合帖：pics 来自 mix pic 项，视频来自 mix video 项', () {
      // 实证：PC show/热门流里这类帖无 page_info、无 pic_infos，
      // pic_ids 只含图片 pid，媒体全在 mix_media_info.items。
      final s = WbStatus.fromJson(_loadFixture('pc_mix_media.json'));
      expect(s.hasVideo, isTrue, reason: 'mix video 项应解析出可播视频');
      expect(s.video!.playbackList, isNotEmpty);
      expect(s.video!.cover, isNotEmpty);
      expect(s.pics.length, 3, reason: 'mix 的 3 个 pic 项应全部保留为图片');
      expect(
        s.pics.map((p) => p.pid),
        containsAll(<String>[
          '0063OWvMgy1iiix46j02xj30xi0xjgs8',
          '0063OWvMgy1iiix46yldzj30xi0yaqbg',
          '0063OWvMgy1iiix47sxmsj30xi0543zb',
        ]),
      );
      // 视频封面 pid 不是任何一张图片
      expect(s.pics.any((p) => p.pid == '5359289800261670'), isFalse);
    });

    test('纯多视频帖（竖屏视频）：hasVideo 为真，pics 为空', () {
      final s = WbStatus.fromJson(_loadFixture('pc_mix_videos.json'));
      expect(s.hasVideo, isTrue);
      expect(s.pics, isEmpty);
      expect(s.hasAnyMediaVideo, isTrue);
      expect(statusAllowsLongImage(s), isFalse);
    });

    test('m 端混合帖 show：pics 里 type=video 条目剔除，真图保留', () {
      // 实证：m show 的 pics 混有 type=='video'（带 videoSrc）的条目，
      // 其 pid 不在 pic_ids 内；本轮起按 type 标记直接剔除。
      final s = WbStatus.fromJson(_loadFixture('m_mix_show.json'));
      expect(s.hasVideo, isTrue, reason: 'page_info 第一个视频应被识别');
      expect(s.pics.length, 3);
      expect(
        s.pics.any((p) => p.pid.endsWith('30u00uowg5')),
        isFalse,
        reason: 'type=video 的封面条目不应进 pics',
      );
    });

    test('pic_infos 条目 type=video 被排除，type=livephoto 仍保留', () {
      Map<String, dynamic> info(String type, int w, int h) => {
            'thumbnail': {'url': 'https://example.com/t.jpg', 'width': 180, 'height': 180},
            'large': {'url': 'https://example.com/l.jpg', 'width': w, 'height': h},
            'type': type,
          };
      final s = WbStatus.fromJson({
        'id': 'synth1',
        'text': '合成帖',
        'pic_ids': ['pv1', 'pl1'],
        'pic_infos': {
          'pv1': info('video', 720, 1920), // 视频帧：高宽比 2.67
          'pl1': info('livephoto', 960, 1281), // 实况照片：是图片
        },
      });
      expect(s.pics.length, 1);
      expect(s.pics.single.pid, 'pl1');
    });
  });

  group('长图准入收口 statusAllowsLongImage', () {
    const longPic = WbPic(pid: 'lp', width: 200, height: 600);
    const videoStatus = WbStatus(
      id: 'v',
      video: WbVideo(fallbackUrl: 'https://example.com/v.mp4'),
    );

    test('普通图文帖允许长图', () {
      const s = WbStatus(id: 'a', pics: [longPic]);
      expect(statusAllowsLongImage(s), isTrue);
    });

    test('本级含视频/直播不允许', () {
      expect(statusAllowsLongImage(videoStatus), isFalse);
      const live = WbStatus(id: 'l', isLive: true);
      expect(statusAllowsLongImage(live), isFalse);
    });

    test('转发原帖含视频时，外层带图帖也不允许长图化', () {
      const outer = WbStatus(id: 'o', pics: [longPic], retweeted: videoStatus);
      expect(outer.hasVideo, isFalse, reason: '外层本级并无视频');
      expect(outer.hasAnyMediaVideo, isTrue);
      expect(statusAllowsLongImage(outer), isFalse);
    });
  });
}
