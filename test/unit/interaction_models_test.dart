import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/models/models.dart';

/// 互动状态字段的模型解析：liked（attitudes_status）/ favorited /
/// following 都是接口对象自带字段（抓包样本实证），访客态缺失时默认未。
void main() {
  group('WbStatus 互动状态', () {
    test('attitudes_status 非 0 → liked', () {
      final s = WbStatus.fromJson({
        'id': '1',
        'text_raw': 'x',
        'attitudes_status': 2,
        'attitudes_count': 10,
      });
      expect(s.liked, isTrue);
      expect(s.favorited, isFalse);
    });

    test('attitudes_status 为 0 或缺失 → 未赞', () {
      expect(
        WbStatus.fromJson({'id': '1', 'attitudes_status': 0}).liked,
        isFalse,
      );
      expect(WbStatus.fromJson({'id': '1'}).liked, isFalse);
    });

    test('favorited 布尔解析（true/缺失）', () {
      expect(WbStatus.fromJson({'id': '1', 'favorited': true}).favorited, isTrue);
      expect(WbStatus.fromJson({'id': '1'}).favorited, isFalse);
    });

    test('copyWith 可覆盖互动状态与计数，其余字段保留', () {
      final s = WbStatus.fromJson({
        'id': '9',
        'text_raw': '原文',
        'attitudes_count': 3,
        'reposts_count': 1,
        'comments_count': 2,
      });
      final t = s.copyWith(
        liked: true,
        attitudesCount: 4,
        favorited: true,
        repostsCount: 2,
      );
      expect(t.liked, isTrue);
      expect(t.attitudesCount, 4);
      expect(t.favorited, isTrue);
      expect(t.repostsCount, 2);
      expect(t.text, '原文');
      expect(t.commentsCount, 2);
      // 原对象不变
      expect(s.liked, isFalse);
      expect(s.attitudesCount, 3);
    });
  });

  group('WbUser following', () {
    test('fromJson 解析 following（抓包 user 对象字段）', () {
      expect(WbUser.fromJson({'id': 5, 'following': true}).following, isTrue);
      expect(WbUser.fromJson({'id': 5, 'following': false}).following, isFalse);
      expect(WbUser.fromJson({'id': 5}).following, isFalse);
    });

    test('toJson/fromJson 往返保 following（会话资料落盘用）', () {
      const u = WbUser(id: 5, screenName: '甲', following: true);
      final back = WbUser.fromJson(u.toJson());
      expect(back.following, isTrue);
      expect(back.screenName, '甲');
    });

    test('copyWith 可覆盖 following', () {
      const u = WbUser(id: 5, screenName: '甲');
      expect(u.copyWith(following: true).following, isTrue);
      expect(u.following, isFalse);
    });
  });
}
