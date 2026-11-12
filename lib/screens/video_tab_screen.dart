import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/hot_feed_view.dart';

/// 视频页签：推荐（热门）+ 视频向分类，拉 hottimeline 后过滤带视频的条目。
class VideoTabScreen extends StatefulWidget {
  const VideoTabScreen({super.key});

  @override
  State<VideoTabScreen> createState() => _VideoTabScreenState();
}

class _VideoTabScreenState extends State<VideoTabScreen> {
  // 名称 → 期望在 allGroups 里按名匹配；匹配不到按文档码表规律兜底拼装
  static const _tabs = <String, WbChannel?>{
    '推荐': WbChannel(gid: '102803', title: '推荐', containerid: '102803'),
    '短剧': WbChannel(
      gid: '102803600410',
      title: '短剧',
      containerid: '102803_ctg1_600410_-_ctg1_600410',
    ),
    '电影': WbChannel(
      gid: '1028033288',
      title: '电影',
      containerid: '102803_ctg1_3288_-_ctg1_3288',
    ),
    '电视剧': WbChannel(
      gid: '1028032488',
      title: '电视剧',
      containerid: '102803_ctg1_2488_-_ctg1_2488',
    ),
    '综艺': WbChannel(
      gid: '1028034688',
      title: '综艺',
      containerid: '102803_ctg1_4688_-_ctg1_4688',
    ),
    '游戏': WbChannel(
      gid: '1028034888',
      title: '游戏',
      containerid: '102803_ctg1_4888_-_ctg1_4888',
    ),
  };

  String _selectedName = '推荐';
  final Map<String, WbChannel> _resolved = {};

  /// 各分类 feed 的刷新句柄（桌面端刷新按钮经 GlobalKey 调 State 的
  /// refresh）：与分类名一一对应，随保活的 IndexedStack 一起常驻。
  final Map<String, GlobalKey<HotFeedViewState>> _feedKeys = {};

  GlobalKey<HotFeedViewState> _feedKeyOf(String name) =>
      _feedKeys.putIfAbsent(name, () => GlobalKey<HotFeedViewState>());

  /// 桌面端刷新按钮：只重拉当前选中分类的 feed（与下拉刷新走同一条
  /// _loadFirst 路径），其余分类的保活缓存不受影响。
  void _refreshCurrent() {
    final future = _feedKeys[_selectedName]?.currentState?.refresh();
    if (future != null) unawaited(future);
  }

  /// 已访问过的分类名：访问过的分类视图在 IndexedStack 里保活
  /// （列表、分页、滚动位置都保留），切回来不重新请求；
  /// 未访问的先占位，首次点开才创建并加载一次。
  final Set<String> _visited = {'推荐'};

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final svc = context.read<WeiyueService>();
    for (final name in _tabs.keys) {
      if (name == '推荐') continue;
      final ch = await svc.channelByTitle(name);
      if (ch != null) _resolved[name] = ch;
    }
    if (mounted) setState(() {});
  }

  WbChannel _channelFor(String name) => _resolved[name] ?? _tabs[name]!;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final names = _tabs.keys.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('视频'),
        centerTitle: false,
        actions: [
          // 桌面端没有下拉手势：宽屏（≥900，与应用既有宽屏断点一致）
          // 显示刷新按钮，只刷当前分类；窄屏不显示，继续下拉刷新。
          if (MediaQuery.sizeOf(context).width >= 900)
            IconButton(
              key: const ValueKey('video-refresh-button'),
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: _refreshCurrent,
            ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              children: [
                for (final name in names)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(name),
                      selected: _selectedName == name,
                      onSelected: (_) {
                        _visited.add(name);
                        setState(() => _selectedName = name);
                      },
                      selectedColor: cs.primaryContainer,
                      showCheckmark: false,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: IndexedStack(
              index: names.indexOf(_selectedName),
              children: [
                for (final name in names)
                  if (name == _selectedName || _visited.contains(name))
                    HotFeedView(
                      key: _feedKeyOf(name),
                      channel: _channelFor(name),
                      filter: (s) =>
                          s.hasVideo || (s.retweeted?.hasVideo ?? false),
                      emptyText: '该分类暂未刷到视频，下拉刷新试试',
                    )
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
