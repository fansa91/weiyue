import 'package:flutter/material.dart';

/// 详情页脚手架：宽屏时正文限宽居中（微博是窄列内容），窄屏全宽。
class DetailScaffold extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const DetailScaffold({super.key, required this.child, this.maxWidth = 680});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}
