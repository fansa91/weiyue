import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weibo_service.dart';
import '../widgets/status_card.dart';
import '../widgets/user_tile.dart';

/// 搜索（m 端 container 全文搜索，访客态唯一可用的搜索 JSON）。
/// 综合页一次返回后本地拆分：用户卡来自 card_type=11 分组里的
/// card_type=10（带 user 对象），微博卡来自顶层 card_type=9 与分组内
/// card_type=9（带 mblog）；card_type=6 的「更多」链接卡忽略。
/// 分段用同一份结果本地过滤，不重复请求。
class SearchScreen extends StatefulWidget {
  final String? initialKeyword;
  final bool autofocus;
  const SearchScreen({super.key, this.initialKeyword, this.autofocus = false});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final _controller = TextEditingController(text: widget.initialKeyword);
  SearchResult? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int _segment = 0; // 0 综合 1 用户 2 微博

  @override
  void initState() {
    super.initState();
    final kw = widget.initialKeyword?.trim() ?? '';
    if (kw.isNotEmpty) {
      _keyword = kw;
      WidgetsBinding.instance.addPostFrameCallback((_) => _doSearch(kw));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String kw) async {
    final keyword = kw.trim();
    if (keyword.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _keyword = keyword;
      _segment = 0;
    });
    try {
      final result = await context.read<WeiboService>().search(keyword);
      if (!mounted) return;
      setState(() {
        _result = result;
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
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: widget.autofocus,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索微博 / 用户',
            border: InputBorder.none,
            filled: false,
          ),
          onSubmitted: _doSearch,
        ),
        actions: [
          TextButton(
            onPressed: () => _doSearch(_controller.text),
            child: const Text('搜索'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            children: [
              if (_result != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('综合')),
                      ButtonSegment(value: 1, label: Text('用户')),
                      ButtonSegment(value: 2, label: Text('微博')),
                    ],
                    selected: {_segment},
                    onSelectionChanged: (s) =>
                        setState(() => _segment = s.first),
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStatePropertyAll(
                          TextStyle(color: cs.onSurface, fontSize: 13)),
                    ),
                  ),
                ),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            FilledButton(
                onPressed: () => _doSearch(_keyword),
                child: const Text('重试')),
          ],
        ),
      );
    }
    final result = _result;
    if (result == null) {
      return const Center(child: Text('输入关键词搜索微博与用户'));
    }
    final showUsers = _segment != 2;
    final showStatuses = _segment != 1;
    final children = <Widget>[];
    if (showUsers) {
      for (final u in result.users) {
        children.add(UserTile(user: u));
      }
    }
    if (showStatuses) {
      for (final s in result.statuses) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: StatusCard(status: s),
        ));
      }
    }
    if (children.isEmpty) {
      return const Center(child: Text('没有找到相关结果'));
    }
    return ListView(children: children);
  }
}
