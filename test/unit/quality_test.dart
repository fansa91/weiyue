import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/core/quality.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/services/settings_service.dart';

const _pic = WbPic(
  pid: 'p1',
  thumbnail: 'https://img/t.jpg',
  bmiddle: 'https://img/m.jpg',
  large: 'https://img/l.jpg',
  original: 'https://img/o.jpg',
);

WbVideo _video() => const WbVideo(playbackList: [
      WbPlayback(label: 'mp4_1080p', height: 1080, url: 'https://v/1080'),
      WbPlayback(label: 'mp4_720p', height: 720, url: 'https://v/720'),
      WbPlayback(label: 'mp4_480p', height: 480, url: 'https://v/480'),
      WbPlayback(label: 'mp4_180p', height: 180, url: 'https://v/180'),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('视频默认清晰度选档', () {
    test('自动 = 旧默认：≤720p 最高档', () {
      expect(_video().playbackFor(VideoQualityPref.auto)?.height, 720);
    });

    test('各上限档取「≤上限的最高档」', () {
      final v = _video();
      expect(v.playbackFor(VideoQualityPref.smooth)?.height, 180);
      expect(v.playbackFor(VideoQualityPref.standard)?.height, 480);
      expect(v.playbackFor(VideoQualityPref.hd)?.height, 720);
      expect(v.playbackFor(VideoQualityPref.fullHd)?.height, 1080);
      expect(v.playbackFor(VideoQualityPref.highest)?.height, 1080);
    });

    test('没有符合上限的档时取最低档（仍可播）', () {
      const v = WbVideo(playbackList: [
        WbPlayback(label: 'mp4_1080p', height: 1080, url: 'https://v/1080'),
      ]);
      expect(v.playbackFor(VideoQualityPref.smooth)?.height, 1080);
    });

    test('空档位表返回 null', () {
      expect(const WbVideo().playbackFor(VideoQualityPref.hd), isNull);
    });
  });

  group('图片默认清晰度档位映射', () {
    test('列表用图', () {
      expect(_pic.feedUrl(ImageQualityPref.standard), 'https://img/m.jpg');
      expect(_pic.feedUrl(ImageQualityPref.hd), 'https://img/l.jpg');
      expect(_pic.feedUrl(ImageQualityPref.original), 'https://img/o.jpg');
      expect(_pic.feedUrl(ImageQualityPref.dataSaver), 'https://img/t.jpg');
    });

    test('图库用图', () {
      expect(_pic.galleryUrl(ImageQualityPref.standard), 'https://img/l.jpg');
      expect(_pic.galleryUrl(ImageQualityPref.hd), 'https://img/o.jpg');
      expect(
        _pic.galleryUrl(ImageQualityPref.dataSaver),
        'https://img/m.jpg',
      );
    });

    test('长图查看用图：只有省流量档降档', () {
      expect(
        _pic.longViewerUrl(ImageQualityPref.standard),
        'https://img/o.jpg',
      );
      expect(
        _pic.longViewerUrl(ImageQualityPref.dataSaver),
        'https://img/m.jpg',
      );
    });

    test('缺档回退：中图缺失时列表标准档退到大图', () {
      const pic = WbPic(pid: 'p2', large: 'https://img/l.jpg');
      expect(pic.feedUrl(ImageQualityPref.standard), 'https://img/l.jpg');
    });
  });

  group('SettingsService 清晰度设置持久化', () {
    test('默认自动/标准，改后写入且重读一致', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.init();
      expect(s.videoQuality, VideoQualityPref.auto);
      expect(s.imageQuality, ImageQualityPref.standard);

      await s.setVideoQuality(VideoQualityPref.fullHd);
      await s.setImageQuality(ImageQualityPref.dataSaver);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('video_quality'), 'fullHd');
      expect(prefs.getString('image_quality'), 'dataSaver');

      final s2 = SettingsService();
      await s2.init();
      expect(s2.videoQuality, VideoQualityPref.fullHd);
      expect(s2.imageQuality, ImageQualityPref.dataSaver);
    });

    test('存了非法值时回退到默认', () async {
      SharedPreferences.setMockInitialValues({
        'video_quality': 'nope',
        'image_quality': 'nope',
      });
      final s = SettingsService();
      await s.init();
      expect(s.videoQuality, VideoQualityPref.auto);
      expect(s.imageQuality, ImageQualityPref.standard);
    });
  });
}
