import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/core/long_image.dart';
import 'package:weiyue/models/models.dart';
import 'package:weiyue/widgets/responsive_status_list.dart';

void main() {
  group('isLongAspect 长图判定', () {
    test('边界：高宽比恰好 2.5 算长图，略低于不算', () {
      expect(isLongAspect(400, 1000), isTrue); // 恰好 2.5
      expect(isLongAspect(400, 999), isFalse); // 2.4975
      expect(isLongAspect(100, 250), isTrue);
      expect(isLongAspect(100, 249), isFalse);
    });

    test('普通图/横图不是长图', () {
      expect(isLongAspect(1200, 900), isFalse);
      expect(isLongAspect(900, 900), isFalse);
      expect(isLongAspect(500, 1200), isFalse); // 2.4
    });

    test('尺寸缺失（任一为 0）不判定为长图', () {
      expect(isLongAspect(0, 3000), isFalse);
      expect(isLongAspect(500, 0), isFalse);
      expect(isLongAspect(0, 0), isFalse);
    });
  });

  group('feedColumnCount 列数阈值', () {
    test('各档边界', () {
      expect(feedColumnCount(320), 1);
      expect(feedColumnCount(899), 1);
      expect(feedColumnCount(900), 2);
      expect(feedColumnCount(1299), 2);
      expect(feedColumnCount(1300), 3);
      expect(feedColumnCount(1749), 3);
      expect(feedColumnCount(1750), 4);
      expect(feedColumnCount(2199), 4);
      expect(feedColumnCount(2200), 5);
      expect(feedColumnCount(3840), 5);
    });
  });

  group('WbPic 尺寸解析（长图数据来源）', () {
    test('PC pic_infos：large 档 width/height（数字）被解析', () {
      final s = WbStatus.fromJson({
        'id': 101,
        'text_raw': '长图帖',
        'pic_ids': ['p1'],
        'pic_infos': {
          'p1': {
            'thumbnail': {'url': 'https://img.example.com/t.jpg'},
            'bmiddle': {'url': 'https://img.example.com/m.jpg'},
            'large': {
              'url': 'https://img.example.com/l.jpg',
              'width': 500,
              'height': 1600,
            },
            'original': {'url': 'https://img.example.com/o.jpg'},
          },
        },
      });
      expect(s.pics, hasLength(1));
      expect(s.pics.single.width, 500);
      expect(s.pics.single.height, 1600);
      expect(s.pics.single.isLongImage, isTrue);
      expect(s.pics.single.bestOriginal, 'https://img.example.com/o.jpg');
    });

    test('PC pic_infos：尺寸为字符串同样解析；large 无尺寸时回退 original', () {
      final s = WbStatus.fromJson({
        'id': 102,
        'text_raw': 'x',
        'pic_ids': ['p2'],
        'pic_infos': {
          'p2': {
            'large': {'url': 'https://img.example.com/l.jpg'},
            'original': {
              'url': 'https://img.example.com/o.jpg',
              'width': '800',
              'height': '600',
            },
          },
        },
      });
      expect(s.pics.single.width, 800);
      expect(s.pics.single.height, 600);
      expect(s.pics.single.isLongImage, isFalse);
    });

    test('m 端 pics：large{width,height} 字符串尺寸被解析', () {
      final s = WbStatus.fromJson({
        'id': 103,
        'text': 'm 长图',
        'pics': [
          {
            'pid': 'p3',
            'url': 'https://img.example.com/t.jpg',
            'large': {
              'url': 'https://img.example.com/l.jpg',
              'width': '600',
              'height': '1900',
            },
          },
        ],
      });
      expect(s.pics.single.width, 600);
      expect(s.pics.single.height, 1900);
      expect(s.pics.single.isLongImage, isTrue);
    });

    test('接口完全没给尺寸：width/height 为 0，isLongImage 为 false（查看器再解析）', () {
      final s = WbStatus.fromJson({
        'id': 104,
        'text_raw': 'x',
        'pic_ids': ['p4'],
        'pic_infos': {
          'p4': {
            'large': {'url': 'https://img.example.com/l.jpg'},
          },
        },
      });
      expect(s.pics.single.hasSize, isFalse);
      expect(s.pics.single.isLongImage, isFalse);
    });
  });
}
