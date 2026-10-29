import '../models/models.dart';

/// 长图判定：高宽比 ≥ 2.5 视为长图（微博长图/长截图的常见形态）。
/// 尺寸来源优先接口数据（WbPic.width/height），缺失时由查看器
/// 在打开后用 ImageStream 解析真实尺寸再判定。
const double kLongImageRatio = 2.5;

/// [width]/[height] 为像素尺寸；任一缺失（≤0）返回 false。
bool isLongAspect(int width, int height) =>
    width > 0 && height > 0 && height / width >= kLongImageRatio;

/// 长图准入的统一收口（硬兜底）：帖子本级或转发原帖任一层含视频/直播
/// 时，整帖的图片一律不作长图处理——不标「长图」角标、不进长图阅读器。
///
/// 解析层已按 pic_ids / type 标记 / mix_media_info 分流剔除视频侧条目，
/// 这里再兜一层：即使某条数据形态漏网（帖级已识别出视频/直播），
/// UI 侧也绝不把它的图片长图化。所有调用点都应走这个判断，不要再
/// 各自拼 hasVideo/isLive 条件。
bool statusAllowsLongImage(WbStatus status) => !status.hasAnyMediaVideo;
