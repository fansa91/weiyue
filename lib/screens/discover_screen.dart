import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/nav.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/weiyue_service.dart';
import 'band_screen.dart';
import 'search_screen.dart';

/// 发现：搜索入口 + 热搜榜 + band 分类词榜入口
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  HotWord? _gov;
  List<HotWord> _words = const [];
  bool _loading = true;
  String? _error;

  static const _bands = [
    ('娱乐', 'entertainment', Icons.movie_outlined),
    ('生活', 'life', Icons.restaurant_outlined),
    ('社会', 'social', Icons.groups_outlined),
    ('科技', 'technology', Icons.smartphone_outlined),
    ('体育', 'sport', Icons.sports_basketball_outlined),
    ('动漫', 'acg', Icons.animation_outlined),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<WeiyueService>().getHotSearch();
      if (!mounted) return;
      setState(() {
        _gov = r.gov;
        _words = r.words;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _search(String keyword) {
    final kw = keyword.replaceAll('#', '').trim();
    if (kw.isEmpty) return;
    Navigator.of(
      context,
    ).push(appPageRoute(builder: (_) => SearchScreen(initialKeyword: kw)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('发现'), centerTitle: false),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            // 搜索框（跳搜索页）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => Navigator.of(context).push(
                  appPageRoute(
                    builder: (_) => const SearchScreen(autofocus: true),
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search, size: 19, color: cs.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Text(
                        '搜索动态 / 用户',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // band 分类入口
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
              child: Text(
                '分类热词榜',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 4,
                children: [
                  for (final (name, segment, icon) in _bands)
                    ActionChip(
                      avatar: Icon(icon, size: 17),
                      label: Text(name),
                      onPressed: () => Navigator.of(context).push(
                        appPageRoute(
                          builder: (_) =>
                              BandScreen(title: name, segment: segment),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
              child: Text(
                '热搜榜',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    FilledButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              )
            else ...[
              if (_gov != null)
                _HotRow(
                  rank: 0,
                  word: _gov!,
                  pinned: true,
                  onTap: () => _search(_gov!.word),
                ),
              for (var i = 0; i < _words.length; i++)
                _HotRow(
                  rank: i + 1,
                  word: _words[i],
                  onTap: () => _search(_words[i].word),
                ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

class _HotRow extends StatelessWidget {
  final int rank;
  final HotWord word;
  final bool pinned;
  final VoidCallback onTap;
  const _HotRow({
    required this.rank,
    required this.word,
    this.pinned = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rankColor = rank == 1
        ? const Color(0xFFE6162D)
        : rank == 2
        ? const Color(0xFFF07C22)
        : rank == 3
        ? const Color(0xFFF5A623)
        : cs.onSurfaceVariant;
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 26,
        child: pinned
            ? Icon(Icons.push_pin, size: 17, color: cs.primary)
            : Text(
                '$rank',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: rankColor,
                ),
              ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              word.word,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (word.label.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: _labelColor(word.label),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                word.label,
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ],
          if (word.flagDesc.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              word.flagDesc,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
      trailing: word.num > 0
          ? Text(
              formatPlayCount(word.num),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            )
          : null,
      onTap: onTap,
    );
  }

  Color _labelColor(String label) {
    switch (label) {
      case '爆':
        return const Color(0xFFBD0000);
      case '热':
        return const Color(0xFFFF9406);
      case '新':
        return const Color(0xFFFF3852);
      default:
        return const Color(0xFF888888);
    }
  }
}
