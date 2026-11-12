import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/emoticons.dart';
import '../models/models.dart';
import '../services/weiyue_service.dart';
import '../widgets/cover_image.dart';
import '../widgets/network_image.dart';

/// 一张已选图片（选图结果）：[bytes] 已读入内存时直接用；
/// 草稿恢复的图片只有 [path]，上传时再按路径读字节。
class ComposePickedImage {
  final String path;
  final Uint8List? bytes;
  final String mimeType;

  const ComposePickedImage({
    required this.path,
    this.bytes,
    required this.mimeType,
  });
}

/// 选图器注入点：默认走系统选图（见 _defaultPickImages），
/// 测试以假实现替换（不碰平台通道）。
typedef ComposeImagePicker =
    Future<List<ComposePickedImage>> Function(int remaining);

/// 按文件名扩展推断 MIME（选图插件没给 mimeType 时的兜底；
/// 上传成功后随 pid 一起进 pic_id 的 type 字段，对齐网页端
/// 用 File.type 的口径）。
String mimeTypeOfFileName(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'heic' => 'image/heic',
    'heif' => 'image/heif',
    _ => 'image/jpeg',
  };
}

/// 在光标处插入文本（有选区时替换选区，无有效光标时追加到末尾）。
/// [selectInnerStart]/[selectInnerLength] 给出插入文本内部要反选的
/// 范围（话题占位 `#话题#` 选中中间的「话题」，方便直接打字覆盖）。
void insertTextAtCursor(
  TextEditingController controller,
  String insert, {
  int selectInnerStart = -1,
  int selectInnerLength = 0,
}) {
  final value = controller.value;
  final selection = value.selection;
  final text = value.text;
  final start = selection.isValid ? selection.start : text.length;
  final end = selection.isValid ? selection.end : text.length;
  final newText = text.replaceRange(start, end, insert);
  controller.value = TextEditingValue(
    text: newText,
    selection: selectInnerStart >= 0
        ? TextSelection(
            baseOffset: start + selectInnerStart,
            extentOffset: start + selectInnerStart + selectInnerLength,
          )
        : TextSelection.collapsed(offset: start + insert.length),
  );
}

enum _ImageUploadState { idle, uploading, ready, failed }

class _ImageItem {
  String path;
  Uint8List? bytes;
  String mimeType;
  _ImageUploadState state = _ImageUploadState.idle;
  String? pid;
  String? error;

  _ImageItem({required this.path, this.bytes, required this.mimeType});

  Future<Uint8List> loadBytes() async =>
      bytes ??= await File(path).readAsBytes();
}

/// 发帖页：纯文字 + 最多 9 张配图（逐张上传 picupload 拿 pid 后
/// 带 pic_id 发布）。文本与图片路径自动存本地草稿，重开恢复、
/// 发布成功清除；图片文件已不存在时恢复时自动忽略。
/// 发布/上传全是用户在本页手动点击触发，与既有写功能同性质。
class ComposeScreen extends StatefulWidget {
  /// 测试注入点：替换系统选图。
  final ComposeImagePicker? imagePicker;

  const ComposeScreen({super.key, this.imagePicker});

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  static const _draftTextKey = 'weiyue_compose_draft_text_v1';
  static const _draftPicsKey = 'weiyue_compose_draft_pics_v1';
  static const maxImages = 9;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final List<_ImageItem> _images = [];
  bool _publishing = false;
  bool _showEmoticons = false;
  bool _draftLoaded = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    unawaited(_loadDraft());
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    unawaited(_saveDraft());
    if (mounted) setState(() {});
  }

  Future<void> _loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(_draftTextKey) ?? '';
    final picPaths = prefs.getStringList(_draftPicsKey) ?? const [];
    if (!mounted) return;
    setState(() {
      if (text.isNotEmpty && _controller.text.isEmpty) {
        _controller.text = text;
      }
      for (final path in picPaths) {
        if (_images.length >= maxImages) break;
        // 草稿只存路径：文件已被清理/移动就忽略这张。
        if (!File(path).existsSync()) continue;
        _images.add(_ImageItem(path: path, mimeType: mimeTypeOfFileName(path)));
      }
      _draftLoaded = true;
    });
  }

  Future<void> _saveDraft() async {
    if (!_draftLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftTextKey, _controller.text);
    await prefs.setStringList(_draftPicsKey, [
      for (final img in _images) img.path,
    ]);
  }

  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftTextKey);
    await prefs.remove(_draftPicsKey);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  bool get _canPublish =>
      !_publishing &&
      (_controller.text.trim().isNotEmpty || _images.isNotEmpty);

  Future<void> _pickImages() async {
    final remaining = maxImages - _images.length;
    if (remaining <= 0) {
      _snack('最多选 $maxImages 张图片');
      return;
    }
    final picker = widget.imagePicker ?? _defaultPickImages;
    final List<ComposePickedImage> picked;
    try {
      picked = await picker(remaining);
    } catch (e) {
      _snack('选图失败：$e');
      return;
    }
    if (!mounted || picked.isEmpty) return;
    setState(() {
      for (final p in picked.take(remaining)) {
        _images.add(
          _ImageItem(path: p.path, bytes: p.bytes, mimeType: p.mimeType),
        );
      }
    });
    unawaited(_saveDraft());
  }

  /// 默认选图：image_picker（移动/macOS）；插件在当前平台没有
  /// 实现（Windows/Linux）时回落 file_selector 的系统文件框。
  Future<List<ComposePickedImage>> _defaultPickImages(int remaining) async {
    try {
      final files = await ImagePicker().pickMultiImage();
      final picked = <ComposePickedImage>[];
      for (final f in files.take(remaining)) {
        picked.add(
          ComposePickedImage(
            path: f.path,
            bytes: await f.readAsBytes(),
            mimeType: f.mimeType ?? mimeTypeOfFileName(f.name),
          ),
        );
      }
      return picked;
    } on MissingPluginException {
      return _pickImagesViaFileSelector(remaining);
    } on UnsupportedError {
      return _pickImagesViaFileSelector(remaining);
    }
  }

  Future<List<ComposePickedImage>> _pickImagesViaFileSelector(
    int remaining,
  ) async {
    const group = XTypeGroup(
      label: '图片',
      extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'],
    );
    final files = await openFiles(acceptedTypeGroups: [group]);
    final picked = <ComposePickedImage>[];
    for (final f in files.take(remaining)) {
      picked.add(
        ComposePickedImage(
          path: f.path,
          bytes: await f.readAsBytes(),
          mimeType: f.mimeType ?? mimeTypeOfFileName(f.name),
        ),
      );
    }
    return picked;
  }

  void _removeImage(int index) {
    if (_publishing) return;
    setState(() => _images.removeAt(index));
    unawaited(_saveDraft());
  }

  /// 上传单张（发布流程与失败重试共用）：成功置 ready 并记 pid，
  /// 失败置 failed 并把服务端消息留在条目上，异常向上抛由调用方提示。
  Future<void> _uploadOne(_ImageItem img) async {
    final svc = context.read<WeiyueService>();
    setState(() => img.state = _ImageUploadState.uploading);
    try {
      final bytes = await img.loadBytes();
      final pid = await svc.uploadPicture(bytes);
      if (!mounted) return;
      setState(() {
        img.state = _ImageUploadState.ready;
        img.pid = pid;
        img.error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          img.state = _ImageUploadState.failed;
          img.error = '$e';
        });
      }
      rethrow;
    }
  }

  Future<void> _retryImage(_ImageItem img) async {
    if (_publishing || img.state == _ImageUploadState.uploading) return;
    try {
      await _uploadOne(img);
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _publish() async {
    if (!_canPublish) return;
    if (_images.any((i) => i.state == _ImageUploadState.uploading)) {
      _snack('图片正在上传中，请稍后');
      return;
    }
    final svc = context.read<WeiyueService>();
    setState(() => _publishing = true);
    try {
      // 逐张上传（已 ready 的跳过），全部成功才带图发布；
      // 任一张失败就停在这里：内容保留，用户可重试或移除后发布。
      for (final img in _images) {
        if (img.state == _ImageUploadState.ready) continue;
        await _uploadOne(img);
      }
      await svc.publishStatus(
        _controller.text.trim(),
        pics: [for (final img in _images) (pid: img.pid!, type: img.mimeType)],
      );
      await _clearDraft();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  void _insertTopic() {
    insertTextAtCursor(
      _controller,
      '#话题#',
      selectInnerStart: 1,
      selectInnerLength: 2,
    );
    _focusNode.requestFocus();
  }

  Future<void> _insertMention() async {
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _MentionPickerSheet(),
    );
    if (name == null || name.isEmpty || !mounted) return;
    insertTextAtCursor(_controller, '@$name ');
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final charCount = _controller.text.runes.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('发动态'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: const ValueKey('compose-publish-button'),
              onPressed: _canPublish ? _publish : null,
              child: _publishing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('发布'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    key: const ValueKey('compose-text-field'),
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    maxLines: null,
                    minLines: 5,
                    decoration: const InputDecoration(
                      hintText: '分享新鲜事…',
                      border: InputBorder.none,
                    ),
                  ),
                  if (_images.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < _images.length; i++)
                            _buildThumb(i),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('compose-pick-image-button'),
                  icon: const Icon(Icons.image_outlined),
                  tooltip: '图片（${_images.length}/$maxImages）',
                  onPressed: _publishing ? null : _pickImages,
                ),
                IconButton(
                  key: const ValueKey('compose-emoticon-button'),
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  tooltip: '表情',
                  onPressed: () =>
                      setState(() => _showEmoticons = !_showEmoticons),
                ),
                IconButton(
                  key: const ValueKey('compose-topic-button'),
                  icon: const Icon(Icons.tag),
                  tooltip: '话题',
                  onPressed: _insertTopic,
                ),
                IconButton(
                  key: const ValueKey('compose-mention-button'),
                  icon: const Icon(Icons.alternate_email),
                  tooltip: '提到朋友',
                  onPressed: _insertMention,
                ),
                const Spacer(),
                Text(
                  '$charCount',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
              ],
            ),
          ),
          if (_showEmoticons) _buildEmoticonPanel(),
        ],
      ),
    );
  }

  Widget _buildThumb(int index) {
    final img = _images[index];
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: img.bytes != null
                ? Image.memory(img.bytes!, fit: BoxFit.cover)
                : Image.file(
                    File(img.path),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: cs.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
          ),
          if (img.state == _ImageUploadState.uploading)
            Container(
              color: Colors.black45,
              child: const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          if (img.state == _ImageUploadState.failed)
            Container(
              color: Colors.black45,
              child: Center(
                child: IconButton(
                  key: ValueKey('compose-image-retry-$index'),
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  tooltip: '上传失败，点击重试',
                  onPressed: () => _retryImage(img),
                ),
              ),
            ),
          Positioned(
            top: 2,
            right: 2,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: InkWell(
                key: ValueKey('compose-image-remove-$index'),
                customBorder: const CircleBorder(),
                onTap: () => _removeImage(index),
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmoticonPanel() {
    return ValueListenableBuilder<int>(
      valueListenable: Emoticons.version,
      builder: (context, _, _) {
        final phrases = Emoticons.phrases;
        return Container(
          height: 220,
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          child: phrases.isEmpty
              ? const Center(child: Text('表情数据加载中…'))
              : GridView.builder(
                  key: const ValueKey('compose-emoticon-panel'),
                  padding: const EdgeInsets.all(10),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 52,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: phrases.length,
                  itemBuilder: (context, i) {
                    final phrase = phrases[i];
                    final url = Emoticons.urlOf(phrase) ?? '';
                    return InkWell(
                      key: ValueKey('compose-emoticon-$phrase'),
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        insertTextAtCursor(_controller, phrase);
                        _focusNode.requestFocus();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(7),
                        child: NetImage(
                          url: url,
                          errorBuilder: (_) => Center(
                            child: Text(
                              phrase,
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

/// @ 选人弹层：输入关键词走用户分类搜索（searchCategory users，
/// 与搜索页用户分类同一接口），点中返回昵称供发帖页插入 `@昵称 `。
class _MentionPickerSheet extends StatefulWidget {
  const _MentionPickerSheet();

  @override
  State<_MentionPickerSheet> createState() => _MentionPickerSheetState();
}

class _MentionPickerSheetState extends State<_MentionPickerSheet> {
  final _keywordController = TextEditingController();
  List<WbUser> _users = const [];
  bool _loading = false;
  String? _error;
  bool _searched = false;

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _keywordController.text.trim();
    if (q.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context.read<WeiyueService>().searchCategory(
        q,
        SearchCategory.users,
      );
      if (!mounted) return;
      setState(() {
        _users = page.users;
        _searched = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('mention-keyword-field'),
                      controller: _keywordController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '搜索用户昵称',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('mention-search-button'),
                    onPressed: _loading ? null : _search,
                    child: const Text('搜索'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text(_error!))
                  : !_searched
                  ? const Center(child: Text('输入昵称搜索，点选后插入到正文'))
                  : _users.isEmpty
                  ? const Center(child: Text('没有找到用户'))
                  : ListView.builder(
                      itemCount: _users.length,
                      itemBuilder: (context, i) {
                        final u = _users[i];
                        return ListTile(
                          key: ValueKey('mention-user-${u.id}'),
                          leading: CoverImage(
                            url: u.avatar,
                            size: 40,
                            radius: 20,
                            fallbackIcon: Icons.person_outline,
                          ),
                          title: Text(u.screenName),
                          subtitle: Text(
                            u.description.isNotEmpty
                                ? u.description
                                : '粉丝 ${u.followersCount}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.of(context).pop(u.screenName),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
