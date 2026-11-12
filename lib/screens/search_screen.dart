import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ime.dart';
import '../core/nav.dart';
import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/responsive_status_list.dart';
import '../widgets/status_card.dart';
import '../widgets/user_tile.dart';

/// 搜索（m 端 container 全文搜索，访客态唯一可用的搜索 JSON）。
/// 7 个分类各走自己的 `100103type={N}` 容器（2026-11-12 探针实证）：
/// 综合 1 / 实时 61 / 用户 3 / 视频 64 / 图片 63 / 话题 38 / 超话 98。
/// 每分类各自维护结果与分页：首次点开才加载，切换回来不重拉
/// （IndexedStack 保活，与首页分类保活同一原则）；关键词变化全部重置。
/// 分页：访客态专属分类第 2 页会被 302 跳登录——翻页失败静默按
/// 「没有更多」处理；综合保持原行为（只取第一页，不翻页）。
class SearchScreen extends StatefulWidget {
  final String? initialKeyword;
  final bool autofocus;
  const SearchScreen({super.key, this.initialKeyword, this.autofocus = false});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// 一个分类的独立状态：结果、分页游标与滚动位置都留在自己名下。
class _CategoryState {
  List<WbStatus> statuses = [];
  List<WbUser> users = [];
  List<WbTopicEntry> topics = [];
  bool loading = false;
  bool loadingMore = false;
  bool loaded = false;
  bool ended = false;
  String? error;

  /// 下一页页码（cardlistInfo.page 给出），加载第一页后更新。
  int nextPage = 2;
  final ScrollController scroll = ScrollController();

  bool get isEmpty => statuses.isEmpty && users.isEmpty && topics.isEmpty;
}

class _SearchScreenState extends State<SearchScreen> {
  static const _historyKey = 'weiyue_search_history';
  static const _historyLimit = 12;

  late final _controller = TextEditingController(text: widget.initialKeyword);
  final _searchFocus = FocusNode();
  bool _hasSearched = false;
  String _keyword = '';
  SearchCategory _category = SearchCategory.all;
  final Map<SearchCategory, _CategoryState> _states = {};
  final Set<SearchCategory> _visited = {};
  List<String> _history = const [];
  Timer? _suggestDebounce;
  SearchSuggest? _suggest;

  WeiyueService get _svc => context.read<WeiyueService>();

  @override
  void initState() {
    super.initState();
    _loadHistory();
    // 桌面端 IME 缓解：搜索框获焦时走第二轮组合处理
    //（落定版重新关联 + 焦点重启，见 core/ime.dart）。
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus) handleImeFocusGain(_searchFocus);
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
    for (final st in _states.values) {
      st.scroll.dispose();
    }
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
    _suggestDebounce = Timer(
      const Duration(milliseconds: 300),
      () => _fetchSuggest(q),
    );
  }

  Future<void> _fetchSuggest(String q) async {
    try {
      final s = await _svc.getSearchSuggest(q);
      // 输入已变化/已提交搜索则丢弃这次结果，避免旧建议闪现
      if (!mounted || _controller.text.trim() != q || _hasSearched) return;
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
    // 关键词变化：全部清类状态从零开始
    for (final st in _states.values) {
      st.scroll.dispose();
    }
    setState(() {
      _states.clear();
      _visited
        ..clear()
        ..add(SearchCategory.all);
      _keyword = keyword;
      _category = SearchCategory.all;
      _hasSearched = true;
      _suggest = null;
    });
    await _loadCategory(SearchCategory.all);
  }

  _CategoryState _stateFor(SearchCategory cat) {
    return _states.putIfAbsent(cat, () {
      final st = _CategoryState();
      st.scroll.addListener(() {
        if (st.scroll.hasClients &&
            st.scroll.position.pixels >=
                st.scroll.position.maxScrollExtent - 500) {
          _loadMore(cat);
        }
      });
      return st;
    });
  }

  void _selectCategory(SearchCategory cat) {
    if (_category == cat) return;
    setState(() {
      _category = cat;
      _visited.add(cat);
    });
    _loadCategory(cat);
  }

  Future<void> _loadCategory(SearchCategory cat) async {
    final st = _stateFor(cat);
    if (st.loaded || st.loading) return;
    setState(() {
      st.loading = true;
      st.error = null;
    });
    try {
      final page = await _svc.searchCategory(_keyword, cat, page: 1);
      if (!mounted) return;
      setState(() {
        st.statuses = page.statuses;
        st.users = page.users;
        st.topics = page.topics;
        st.nextPage = page.nextPage;
        // 综合保持原行为不翻页；其余分类没有下一页序号即到底
        st.ended = cat == SearchCategory.all || page.nextPage <= 0;
        st.loaded = true;
        st.loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          st.error = '$e';
          st.loading = false;
        });
      }
    }
  }

  /// 翻页：失败（访客态 302 跳登录等）静默按没有更多处理，
  /// 不报错、不清已有列表；成功则按状态 id 去重追加。
  Future<void> _loadMore(SearchCategory cat) async {
    final st = _states[cat];
    if (st == null || !st.loaded || st.loading || st.loadingMore || st.ended) {
      return;
    }
    st.loadingMore = true;
    setState(() {});
    try {
      final page = await _svc.searchCategory(_keyword, cat, page: st.nextPage);
      if (!mounted) return;
      setState(() {
        final seen = st.statuses.map((s) => s.id).toSet();
        st.statuses = [
          ...st.statuses,
          for (final s in page.statuses)
            if (seen.add(s.id)) s,
        ];
        final seenUsers = st.users.map((u) => u.id).toSet();
        st.users = [
          ...st.users,
          for (final u in page.users)
            if (seenUsers.add(u.id)) u,
        ];
        st.topics = [...st.topics, ...page.topics];
        st.nextPage = page.nextPage;
        st.ended = page.nextPage <= 0 ||
            (page.statuses.isEmpty && page.users.isEmpty && page.topics.isEmpty);
        st.loadingMore = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          st.ended = true;
          st.loadingMore = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
      body: Column(
        children: [
          if (_hasSearched) _buildCategoryBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// 顶部分类栏：7 项横滑 chips。
  Widget _buildCategoryBar() {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        children: [
          for (final cat in SearchCategory.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(cat.label),
                selected: _category == cat,
                onSelected: (_) => _selectCategory(cat),
                visualDensity: VisualDensity.compact,
                labelStyle: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (!_hasSearched) {
      // 有输入且建议非空 → 建议列表；否则（空输入/无建议）→ 历史区
      final suggest = _suggest;
      if (_controller.text.trim().isNotEmpty &&
          suggest != null &&
          !suggest.isEmpty) {
        return _buildSuggestions(suggest);
      }
      return _buildHistoryOrHint();
    }
    final cats = SearchCategory.values;
    return IndexedStack(
      index: cats.indexOf(_category),
      children: [
        for (final cat in cats)
          if (_visited.contains(cat))
            _buildCategoryView(cat)
          else
            const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildCategoryView(SearchCategory cat) {
    final st = _stateFor(cat);
    if (st.loading) return const Center(child: CircularProgressIndicator());
    if (st.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(st.error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                st.loaded = false;
                _loadCategory(cat);
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!st.loaded || st.isEmpty) {
      return const Center(child: Text('没有找到相关结果'));
    }
    return switch (cat) {
      SearchCategory.users => ListView.builder(
          controller: st.scroll,
          itemCount: st.users.length + (st.loadingMore ? 1 : 0),
          itemBuilder: (context, i) => i < st.users.length
              ? UserTile(user: st.users[i])
              : const _LoadingMoreFooter(),
        ),
      SearchCategory.topic || SearchCategory.supertopic =>
        ListView.builder(
          controller: st.scroll,
          itemCount: st.topics.length + (st.loadingMore ? 1 : 0),
          itemBuilder: (context, i) => i < st.topics.length
              ? _TopicRow(entry: st.topics[i])
              : const _LoadingMoreFooter(),
        ),
      _ => _buildStatusResults(cat, st),
    };
  }

  /// 微博卡结果（综合带用户行置顶；实时/视频/图片只有微博卡）。
  /// 窄屏单列，宽屏用户行整行置顶 + 帖子卡瀑布流多列。
  Widget _buildStatusResults(SearchCategory cat, _CategoryState st) {
    final users = cat == SearchCategory.all ? st.users : const <WbUser>[];
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = feedColumnCount(constraints.maxWidth);
        if (cols <= 1) {
          return ListView(
            controller: st.scroll,
            children: [
              for (final u in users) UserTile(user: u),
              for (final s in st.statuses)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: StatusCard(status: s),
                ),
              if (st.loadingMore) const _LoadingMoreFooter(),
            ],
          );
        }
        return CustomScrollView(
          controller: st.scroll,
          slivers: [
            SliverList.builder(
              itemCount: users.length,
              itemBuilder: (context, i) => UserTile(user: users[i]),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              sliver: SliverMasonryGrid.count(
                crossAxisCount: cols,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childCount: st.statuses.length,
                itemBuilder: (context, i) => StatusCard(status: st.statuses[i]),
              ),
            ),
            if (st.loadingMore)
              const SliverToBoxAdapter(child: _LoadingMoreFooter()),
          ],
        );
      },
    );
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
            child: Text(
              '推荐用户',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
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
            const Text(
              '搜索历史',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            TextButton(onPressed: _clearHistory, child: const Text('清空')),
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

/// 话题 / 超话行：封面 + 标题 + 简介/统计文案，点击进话题页
///（与正文话题点击同一条 openTopic 路）。
class _TopicRow extends StatelessWidget {
  final WbTopicEntry entry;
  const _TopicRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = entry.title.replaceAll(RegExp(r'^#+|#+$'), '').trim();
    return ListTile(
      leading: CoverImage(
        url: entry.pic,
        size: 48,
        radius: 8,
        fallbackIcon: Icons.tag,
      ),
      title: Text(
        entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: (entry.desc1.isEmpty && entry.desc2.isEmpty)
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.desc1.isNotEmpty && entry.desc1 != name)
                  Text(
                    entry.desc1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (entry.desc2.isNotEmpty)
                  Text(
                    entry.desc2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
              ],
            ),
      onTap: () {
        // 超话条目（scheme containerid=100808…）进超话页（带关注/签到），
        // 其余仍走普通话题页。
        final pageId = entry.superPageId;
        if (pageId != null) {
          openSuperTopic(context, pageId, entry.title, cover: entry.pic);
        } else {
          openTopic(context, entry.title);
        }
      },
    );
  }
}

class _LoadingMoreFooter extends StatelessWidget {
  const _LoadingMoreFooter();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
