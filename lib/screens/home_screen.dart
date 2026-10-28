import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/session_service.dart';
import '../services/weiyue_service.dart';
import '../widgets/friends_feed_view.dart';
import '../widgets/hot_feed_view.dart';

/// 「关注」频道哨兵（登录后出现在频道行最前）：gid 用本地保留值，
/// 数据走 friendstimeline，不经 hottimeline 的 WbChannel 参数拼装。
const friendsChannel = WbChannel(
  gid: 'weiyue_friends',
  title: '关注',
  containerid: '10001',
);

/// 首页：热门推荐 + 子分类 chips（allGroups「我的频道」）；
/// 登录后最前面多一个「关注」频道（关注流）。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<WbChannel> _channels = const [];
  WbChannel? _selected;
  bool _loadingChannels = true;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    final result = await context.read<WeiyueService>().getChannels();
    if (!mounted) return;
    setState(() {
      _channels = result.mine;
      _selected = result.mine.isNotEmpty
          ? result.mine.first
          : WeiyueService.fallbackChannels.first;
      _loadingChannels = false;
    });
  }

  /// 当前选中频道：选中项已不在列表里（如退出登录后「关注」消失）
  /// 时回落到第一个。
  WbChannel _effectiveSelected(List<WbChannel> channels) {
    final sel = _selected;
    if (sel != null &&
        channels.any(
          (c) => c.gid == sel.gid && c.containerid == sel.containerid,
        )) {
      return sel;
    }
    return channels.first;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loggedIn = context.watch<SessionService>().isLoggedIn;
    final channels = [if (loggedIn) friendsChannel, ..._channels];
    final selected = channels.isEmpty ? null : _effectiveSelected(channels);
    return Scaffold(
      appBar: AppBar(title: const Text('微阅 · 热门'), centerTitle: false),
      body: Column(
        children: [
          // 分类 chips
          SizedBox(
            height: 46,
            child: _loadingChannels
                ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    itemCount: channels.length,
                    itemBuilder: (context, i) {
                      final ch = channels[i];
                      final isSelected =
                          selected?.gid == ch.gid &&
                          selected?.containerid == ch.containerid;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(ch.title),
                          selected: isSelected,
                          onSelected: (_) => setState(() => _selected = ch),
                          selectedColor: cs.primaryContainer,
                          showCheckmark: false,
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Expanded(
            child: selected == null
                ? const SizedBox.shrink()
                : selected.gid == friendsChannel.gid
                ? const FriendsFeedView(key: ValueKey('friends_feed'))
                : HotFeedView(
                    key: ValueKey('${selected.gid}_${selected.containerid}'),
                    channel: selected,
                    homeTopSignalEnabled: true,
                  ),
          ),
        ],
      ),
    );
  }
}
