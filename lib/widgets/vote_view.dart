import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/weiyue_service.dart';
import 'interactions.dart';

/// 帖子投票区（主包 FeedVote 组件行为对齐，2026-11-12 实证）：
/// - 未投且未结束：单选点选项直接投；多选先勾选（[minimum, maximum]
///   区间内）再点「投票」提交（setVote，vote_items 逗号拼接）；
/// - 已投或已结束：展示各选项票数与占比条，本人选过的带勾；
///   已投未结束时点任一选项弹确认撤回（cancelVote）；
/// - 投/撤都以服务端回的 vote_object 整替本地状态；回执自带
///   error_msg 时按主包语义只弹警告、状态照常更新。
/// 写操作前走 ensureLoggedIn 守卫（未登录不发请求）。
class VoteView extends StatefulWidget {
  final WbVote vote;

  /// 测试注入；默认取 Provider 里的 WeiyueService。
  final WeiyueService? service;

  const VoteView({super.key, required this.vote, this.service});

  @override
  State<VoteView> createState() => _VoteViewState();
}

class _VoteViewState extends State<VoteView> {
  late WbVote _vote;
  final Set<int> _checked = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _vote = widget.vote;
  }

  @override
  void didUpdateWidget(VoteView old) {
    super.didUpdateWidget(old);
    // 换了一条帖子（列表复用）才重置；同一投票的新对象由回执路径更新。
    if (old.vote.id != widget.vote.id) {
      _vote = widget.vote;
      _checked.clear();
    }
  }

  WeiyueService get _svc => widget.service ?? context.read<WeiyueService>();

  bool get _showResults => _vote.voted || _vote.ended;

  bool get _canSubmit =>
      _checked.length >= _vote.minimum && _checked.length <= _vote.maximum;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _cast(List<int> itemIds) async {
    if (_busy || itemIds.isEmpty) return;
    if (!ensureLoggedIn(context)) return;
    setState(() => _busy = true);
    try {
      final r = await _svc.setVote(_vote.id, itemIds);
      if (!mounted) return;
      setState(() {
        if (r.vote != null) {
          _vote = r.vote!;
          _checked.clear();
        }
      });
      if (r.errorMsg != null) {
        _toast(r.errorMsg!);
      } else if (r.vote != null) {
        _toast('投票成功');
      }
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _askCancel() async {
    if (_busy || _vote.ended) return;
    if (!ensureLoggedIn(context)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text('是否撤回投票？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('撤回'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await _svc.cancelVote(_vote.id);
      if (!mounted) return;
      setState(() {
        if (r.vote != null) {
          _vote = r.vote!;
          _checked.clear();
        }
      });
      if (r.errorMsg != null) {
        _toast(r.errorMsg!);
      } else if (r.vote != null) {
        _toast('已撤回投票');
      }
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onTapItem(WbVoteItem item) {
    if (_busy) return;
    if (_showResults) {
      // 已投（未结束）点选项 = 撤回入口，与网页端 onClickOption 一致。
      if (_vote.voted && !_vote.ended) _askCancel();
      return;
    }
    if (_vote.multiSelect) {
      setState(() {
        if (!_checked.remove(item.id)) _checked.add(item.id);
      });
    } else {
      _cast([item.id]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = _vote.items.fold<int>(0, (a, e) => a + e.partNum);
    final participants = _vote.partInfo > 0 ? _vote.partInfo : total;
    return Container(
      key: const ValueKey('vote-view'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.poll_outlined, size: 17, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                _vote.multiSelect ? '投票 · 多选' : '投票',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                _headerMeta(participants),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final item in _vote.items) ...[
            _optionRow(context, item),
            const SizedBox(height: 6),
          ],
          if (!_showResults && _vote.multiSelect)
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _busy || !_canSubmit
                    ? null
                    : () => _cast(_checked.toList()),
                child: Text(_busy ? '提交中…' : '投票'),
              ),
            ),
          if (_vote.voted && !_vote.ended)
            Text(
              '已投票 · 点选项可撤回',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  String _headerMeta(int participants) {
    final parts = <String>[
      if (participants > 0) '$participants 人参与',
      if (_vote.ended)
        '已结束'
      else if (_vote.expireAt != null)
        '截止 ${_vote.expireAt!.month}月${_vote.expireAt!.day}日',
    ];
    return parts.join(' · ');
  }

  Widget _optionRow(BuildContext context, WbVoteItem item) {
    final cs = Theme.of(context).colorScheme;
    if (_showResults) {
      return InkWell(
        onTap: _busy ? null : () => _onTapItem(item),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: cs.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _ratioOf(item).clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.content,
                      style: TextStyle(fontSize: 14, color: cs.onSurface),
                    ),
                  ),
                  if (item.selected)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.check_circle,
                        size: 16,
                        color: cs.primary,
                      ),
                    ),
                  Text(
                    '${item.partNum} 票 · ${(_ratioOf(item) * 100).toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final checked = _vote.multiSelect && _checked.contains(item.id);
    return InkWell(
      onTap: _busy ? null : () => _onTapItem(item),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          border: Border.all(color: checked ? cs.primary : cs.outlineVariant),
          borderRadius: BorderRadius.circular(8),
          color: checked ? cs.primary.withValues(alpha: 0.08) : null,
        ),
        child: Row(
          children: [
            if (_vote.multiSelect) ...[
              Icon(
                checked
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                size: 19,
                color: checked ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                item.content,
                style: TextStyle(fontSize: 14, color: cs.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _ratioOf(WbVoteItem item) {
    final total = _vote.items.fold<int>(0, (a, e) => a + e.partNum);
    if (total > 0) return item.partNum / total;
    // 与网页端一致：总票数为 0 时各选项均分（仅影响条宽展示）。
    if (_vote.items.isNotEmpty) return 1 / _vote.items.length;
    return item.partRatio;
  }
}
