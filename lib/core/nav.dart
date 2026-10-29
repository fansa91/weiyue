import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../models/models.dart';
import '../screens/detail_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/topic_screen.dart';
import '../widgets/detail_scaffold.dart';

/// 按平台生成二级页路由（换壳第一阶段的转场分流）：
/// Windows 用 Fluent 的 DrillIn 转场、iOS/macOS 用 Cupertino 推入、
/// 其余用 Material 转场。所有 push 入口统一走这里，调用点不感知壳差异。
PageRoute<T> appPageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
}) {
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => fluent.FluentPageRoute<T>(
        builder: builder,
        settings: settings,
      ),
    TargetPlatform.iOS ||
    TargetPlatform.macOS =>
      CupertinoPageRoute<T>(builder: builder, settings: settings),
    _ => MaterialPageRoute<T>(builder: builder, settings: settings),
  };
}

void openProfile(BuildContext context, int uid) {
  if (uid <= 0) return;
  Navigator.of(context).push(appPageRoute(
    builder: (_) => DetailScaffold(child: ProfileScreen(uid: '$uid')),
  ));
}

/// 打开详情：视频帖也在详情页内嵌预览播放，不再有独立播放页。
void openDetail(BuildContext context, WbStatus status) {
  Navigator.of(context).push(appPageRoute(
    builder: (_) => DetailScaffold(child: DetailScreen(status: status)),
  ));
}

/// 打开话题页。[token] 可以是正文里的原始分段（含两端 #）或裸话题名。
void openTopic(BuildContext context, String token) {
  final topic = token.replaceAll(RegExp(r'^#+|#+$'), '').trim();
  if (topic.isEmpty) return;
  Navigator.of(context).push(appPageRoute(
    builder: (_) => DetailScaffold(child: TopicScreen(topic: topic)),
  ));
}
