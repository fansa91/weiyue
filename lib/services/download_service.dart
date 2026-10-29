import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

/// 下载进度回调：已接收字节 / 总字节（未知为 -1）。
typedef DownloadProgress = void Function(int received, int total);

/// 下载/保存失败（message 为可直接展示给用户的可读原因）。
class DownloadException implements Exception {
  final String message;
  const DownloadException(this.message);
  @override
  String toString() => message;
}

/// 保存结果：相册或文件路径二选一，[describe] 是给用户的完成提示。
class DownloadResult {
  final bool savedToGallery;
  final String? filePath;

  const DownloadResult.gallery()
      : savedToGallery = true,
        filePath = null;

  const DownloadResult.file(String path)
      : savedToGallery = false,
        filePath = path;

  String get describe =>
      savedToGallery ? '已保存到相册' : '已保存到 $filePath';
}

/// 相册保存后端（可注入，测试用假后端替代，避免真调 gal 平台通道）。
abstract class GallerySaver {
  Future<void> saveImageBytes(List<int> bytes, {required String name});
  Future<void> saveVideoFile(String filePath);
}

/// gal 实现：图片 putImageBytes、视频 putVideo（入参为本地文件路径）。
class GalGallerySaver implements GallerySaver {
  @override
  Future<void> saveImageBytes(List<int> bytes, {required String name}) async {
    try {
      await Gal.putImageBytes(Uint8List.fromList(bytes), name: name);
    } on GalException catch (e) {
      throw DownloadException('保存到相册失败：${e.type.message}');
    }
  }

  @override
  Future<void> saveVideoFile(String filePath) async {
    try {
      await Gal.putVideo(filePath);
    } on GalException catch (e) {
      throw DownloadException('保存到相册失败：${e.type.message}');
    }
  }
}

/// 流式下载后端（可注入）：视频等大文件必须走 [downloadToFile]
/// 流式落盘，不整段载入内存。
abstract class StreamDownloader {
  Future<void> downloadToFile(
    String url,
    File file, {
    DownloadProgress? onProgress,
  });

  Future<List<int>> downloadBytes(String url, {DownloadProgress? onProgress});
}

/// Dio 实现：download 内部流式写文件；get(bytes) 只用于图片小文件。
class DioStreamDownloader implements StreamDownloader {
  final Dio _dio;

  DioStreamDownloader([Dio? dio])
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(minutes: 10),
              ),
            );

  @override
  Future<void> downloadToFile(
    String url,
    File file, {
    DownloadProgress? onProgress,
  }) async {
    await _dio.download(
      url,
      file.path,
      onReceiveProgress: onProgress,
      deleteOnError: true,
    );
  }

  @override
  Future<List<int>> downloadBytes(
    String url, {
    DownloadProgress? onProgress,
  }) async {
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
      onReceiveProgress: onProgress,
    );
    return resp.data ?? const [];
  }
}

/// 图片/视频保存到本地：
/// - Android/iOS → 系统相册（gal；图片传字节，视频先流式下到临时文件
///   再 putVideo，完成后删临时文件）；
/// - Windows/macOS/Linux → 用户下载目录（path_provider），流式落盘，
///   文件名由调用方给的 baseName + URL 扩展名拼成，重名自动加后缀。
class DownloadService {
  final StreamDownloader _downloader;
  final GallerySaver _gallerySaver;
  final Future<Directory?> Function() _downloadsDirectory;
  final Future<Directory> Function() _tempDirectory;
  final bool _useGallery;

  DownloadService({
    StreamDownloader? downloader,
    GallerySaver? gallerySaver,
    Future<Directory?> Function()? downloadsDirectory,
    Future<Directory> Function()? tempDirectory,
    bool? useGallery,
  })  : _downloader = downloader ?? DioStreamDownloader(),
        _gallerySaver = gallerySaver ?? GalGallerySaver(),
        _downloadsDirectory = downloadsDirectory ?? getDownloadsDirectory,
        _tempDirectory = tempDirectory ?? getTemporaryDirectory,
        _useGallery = useGallery ?? (Platform.isAndroid || Platform.isIOS);

  /// 应用内共享实例（按钮默认用它；测试可注入替身）。
  static final DownloadService shared = DownloadService();

  /// 当前平台是否走相册（移动端）。
  bool get useGallery => _useGallery;

  Future<DownloadResult> saveImage({
    required String url,
    required String baseName,
    DownloadProgress? onProgress,
  }) async {
    if (url.isEmpty) throw const DownloadException('图片地址为空');
    final stem = sanitizeBaseName(baseName);
    final fileName = '$stem${extensionOf(url, '.jpg')}';
    if (_useGallery) {
      final bytes = await _guard(
        () => _downloader.downloadBytes(url, onProgress: onProgress),
      );
      if (bytes.isEmpty) throw const DownloadException('图片下载为空');
      await _guard(() => _gallerySaver.saveImageBytes(bytes, name: stem));
      return const DownloadResult.gallery();
    }
    final file = await _uniqueFile(await _requireDownloadsDir(), fileName);
    await _guard(
      () => _downloader.downloadToFile(url, file, onProgress: onProgress),
    );
    return DownloadResult.file(file.path);
  }

  Future<DownloadResult> saveVideo({
    required String url,
    required String baseName,
    DownloadProgress? onProgress,
  }) async {
    if (url.isEmpty) throw const DownloadException('视频地址为空');
    final fileName = '${sanitizeBaseName(baseName)}${extensionOf(url, '.mp4')}';
    if (_useGallery) {
      // 视频先进临时文件（流式），再交给相册，随后清理临时文件。
      final tempDir = await _tempDirectory();
      final tempFile = await _uniqueFile(tempDir, fileName);
      try {
        await _guard(
          () => _downloader.downloadToFile(url, tempFile, onProgress: onProgress),
        );
        await _guard(() => _gallerySaver.saveVideoFile(tempFile.path));
      } finally {
        if (await tempFile.exists()) {
          try {
            await tempFile.delete();
          } catch (_) {}
        }
      }
      return const DownloadResult.gallery();
    }
    final file = await _uniqueFile(await _requireDownloadsDir(), fileName);
    await _guard(
      () => _downloader.downloadToFile(url, file, onProgress: onProgress),
    );
    return DownloadResult.file(file.path);
  }

  /// 把后端异常统一翻译成可读的 DownloadException。
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DownloadException {
      rethrow;
    } on DioException catch (e) {
      final detail = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout =>
          '网络超时',
        DioExceptionType.badResponse =>
          '服务器返回 ${e.response?.statusCode ?? '错误'}',
        _ => '网络错误',
      };
      throw DownloadException('下载失败：$detail');
    } catch (e) {
      throw DownloadException('保存失败：$e');
    }
  }

  Future<Directory> _requireDownloadsDir() async {
    final dir = await _downloadsDirectory();
    if (dir == null) throw const DownloadException('无法确定下载目录');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 目标文件重名时依次加 _1、_2… 后缀，绝不覆盖既有文件。
  Future<File> _uniqueFile(Directory dir, String fileName) async {
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    var candidate = File('${dir.path}${Platform.pathSeparator}$fileName');
    var n = 1;
    while (await candidate.exists()) {
      candidate = File(
        '${dir.path}${Platform.pathSeparator}${stem}_$n$ext',
      );
      n++;
    }
    return candidate;
  }

  /// 文件名清洗：路径分隔符与非法字符换下划线，空白折叠。
  static String sanitizeBaseName(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), '_');
    if (s.isEmpty) s = 'weiyue';
    if (s.length > 60) s = s.substring(0, 60);
    return s;
  }

  static const _knownExts = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.mp4', '.mov', '.m4v',
  };

  /// 从 URL 路径取扩展名（已知媒体扩展才用），否则用 [fallback]。
  static String extensionOf(String url, String fallback) {
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot >= 0 && dot >= path.length - 6) {
      final ext = path.substring(dot).toLowerCase();
      if (_knownExts.contains(ext)) return ext;
    }
    return fallback;
  }
}
