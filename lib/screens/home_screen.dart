import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/session_service.dart';
import '../services/weiyue_service.dart';
import '../widgets/friends_feed_view.dart';
import '../widgets/group_feed_view.dart';
import '../widgets/hot_feed_view.dart';

/// 「关注」频道哨兵（登录后出现在频道行最前）：gid 用本地保留值，
/// 数据走 friendstimeline，不经 hottimeline 的 WbChannel 参数拼装。
const friendsChannel = WbChannel(
  gid: 'weiyue_friends',
  title: '关注',
  containerid: '10001',
);

/// 关注分组频道的 containerid 哨兵：分组频道复用 WbChannel 承载
/// （gid=分组 gid、title=组名），feed 按此标记分发到 GroupFeedView
/// （数据走分组时间线接口，不经 hottimeline）。
const groupChannelContainerId = 'weiyue_group';

/// 首页：热门推荐 + 子分类 chips（allGroups「我的频道」）；
/// 登录后最前面多一个「关注」频道（关注流）。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<WbChannel> _channels = const [];

  /// 关注分组频道（登录后追加在热门频道之后）：选中即一个保活
  /// 频道，与热门分类同机制（IndexedStack + _visited 懒创建）。
  List<WbChannel> _groupChannels = const [];
  String _groupsLoadedForUid = '';
  SessionService? _session;
  WbChannel? _selected;
  bool _loadingChannels = true;

  /// 已访问过的频道 key：访问过的频道视图在 IndexedStack 里保活
  /// （列表内容、分页游标、滚动位置都保留），切回来不重新请求；
  /// 未访问的频道先占位，首次点开才创建并加载一次。
  final Set<String> _visited = {};

  /// 各频道 feed 的刷新句柄（桌面端刷新按钮经 GlobalKey 调 State 的
  /// refresh）：与频道一一对应，随保活的 IndexedStack 一起常驻。
  final Map<String, GlobalKey<HotFeedViewState>> _feedKeys = {};
  final GlobalKey<FriendsFeedViewState> _friendsFeedKey = GlobalKey();
  final Map<String, GlobalKey<GroupFeedViewState>> _groupFeedKeys = {};

  static String _keyOf(WbChannel ch) => '${ch.gid}_${ch.containerid}';

  GlobalKey<HotFeedViewState> _feedKeyOf(WbChannel ch) =>
      _feedKeys.putIfAbsent(_keyOf(ch), () => GlobalKey<HotFeedViewState>());

  GlobalKey<GroupFeedViewState> _groupFeedKeyOf(WbChannel ch) =>
      _groupFeedKeys.putIfAbsent(
        _keyOf(ch),
        () => GlobalKey<GroupFeedViewState>(),
      );

  /// 完整频道行：关注（登录时）+ 热门分类 + 关注分组（登录时）。
  List<WbChannel> _allChannels(bool loggedIn) => [
    if (loggedIn) friendsChannel,
    ..._channels,
    if (loggedIn) ..._groupChannels,
  ];

  @override
  void initState() {
    super.initState();
    _session = context.read<SessionService>();
    _session!.addListener(_onSessionChanged);
    _loadChannels();
    if (_session!.isLoggedIn) _loadGroups();
  }

  @override
  void dispose() {
    _session?.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 登录态变化（页面打开后才登录/换号）时补拉分组；同一 uid
  /// 只拉一次，退出登录后频道行由 build 的 loggedIn 门控隐藏。
  void _onSessionChanged() {
    final s = _session;
    if (s == null || !s.isLoggedIn) return;
    if (_groupsLoadedForUid != s.uid) _loadGroups();
  }

  Future<void> _loadGroups() async {
    final uid = _session?.uid ?? '';
    _groupsLoadedForUid = uid;
    try {
      final groups = await context.read<WeiyueService>().getFollowGroups();
      if (!mounted) return;
      setState(() {
        _groupChannels = [
          for (final g in groups)
            WbChannel(
              gid: g.gid,
              title: g.title,
              containerid: groupChannelContainerId,
            ),
        ];
      });
    } catch (_) {
      // 分组拉取失败不影响首页：入口不出现即可（服务层已有缓存，
      // 下次登录态变化可再试）。
      if (mounted) setState(() => _groupChannels = const []);
    }
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
      return FriendsFeedView(key: _friendsFeedKey);
    }
    if (ch.containerid == groupChannelContainerId) {
      return GroupFeedView(
        key: _groupFeedKeyOf(ch),
        group: WbFollowGroup(gid: ch.gid, title: ch.title),
      );
    }
    return HotFeedView(
      key: _feedKeyOf(ch),
      channel: ch,
      homeTopSignalEnabled: true,
    );
  }

  /// 桌面端刷新按钮：只重拉当前选中频道的 feed（与下拉刷新走同一条
  /// _loadFirst 路径），其余频道的保活缓存不受影响。
  void _refreshCurrent() {
    final loggedIn = context.read<SessionService>().isLoggedIn;
    final channels = _allChannels(loggedIn);
    if (channels.isEmpty) return;
    final selected = _effectiveSelected(channels);
    final Future<void>? future;
    if (selected.gid == friendsChannel.gid) {
      future = _friendsFeedKey.currentState?.refresh();
    } else if (selected.containerid == groupChannelContainerId) {
      future = _groupFeedKeys[_keyOf(selected)]?.currentState?.refresh();
    } else {
      future = _feedKeys[_keyOf(selected)]?.currentState?.refresh();
    }
    if (future != null) unawaited(future);
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
    final channels = _allChannels(loggedIn);
    final selected = channels.isEmpty ? null : _effectiveSelected(channels);
    final selectedIndex = selected == null
        ? -1
        : channels.indexWhere((c) => _keyOf(c) == _keyOf(selected));
    // 当前显示的频道必须在保活集合里（回落选中等无点击路径也覆盖）。
    if (selected != null) _visited.add(_keyOf(selected));
    return Scaffold(
      appBar: AppBar(
        title: const Text('微阅 · 热门'),
        centerTitle: false,
        actions: [
          // 桌面端没有下拉手势：宽屏（≥900，与应用既有宽屏断点一致）
          // 显示刷新按钮，只刷当前频道；窄屏不显示，继续下拉刷新。
          if (MediaQuery.sizeOf(context).width >= 900)
            IconButton(
              key: const ValueKey('home-refresh-button'),
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: _refreshCurrent,
            ),
        ],
      ),
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
