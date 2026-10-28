/// 默认清晰度设置（设置页 / 播放器 / 图片查看共用）。
///
/// 视频档位按播放档高度（p）选档：取「高度 ≤ 上限的最高档」，
/// 没有符合的档时取最低档（保证仍可播）；档位高度未知（0）时不参与上限比较。
enum VideoQualityPref {
  /// 自动：沿用旧默认（≤720p 的最高档，没有则最低档）。
  auto('自动', 720),

  /// 流畅：≤360p 的最高档。
  smooth('流畅', 360),

  /// 标清：≤480p 的最高档。
  standard('标清', 480),

  /// 高清：≤720p 的最高档。
  hd('高清', 720),

  /// 超清：≤1080p 的最高档。
  fullHd('超清', 1080),

  /// 最高：不限高度，取档位表第一档（档位表按高度降序）。
  highest('最高', null);

  const VideoQualityPref(this.label, this.maxHeight);
  final String label;

  /// 该档位的高度上限（p），null 表示不限。
  final int? maxHeight;
}

/// 图片默认清晰度：决定列表与查看器用 WbPic 的哪一档 URL。
///
/// - 标准（现状）：列表中图、图库大图、长图查看原图。
/// - 高清：列表大图、图库原图、长图查看原图。
/// - 原图：列表原图、图库原图、长图查看原图。
/// - 省流量：列表缩略图、图库中图、长图查看中图。
enum ImageQualityPref {
  standard('标准'),
  hd('高清'),
  original('原图'),
  dataSaver('省流量');

  const ImageQualityPref(this.label);
  final String label;
}
