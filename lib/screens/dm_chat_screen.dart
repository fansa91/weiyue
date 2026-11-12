import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/session_service.dart';
import '../services/weiyue_service.dart';
import '../widgets/cover_image.dart';

/// 私信聊天页（WebIM 子系统）：打开拉最新一页、列表顶部按钮
/// 加载更早、手动刷新合并新消息；文本发送走
/// /webim/2/direct_messages/new.json（bundle 实证，见
/// WEIBO_API.md「私信」小节），乐观上屏，失败标红可点重发。
/// 子系统是 comet 长轮询推送模型，本页**不接长连接**——新消息
/// 靠打开与手动刷新获取（任务定版）。
/// 未关注人会话（isPublic）全程走 public 族接口。
class DmChatScreen extends StatefulWidget {
  final DmConversation conversation;

  const DmChatScreen({super.key, required this.conversation});

  @override
  State<DmChatScreen> createState() => _DmChatScreenState();
}

class _DmChatScreenState extends State<DmChatScreen> {
  late final WeiyueService _svc;
  final _scroll = ScrollController();
  final _input = TextEditingController();

  /// 时间升序（旧→新）；本地待发/失败条恒在尾部（负数临时 id）。
  List<DmMessage> _messages = [];
  bool _loading = true;
  bool _refreshing = false;
  bool _loadingOlder = false;
  bool _hasMore = false;
  String? _error;
  int _tempSeq = 0;

  DmConversation get _conv => widget.conversation;
  String get _peerUid => _conv.uid;
  int get _myUid => int.tryParse(context.read<SessionService>().uid) ?? 0;

  @override
  void initState() {
    super.initState();
    _svc = context.read<WeiyueService>();
    // 加载更早只走列表顶部的显式按钮：滚动监听在首屏跳底/
    // 前插回位时机会误触，行为不确定，故不做滚动自动触发。
    _loadLatest(initial: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _markRead() async {
    try {
      await _svc.markDmRead(_peerUid, isPublic: _conv.isPublic);
    } catch (_) {
      // 标记已读失败不打扰阅读（下次打开/刷新会再试）
    }
  }

  Future<void> _loadLatest({bool initial = false}) async {
    if (!initial && _refreshing) return;
    setState(() {
      if (initial) {
        _loading = true;
        _error = null;
      } else {
        _refreshing = true;
      }
    });
    try {
      final page = await _svc.getDmHistory(
        _peerUid,
        isPublic: _conv.isPublic,
      );
      if (!mounted) return;
      setState(() {
        if (initial || _messages.isEmpty) {
          _messages = page.messages;
          _hasMore = page.hasMore;
        } else {
          // 手动刷新：与已加载消息按 id 合并（保留已翻出的更早页
          // 与尾部本地待发条），服务端版本覆盖同 id 条目。
          final locals = _messages
              .where((m) => m.sendState != DmSendState.normal)
              .toList();
          final byId = <int, DmMessage>{
            for (final m in _messages)
              if (m.sendState == DmSendState.normal) m.id: m,
            for (final m in page.messages) m.id: m,
          };
          final merged = byId.values.toList()
            ..sort((a, b) => a.id.compareTo(b.id));
          _messages = [...merged, ...locals];
        }
        _loading = false;
        _refreshing = false;
        _error = null;
      });
      _scrollToBottom();
      unawaited(_markRead());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        if (initial) _error = _errText(e);
      });
      if (!initial) _snack(_errText(e));
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMore || _loading) return;
    final oldest = _messages.where((m) => m.id > 0).firstOrNull;
    if (oldest == null) return;
    _loadingOlder = true;
    final oldOffset = _scroll.hasClients ? _scroll.position.pixels : 0;
    final oldExtent = _scroll.hasClients
        ? _scroll.position.maxScrollExtent
        : 0.0;
    try {
      final page = await _svc.getDmHistory(
        _peerUid,
        maxId: oldest.id,
        isPublic: _conv.isPublic,
      );
      if (!mounted) return;
      final known = _messages.map((m) => m.id).toSet();
      final fresh = page.messages.where((m) => !known.contains(m.id)).toList();
      setState(() {
        _messages = [...fresh, ..._messages];
        _hasMore = page.hasMore && fresh.isNotEmpty;
      });
      // 前插后把滚动位置按新增高度下移，视觉上停在原处
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          final delta = _scroll.position.maxScrollExtent - oldExtent;
          _scroll.jumpTo(oldOffset + delta);
        }
      });
    } catch (_) {
      // 加载更早失败静默（滚动/按钮可再试），不打断阅读
    } finally {
      _loadingOlder = false;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  String _errText(Object e) => e is WeiyueException ? e.message : '$e';

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final local = DmMessage(
      id: --_tempSeq,
      senderId: _myUid,
      text: text,
      createdAt: DateTime.now(),
      sendState: DmSendState.sending,
    );
    setState(() => _messages = [..._messages, local]);
    _scrollToBottom();
    await _deliver(local);
  }

  /// 点失败气泡重发：同一条本地消息原地转发送中再投递。
  Future<void> _resend(DmMessage msg) async {
    if (msg.sendState != DmSendState.failed) return;
    final idx = _messages.indexWhere((m) => m.id == msg.id);
    if (idx < 0) return;
    final sending = msg.copyWith(sendState: DmSendState.sending);
    _replaceAt(idx, sending);
    await _deliver(sending);
  }

  Future<void> _deliver(DmMessage local) async {
    try {
      final sent = await _svc.sendDm(_peerUid, local.text);
      if (!mounted) return;
      final idx = _messages.indexWhere((m) => m.id == local.id);
      if (idx >= 0) _replaceAt(idx, sent);
    } catch (e) {
      if (!mounted) return;
      final idx = _messages.indexWhere((m) => m.id == local.id);
      if (idx >= 0) {
        _replaceAt(
          idx,
          _messages[idx].copyWith(sendState: DmSendState.failed),
        );
      }
      _snack('发送失败：${_errText(e)}');
    }
  }

  void _replaceAt(int idx, DmMessage msg) {
    setState(() {
      final next = [..._messages];
      next[idx] = msg;
      _messages = next;
    });
  }

  static String _timeLabel(DateTime t) {
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay
        ? DateFormat('HH:mm').format(t)
        : DateFormat('M月d日 HH:mm').format(t);
  }

  bool _showTimeAt(int i) {
    final t = _messages[i].createdAt;
    if (t == null) return false;
    if (i == 0) return true;
    final prev = _messages[i - 1].createdAt;
    if (prev == null) return true;
    return t.difference(prev).inMinutes >= 5;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CoverImage(
              url: _conv.user.avatar,
              size: 32,
              radius: 16,
              fallbackIcon: Icons.person_outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _conv.user.screenName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _refreshing ? null : () => _loadLatest(),
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody(cs)),
          _buildComposer(cs),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _loadLatest(initial: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_messages.isEmpty) {
      return const Center(child: Text('暂无消息'));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (_hasMore && i == 0) {
          return Center(
            child: TextButton(
              onPressed: _loadingOlder ? null : _loadOlder,
              child: Text(_loadingOlder ? '加载中…' : '加载更早的消息'),
            ),
          );
        }
        final idx = _hasMore ? i - 1 : i;
        final msg = _messages[idx];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_showTimeAt(idx))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  _timeLabel(msg.createdAt!),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            _bubble(msg),
          ],
        );
      },
    );
  }

  Widget _bubble(DmMessage msg) {
    final cs = Theme.of(context).colorScheme;
    if (msg.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          msg.displayText,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      );
    }
    final mine = msg.isMineFrom(_myUid);
    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: mine ? cs.primary : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 4),
          bottomRight: Radius.circular(mine ? 4 : 16),
        ),
      ),
      child: Text(
        msg.displayText,
        style: TextStyle(color: mine ? cs.onPrimary : cs.onSurface),
      ),
    );
    if (mine) {
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          bubble,
          if (msg.sendState == DmSendState.sending)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 4),
              child: Text(
                '发送中…',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),
          if (msg.sendState == DmSendState.failed)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 4),
              child: Text(
                '发送失败，点击重发',
                style: TextStyle(fontSize: 11, color: cs.error),
              ),
            ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        // 失败态整行可点重发（气泡 + 提示文字都算点击区）
        child: msg.sendState == DmSendState.failed
            ? GestureDetector(
                onTap: () => _resend(msg),
                behavior: HitTestBehavior.opaque,
                child: content,
              )
            : content,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverImage(
            url: _conv.user.avatar,
            size: 32,
            radius: 16,
            fallbackIcon: Icons.person_outline,
          ),
          const SizedBox(width: 8),
          Flexible(child: bubble),
        ],
      ),
    );
  }

  Widget _buildComposer(ColorScheme cs) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: '发送私信…',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              tooltip: '发送',
              onPressed: _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
