import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/core/utils.dart';
import 'package:weiyue/models/models.dart';

void main() {
  group('formatPlayCount', () {
    test('万以下原样', () {
      expect(formatPlayCount(0), '0');
      expect(formatPlayCount(9999), '9999');
    });
    test('万级一位小数', () {
      expect(formatPlayCount(12345), '1.2万');
      expect(formatPlayCount(128308716 ~/ 10000), '1.3万');
      expect(formatPlayCount(34657), '3.5万');
    });
    test('亿级一位小数', () {
      expect(formatPlayCount(114118609), '1.1亿');
      expect(formatPlayCount(128308716), '1.3亿');
    });
  });

  group('formatDurationSec', () {
    test('分:秒', () {
      expect(formatDurationSec(703), '11:43');
      expect(formatDurationSec(65), '1:05');
      expect(formatDurationSec(9), '0:09');
    });
    test('超过一小时带时', () {
      expect(formatDurationSec(3661), '1:01:01');
    });
  });

  group('formatTimeAgo', () {
    test('分钟/小时/天', () {
      final now = DateTime.now();
      expect(formatTimeAgo(now.subtract(const Duration(minutes: 5))),
          '5分钟前');
      expect(formatTimeAgo(now.subtract(const Duration(hours: 2))), '2小时前');
      expect(formatTimeAgo(now.subtract(const Duration(days: 3))), '3天前');
      expect(formatTimeAgo(now), '刚刚');
      expect(formatTimeAgo(null), '');
    });
  });

  group('parseWbTime 英文 created_at', () {
    test('标准格式', () {
      final dt = parseWbTime('Mon Oct 26 13:09:19 +0800 2026');
      expect(dt, isNotNull);
      expect(dt!.year, 2026);
      expect(dt.month, 10);
      expect(dt.day, 26);
      expect(dt.hour, 13);
      expect(dt.minute, 9);
    });
    test('非法输入返回 null', () {
      expect(parseWbTime(''), isNull);
      expect(parseWbTime('not a date'), isNull);
    });
  });

  group('stripHtml', () {
    test('剥标签、br 换行、img alt、实体解码', () {
      expect(
        stripHtml('<a href="/n/x">#话题#</a>正文<br>第二行'
            '<img alt="[微笑]" src="i.png">结尾 &amp; 符号'),
        '#话题#正文\n第二行[微笑]结尾 & 符号',
      );
    });
    test('清洗多余空白', () {
      expect(stripHtml('  a   b\n\n\n c '), 'a   b\n\n\n c');
    });
  });

  group('cleanSource', () {
    test('HTML 链接取文本、纯文本原样', () {
      expect(cleanSource('<a href="https://app.weibo.com/t/feed/x">微博视频号</a>'),
          '微博视频号');
      expect(cleanSource('微博网页版'), '微博网页版');
    });
  });
}
