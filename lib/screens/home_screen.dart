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

  /// 已访问过的频道 key：访问过的频道视图在 IndexedStack 里保活
  /// （列表内容、分页游标、滚动位置都保留），切回来不重新请求；
  /// 未访问的频道先占位，首次点开才创建并加载一次。
  final Set<String> _visited = {};

  static String _keyOf(WbChannel ch) => '${ch.gid}_${ch.containerid}';

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    final result = await context.read<WeiyueService>().getChannels();
    if (!mounted) return;
    final initial = result.mine.isNotEmpty
        ? result.mine.first
        : WeiyueService.fallbackChannels.first;
    setState(() {
      _channels = result.mine;
      _selected = initial;
      _visited.add(_keyOf(initial));
      _loadingChannels = false;
    });
  }

  Widget _feedFor(WbChannel ch) {
    if (ch.gid == friendsChannel.gid) {
      return const FriendsFeedView(key: ValueKey('friends_feed'));
    }
    return HotFeedView(
      key: ValueKey(_keyOf(ch)),
      channel: ch,
      homeTopSignalEnabled: true,
    );
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
    final selectedIndex = selected == null
        ? -1
        : channels.indexWhere((c) => _keyOf(c) == _keyOf(selected));
    // 当前显示的频道必须在保活集合里（回落选中等无点击路径也覆盖）。
    if (selected != null) _visited.add(_keyOf(selected));
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
                          onSelected: (_) {
                            _visited.add(_keyOf(ch));
                            setState(() => _selected = ch);
                          },
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
                : IndexedStack(
                    index: selectedIndex,
                    children: [
                      for (var i = 0; i < channels.length; i++)
                        if (i == selectedIndex ||
                            _visited.contains(_keyOf(channels[i])))
                          _feedFor(channels[i])
                        else
                          const SizedBox.shrink(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
