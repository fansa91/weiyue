import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weiyue/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService 视频自动播放', () {
    test('默认开，关闭后写入持久化且重读仍为关', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.init();
      expect(s.videoAutoplay, isTrue);

      await s.setVideoAutoplay(false);
      expect(s.videoAutoplay, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('video_autoplay'), isFalse);

      // 模拟重启：新实例从持久化读回
      final s2 = SettingsService();
      await s2.init();
      expect(s2.videoAutoplay, isFalse);
    });

    test('已存为关时 init 读回关，打开后持久化为开', () async {
      SharedPreferences.setMockInitialValues({'video_autoplay': false});
      final s = SettingsService();
      await s.init();
      expect(s.videoAutoplay, isFalse);

      await s.setVideoAutoplay(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('video_autoplay'), isTrue);
    });
  });
}
