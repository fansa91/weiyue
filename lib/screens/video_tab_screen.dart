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
        containerid: '102803_ctg1_600410_-_ctg1_600410'),
    '电影': WbChannel(
        gid: '1028033288',
        title: '电影',
        containerid: '102803_ctg1_3288_-_ctg1_3288'),
    '电视剧': WbChannel(
        gid: '1028032488',
        title: '电视剧',
        containerid: '102803_ctg1_2488_-_ctg1_2488'),
    '综艺': WbChannel(
        gid: '1028034688',
        title: '综艺',
        containerid: '102803_ctg1_4688_-_ctg1_4688'),
    '游戏': WbChannel(
        gid: '1028034888',
        title: '游戏',
        containerid: '102803_ctg1_4888_-_ctg1_4888'),
  };

  String _selectedName = '推荐';
  final Map<String, WbChannel> _resolved = {};

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

  WbChannel _channelFor(String name) =>
      _resolved[name] ?? _tabs[name]!;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final channel = _channelFor(_selectedName);
    return Scaffold(
      appBar: AppBar(title: const Text('视频'), centerTitle: false),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            children: [
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  children: [
                    for (final name in _tabs.keys)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(name),
                          selected: _selectedName == name,
                          onSelected: (_) =>
                              setState(() => _selectedName = name),
                          selectedColor: cs.primaryContainer,
                          showCheckmark: false,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: HotFeedView(
                  key: ValueKey('video_${channel.gid}'),
                  channel: channel,
                  filter: (s) => s.hasVideo || (s.retweeted?.hasVideo ?? false),
                  emptyText: '该分类暂未刷到视频，下拉刷新试试',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
