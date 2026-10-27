import 'package:flutter/material.dart';

import '../models/models.dart';
import '../screens/detail_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/topic_screen.dart';
import '../widgets/detail_scaffold.dart';

void openProfile(BuildContext context, int uid) {
  if (uid <= 0) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => DetailScaffold(child: ProfileScreen(uid: '$uid')),
  ));
}

/// 打开详情：视频帖也在详情页内嵌预览播放，不再有独立播放页。
void openDetail(BuildContext context, WbStatus status) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => DetailScaffold(child: DetailScreen(status: status)),
  ));
}

/// 打开话题页。[token] 可以是正文里的原始分段（含两端 #）或裸话题名。
void openTopic(BuildContext context, String token) {
  final topic = token.replaceAll(RegExp(r'^#+|#+$'), '').trim();
  if (topic.isEmpty) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => DetailScaffold(child: TopicScreen(topic: topic)),
  ));
}
