import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weibo_service.dart';
import '../widgets/hot_feed_view.dart';

/// 首页：热门推荐 + 子分类 chips（allGroups「我的频道」）
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
    final result = await context.read<WeiboService>().getChannels();
    if (!mounted) return;
    setState(() {
      _channels = result.mine;
      _selected = result.mine.isNotEmpty
          ? result.mine.first
          : WeiboService.fallbackChannels.first;
      _loadingChannels = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('微博 · 热门'),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
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
                            horizontal: 10, vertical: 7),
                        itemCount: _channels.length,
                        itemBuilder: (context, i) {
                          final ch = _channels[i];
                          final selected = _selected?.gid == ch.gid &&
                              _selected?.containerid == ch.containerid;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(ch.title),
                              selected: selected,
                              onSelected: (_) =>
                                  setState(() => _selected = ch),
                              selectedColor: cs.primaryContainer,
                              showCheckmark: false,
                            ),
                          );
                        },
                      ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _selected == null
                    ? const SizedBox.shrink()
                    : HotFeedView(
                        key: ValueKey(
                            '${_selected!.gid}_${_selected!.containerid}'),
                        channel: _selected!,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
