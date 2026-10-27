/// 长图判定：高宽比 ≥ 2.5 视为长图（微博长图/长截图的常见形态）。
/// 尺寸来源优先接口数据（WbPic.width/height），缺失时由查看器
/// 在打开后用 ImageStream 解析真实尺寸再判定。
const double kLongImageRatio = 2.5;

/// [width]/[height] 为像素尺寸；任一缺失（≤0）返回 false。
bool isLongAspect(int width, int height) =>
    width > 0 && height > 0 && height / width >= kLongImageRatio;
