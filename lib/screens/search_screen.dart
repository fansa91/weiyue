import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ime.dart';
import '../models/models.dart';
import '../services/weiyue_service.dart';
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
  static const _historyKey = 'weiyue_search_history';
  static const _historyLimit = 12;

  late final _controller = TextEditingController(text: widget.initialKeyword);
  final _searchFocus = FocusNode();
  SearchResult? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int _segment = 0; // 0 综合 1 用户 2 微博
  List<String> _history = const [];
  Timer? _suggestDebounce;
  SearchSuggest? _suggest;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    // 桌面端 IME 缓解：搜索框获焦时把 IME 重新关联回窗口
    //（播放器原生窗口可能把 IME 上下文分离，见 core/ime.dart）。
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus) ensureImeAttached();
    });
    final kw = widget.initialKeyword?.trim() ?? '';
    if (kw.isNotEmpty) {
      _keyword = kw;
      WidgetsBinding.instance.addPostFrameCallback((_) => _doSearch(kw));
    }
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _searchFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 输入防抖（约 300ms）拉搜索建议；清空输入则回到历史区。
  void _onQueryChanged(String value) {
    _suggestDebounce?.cancel();
    final q = value.trim();
    if (q.isEmpty) {
      if (_suggest != null) setState(() => _suggest = null);
      return;
    }
    _suggestDebounce =
        Timer(const Duration(milliseconds: 300), () => _fetchSuggest(q));
  }

  Future<void> _fetchSuggest(String q) async {
    try {
      final s = await context.read<WeiyueService>().getSearchSuggest(q);
      // 输入已变化/已提交搜索则丢弃这次结果，避免旧建议闪现
      if (!mounted || _controller.text.trim() != q || _result != null) return;
      setState(() => _suggest = s);
    } catch (_) {
      // 建议失败不打扰：保持历史/提示区
    }
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_historyKey) ?? const [];
      if (mounted) setState(() => _history = saved);
    } catch (_) {
      // 历史读取失败不影响搜索功能
    }
  }

  /// 提交搜索时记录：最新在前、去重、上限 [_historyLimit] 条。
  Future<void> _recordHistory(String keyword) async {
    final next = <String>[
      keyword,
      for (final h in _history)
        if (h != keyword) h,
    ].take(_historyLimit).toList();
    if (mounted) setState(() => _history = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyKey, next);
    } catch (_) {}
  }

  Future<void> _clearHistory() async {
    if (mounted) setState(() => _history = const []);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
    } catch (_) {}
  }

  Future<void> _removeHistoryItem(String keyword) async {
    final next = _history.where((h) => h != keyword).toList();
    if (mounted) setState(() => _history = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyKey, next);
    } catch (_) {}
  }

  void _searchFromHistory(String keyword) {
    _controller.text = keyword;
    _doSearch(keyword);
  }

  Future<void> _doSearch(String kw) async {
    final keyword = kw.trim();
    if (keyword.isEmpty) return;
    _recordHistory(keyword);
    _suggestDebounce?.cancel();
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _keyword = keyword;
      _segment = 0;
      _suggest = null;
    });
    try {
      final result = await context.read<WeiyueService>().search(keyword);
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
          focusNode: _searchFocus,
          autofocus: widget.autofocus,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索动态 / 用户',
            border: InputBorder.none,
            filled: false,
          ),
          onSubmitted: _doSearch,
          onChanged: _onQueryChanged,
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
                      ButtonSegment(value: 2, label: Text('动态')),
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
      // 有输入且建议非空 → 建议列表；否则（空输入/无建议）→ 历史区
      final suggest = _suggest;
      if (_controller.text.trim().isNotEmpty &&
          suggest != null &&
          !suggest.isEmpty) {
        return _buildSuggestions(suggest);
      }
      return _buildHistoryOrHint();
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

  /// 输入中的建议列表：联想词行（点→直接搜该词）+ 推荐用户行（点→主页）。
  Widget _buildSuggestions(SearchSuggest suggest) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      children: [
        for (final q in suggest.queries)
          ListTile(
            leading: Icon(Icons.search, size: 20, color: cs.onSurfaceVariant),
            title: Text(q),
            dense: true,
            onTap: () {
              _controller.text = q;
              _doSearch(q);
            },
          ),
        if (suggest.users.isNotEmpty) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('推荐用户',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
          ),
          for (final u in suggest.users) UserTile(user: u),
        ],
      ],
    );
  }

  /// 无结果时：有历史则展示「搜索历史」区（点击直达搜索，
  /// 支持单条删除与一键清空），没有历史则展示输入提示。
  Widget _buildHistoryOrHint() {
    if (_history.isEmpty) {
      return const Center(child: Text('输入关键词搜索动态与用户'));
    }
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        Row(
          children: [
            Icon(Icons.history, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            const Text('搜索历史',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton(
              onPressed: _clearHistory,
              child: const Text('清空'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final h in _history)
              InputChip(
                label: Text(h),
                onPressed: () => _searchFromHistory(h),
                onDeleted: () => _removeHistoryItem(h),
                deleteIcon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ],
    );
  }
}
