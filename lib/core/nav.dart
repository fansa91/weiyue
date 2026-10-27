import 'package:flutter/material.dart';

import '../models/models.dart';
import '../screens/detail_screen.dart';
import '../screens/player_screen.dart';
import '../screens/profile_screen.dart';
import '../widgets/detail_scaffold.dart';

void openProfile(BuildContext context, int uid) {
  if (uid <= 0) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => DetailScaffold(child: ProfileScreen(uid: '$uid')),
  ));
}

void openDetail(BuildContext context, WbStatus status) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => DetailScaffold(child: DetailScreen(status: status)),
  ));
}

void openPlayer(BuildContext context, WbStatus status) {
  Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => PlayerScreen(status: status),
  ));
}
