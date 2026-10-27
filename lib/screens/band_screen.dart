import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils.dart';
import '../models/models.dart';
import '../services/weibo_service.dart';
import 'search_screen.dart';

/// 分类热词榜（band_list）：点词跳搜索。
class BandScreen extends StatefulWidget {
  final String title;
  final String segment;
  const BandScreen({super.key, required this.title, required this.segment});

  @override
  State<BandScreen> createState() => _BandScreenState();
}

class _BandScreenState extends State<BandScreen> {
  List<BandItem> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items =
          await context.read<WeiboService>().getBand(widget.segment);
      if (!mounted) return;
      setState(() {
        _items = items;
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.title}热词榜')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!))
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        final rank = item.realpos > 0 ? item.realpos : i + 1;
                        return ListTile(
                          leading: SizedBox(
                            width: 28,
                            child: Text('$rank',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: rank <= 3
                                      ? const Color(0xFFE6162D)
                                      : cs.onSurfaceVariant,
                                )),
                          ),
                          title: Text(item.word),
                          subtitle: item.category.isNotEmpty
                              ? Text(item.category)
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (item.label.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Text(item.label,
                                      style: const TextStyle(
                                          color: Color(0xFFFF9406),
                                          fontSize: 12)),
                                ),
                              Text(formatPlayCount(item.num),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurfaceVariant)),
                            ],
                          ),
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(
                            builder: (_) =>
                                SearchScreen(initialKeyword: item.word),
                          )),
                        );
                      },
                    ),
        ),
      ),
    );
  }
}
