import 'package:flutter/material.dart';

/// 二级页脚手架：内容铺满可用宽度。
///
/// 历史教训（v0.1.3 真机反馈）：早期这里给正文加了 680px 居中封顶，
/// 结果详情页的 ≥900 双栏分支、主页等页面的宽屏布局在真机上永远
/// 触发不了（LayoutBuilder 拿到的宽度被封顶先截断）。桌面端要铺满，
/// 窄列/双栏等布局决策交给各页面自己按真实宽度做，不在这里截断。
class DetailScaffold extends StatelessWidget {
  final Widget child;
  const DetailScaffold({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: child);
  }
}
