/// API 返回的图片多为 http 链接，https 页面 / App 内统一转成 https，
/// 避免 Web 端 Mixed Content 被拦截。
String httpsUrl(String? url) {
  if (url == null || url.isEmpty) return '';
  if (url.startsWith('http://')) {
    return 'https://${url.substring(7)}';
  }
  return url;
}

/// 网易云图片裁剪参数：空 URL 或已带参数时原样返回，避免拼出坏链接
String thumb(String url, int size) {
  if (url.isEmpty || url.contains('?')) return url;
  return '$url?param=${size}y$size';
}

String formatPlayCount(int count) {
  if (count >= 100000000) {
    return '${(count / 100000000).toStringAsFixed(1)}亿';
  }
  if (count >= 10000) {
    return '${(count / 10000).toStringAsFixed(1)}万';
  }
  return '$count';
}

String formatDuration(int ms) {
  if (ms <= 0) return '--:--';
  final totalSec = ms ~/ 1000;
  final m = totalSec ~/ 60;
  final s = totalSec % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String formatDate(int msEpoch) {
  if (msEpoch <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(msEpoch);
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}

/// 秒数时长（视频）：703 → "11:43"，超过 1 小时带小时位
String formatDurationSec(num sec) {
  if (sec <= 0) return '--:--';
  final total = sec.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// 相对时间展示：刚刚 / N分钟前 / N小时前 / 昨天 / 日期
String formatTimeAgo(DateTime? dt, {String fallback = ''}) {
  if (dt == null) return fallback;
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays == 1) return '昨天';
  if (diff.inDays < 7) return '${diff.inDays}天前';
  if (dt.year == now.year) return '${dt.month}月${dt.day}日';
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}

int intOf(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// 视频是否为横屏尺寸（宽 > 高）。宽高未知（任一为 null 或 <=0）按非横屏处理，
/// 播放器据此决定移动端全屏方向：横屏视频才强制横屏，竖屏/方形保持竖屏。
bool isLandscapeVideoSize(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return false;
  }
  return width > height;
}
