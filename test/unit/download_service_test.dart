import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/services/download_service.dart';

class FakeDownloader implements StreamDownloader {
  List<int> bytes = [1, 2, 3, 4];
  Object? error;
  final fileUrls = <String>[];
  final byteUrls = <String>[];

  @override
  Future<void> downloadToFile(
    String url,
    File file, {
    DownloadProgress? onProgress,
  }) async {
    if (error != null) throw error!;
    fileUrls.add(url);
    await file.writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }

  @override
  Future<List<int>> downloadBytes(
    String url, {
    DownloadProgress? onProgress,
  }) async {
    if (error != null) throw error!;
    byteUrls.add(url);
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }
}

class FakeGallerySaver implements GallerySaver {
  final imageCalls = <({List<int> bytes, String name})>[];
  final videoCalls = <({String path, bool existedAtCall})>[];

  @override
  Future<void> saveImageBytes(List<int> bytes, {required String name}) async {
    imageCalls.add((bytes: bytes, name: name));
  }

  @override
  Future<void> saveVideoFile(String filePath) async {
    videoCalls.add((path: filePath, existedAtCall: File(filePath).existsSync()));
  }
}

void main() {
  late Directory root;
  late Directory downloads;
  late Directory temp;
  late FakeDownloader downloader;
  late FakeGallerySaver gallery;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('weiyue_dl_test');
    downloads = await Directory('${root.path}/downloads').create();
    temp = await Directory('${root.path}/tmp').create();
    downloader = FakeDownloader();
    gallery = FakeGallerySaver();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  DownloadService make({required bool useGallery}) => DownloadService(
        downloader: downloader,
        gallerySaver: gallery,
        downloadsDirectory: () async => downloads,
        tempDirectory: () async => temp,
        useGallery: useGallery,
      );

  group('桌面（下载目录）', () {
    test('图片：流式落盘到下载目录，扩展名取自 URL，进度有回调', () async {
      final svc = make(useGallery: false);
      var progressed = false;
      final result = await svc.saveImage(
        url: 'https://wx.example.com/large/abc.PNG?Expires=99&ssig=x',
        baseName: 'weiyue_p1',
        onProgress: (_, _) => progressed = true,
      );
      expect(result.savedToGallery, isFalse);
      expect(result.filePath, '${downloads.path}/weiyue_p1.png');
      expect(await File(result.filePath!).readAsBytes(), [1, 2, 3, 4]);
      expect(downloader.fileUrls, hasLength(1), reason: '图片也走流式落盘');
      expect(progressed, isTrue);
      expect(result.describe, contains('已保存到'));
    });

    test('重名不覆盖：自动加 _1 后缀', () async {
      await File('${downloads.path}/weiyue_p1.jpg').writeAsBytes([9]);
      final svc = make(useGallery: false);
      final result = await svc.saveImage(
        url: 'https://wx.example.com/a.jpg',
        baseName: 'weiyue_p1',
      );
      expect(result.filePath, '${downloads.path}/weiyue_p1_1.jpg');
      expect(await File('${downloads.path}/weiyue_p1.jpg').readAsBytes(), [9],
          reason: '原文件未被覆盖');
    });

    test('视频：流式下载到下载目录，默认 .mp4', () async {
      final svc = make(useGallery: false);
      final result = await svc.saveVideo(
        url: 'https://f.video.example.com/o0/xyz?label=mp4_hd',
        baseName: 'weiyue_video_42',
      );
      expect(result.filePath, '${downloads.path}/weiyue_video_42.mp4');
      expect(await File(result.filePath!).exists(), isTrue);
      expect(gallery.videoCalls, isEmpty);
    });
  });

  group('移动端（相册）', () {
    test('图片：下载字节后交给相册后端（名字不带扩展名）', () async {
      final svc = make(useGallery: true);
      final result = await svc.saveImage(
        url: 'https://wx.example.com/a.jpg',
        baseName: 'weiyue_p2',
      );
      expect(result.savedToGallery, isTrue);
      expect(result.describe, '已保存到相册');
      expect(gallery.imageCalls, hasLength(1));
      expect(gallery.imageCalls.single.bytes, [1, 2, 3, 4]);
      expect(gallery.imageCalls.single.name, 'weiyue_p2');
      expect(downloader.byteUrls, hasLength(1));
    });

    test('视频：先流式下到临时文件再入相册，临时文件事后清理', () async {
      final svc = make(useGallery: true);
      final result = await svc.saveVideo(
        url: 'https://f.video.example.com/v.mp4?x=1',
        baseName: 'weiyue_video_7',
      );
      expect(result.savedToGallery, isTrue);
      expect(gallery.videoCalls, hasLength(1));
      expect(gallery.videoCalls.single.existedAtCall, isTrue,
          reason: '交给相册时临时文件必须存在');
      expect(
        await File(gallery.videoCalls.single.path).exists(),
        isFalse,
        reason: '入相册后临时文件应被清理',
      );
    });
  });

  group('失败与清洗', () {
    test('空 URL 直接抛可读错误', () async {
      final svc = make(useGallery: false);
      await expectLater(
        svc.saveImage(url: '', baseName: 'x'),
        throwsA(isA<DownloadException>()),
      );
      await expectLater(
        svc.saveVideo(url: '', baseName: 'x'),
        throwsA(isA<DownloadException>()),
      );
    });

    test('网络超时翻译成可读原因', () async {
      downloader.error = DioException(
        requestOptions: RequestOptions(path: 'https://x/a.jpg'),
        type: DioExceptionType.connectionTimeout,
      );
      final svc = make(useGallery: false);
      await expectLater(
        svc.saveImage(url: 'https://x/a.jpg', baseName: 'x'),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            contains('网络超时'),
          ),
        ),
      );
    });

    test('文件名清洗与扩展名推断', () {
      expect(DownloadService.sanitizeBaseName('a/b:c d*e'), 'a_b_c_d_e');
      expect(DownloadService.sanitizeBaseName('  '), 'weiyue');
      expect(
        DownloadService.extensionOf('https://x/v.MP4?token=1', '.bin'),
        '.mp4',
      );
      expect(
        DownloadService.extensionOf('https://x/file.bin', '.jpg'),
        '.jpg',
        reason: '未知扩展回退默认',
      );
      expect(
        DownloadService.extensionOf('https://x/noext', '.mp4'),
        '.mp4',
      );
    });
  });
}
