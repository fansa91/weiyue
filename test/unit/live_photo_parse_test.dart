import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/models/models.dart';

Map<String, dynamic> _loadFixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('PC pic_infos 实况照片解析（样本结构裁剪，假签名/假域名）', () {
    final status = WbStatus.fromJson(_loadFixture('live_photo_status.json'));

    test('三张图全部保留为图片（livephoto 不剔除）', () {
      expect(status.pics.map((p) => p.pid), ['liveA', 'liveB', 'normalC']);
    });

    test('video_hd 有效：主地址取 hd，兜底直链从 hd 解码', () {
      final pic = status.pics[0];
      expect(pic.isLivePhoto, isTrue);
      expect(
        pic.liveVideoUrl,
        'https://video.example.com/media/play?livephoto='
        'https%3A%2F%2Fus.example.com%2F004FakeHDjx08BKmAMQx10h04110077up0k01.mov'
        '&Expires=1799999999&ssig=FAKESIG&KID=unistore,video',
      );
      expect(
        pic.liveVideoFallbackUrl,
        'https://us.example.com/004FakeHDjx08BKmAMQx10h04110077up0k01.mov',
      );
    });

    test('video_hd 残缺空壳（解码为 /.mov）：回落 video', () {
      final pic = status.pics[1];
      expect(pic.isLivePhoto, isTrue);
      expect(
        pic.liveVideoUrl,
        'https://video.example.com/media/play?livephoto='
        'https%3A%2F%2Fus.example.com%2F003FakeOKjx08BTDNmiBa0f0f0100j7yH0k01.mov',
      );
      expect(
        pic.liveVideoFallbackUrl,
        'https://us.example.com/003FakeOKjx08BTDNmiBa0f0f0100j7yH0k01.mov',
      );
    });

    test('普通照片：实况地址为空，非实况', () {
      final pic = status.pics[2];
      expect(pic.isLivePhoto, isFalse);
      expect(pic.liveVideoUrl, isEmpty);
      expect(pic.liveVideoFallbackUrl, isEmpty);
    });
  });

  group('m pics 实况照片解析（raw/m_hot_local.json 实证结构）', () {
    final status = WbStatus.fromJson(_loadFixture('m_live_photo_status.json'));

    test('livephoto 按图片保留并接线 videoSrc，type=video 仍剔除', () {
      expect(status.pics.map((p) => p.pid), ['mlive1', 'mplain1']);
      final live = status.pics.first;
      expect(live.isLivePhoto, isTrue);
      expect(
        live.liveVideoUrl,
        'https://video.example.com/media/play?livephoto='
        'https%3A%2F%2Flivephoto.example.com%2F003FakeMVjx08BTDNmiBa0f0f0100j7yH0k01.mov',
      );
      expect(
        live.liveVideoFallbackUrl,
        'https://livephoto.example.com/003FakeMVjx08BTDNmiBa0f0f0100j7yH0k01.mov',
      );
      expect(status.pics[1].isLivePhoto, isFalse);
    });
  });
}
