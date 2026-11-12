import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/session_service.dart';
import '../services/weiyue_service.dart';

/// 编辑资料页（主包编辑资料页行为对齐，2026-11-12 实证）：
/// 预填走 GET /ajax/setting/getBasicInfo；保存与网页端同构——
/// 文本字段（昵称/简介）各自点保存，选项字段（性别/情感/地区）
/// 选中即存，全部逐字段单提交 updateProfileBasic /
/// updateProfileExtend。头像更换在主包内无提交调用点实证，本页不做。
class EditProfileScreen extends StatefulWidget {
  /// 测试注入；默认取 Provider 里的 WeiyueService。
  final WeiyueService? service;

  const EditProfileScreen({super.key, this.service});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  ProfileBasicInfo? _info;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  String _gender = '';
  String _birthday = '';
  String _single = '';
  String _province = '';
  String _city = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  WeiyueService get _svc => widget.service ?? context.read<WeiyueService>();

  Future<void> _load() async {
    try {
      final info = await _svc.getProfileBasicInfo();
      if (!mounted) return;
      setState(() {
        _info = info;
        _nameCtrl.text = info.screenName;
        _descCtrl.text = info.description;
        _gender = info.gender;
        _birthday = info.birthday;
        _single = info.single;
        _province = info.province;
        _city = info.city;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 逐字段保存的统一外壳：忙态、成功提示（含服务端 msg）、失败原样弹。
  Future<void> _save(
    Future<String> Function() action, {
    String okText = '保存成功',
    VoidCallback? onOk,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final msg = await action();
      if (!mounted) return;
      onOk?.call();
      _toast(msg.isNotEmpty ? msg : okText);
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveName() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast('昵称不能为空');
      return;
    }
    await _save(
      () => _svc.updateProfileBasic({'screen_name': name}),
      okText: '修改成功',
      onOk: () {
        // 账号区昵称即时同步（探活字段只更非空项）。
        context.read<SessionService>().saveProbe(screenName: name);
      },
    );
  }

  Future<void> _saveDesc() async {
    final desc = _descCtrl.text;
    await _save(
      () => _svc.updateProfileBasic({
        'description': desc,
        'desc_empty': desc.isEmpty,
      }),
    );
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(_birthday) ?? DateTime(now.year - 25);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    final text =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    await _save(
      () => _svc.updateProfileBasic({'birthday': text}),
      onOk: () => setState(() => _birthday = text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('编辑资料')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null || _info == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：${_error ?? ''}'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                _load();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final info = _info!;
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _label('昵称'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _nameCtrl,
                maxLength: 30,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '昵称',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _saving ? null : _saveName,
              child: const Text('保存'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _label('简介'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _descCtrl,
                maxLines: 3,
                maxLength: 70,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '一句话介绍自己',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _saving ? null : _saveDesc,
              child: const Text('保存'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _label('性别'),
        Row(
          children: [
            ChoiceChip(
              label: const Text('男'),
              selected: _gender == 'm',
              onSelected: _saving
                  ? null
                  : (_) => _save(
                        () => _svc.updateProfileBasic({'gender': 'm'}),
                        onOk: () => setState(() => _gender = 'm'),
                      ),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('女'),
              selected: _gender == 'f',
              onSelected: _saving
                  ? null
                  : (_) => _save(
                        () => _svc.updateProfileBasic({'gender': 'f'}),
                        onOk: () => setState(() => _gender = 'f'),
                      ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _label('生日'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_birthday.isEmpty ? '未设置' : _birthday),
          trailing: const Icon(Icons.chevron_right),
          onTap: _saving ? null : _pickBirthday,
        ),
        const Divider(height: 1),
        const SizedBox(height: 8),
        _label('情感状态'),
        DropdownButton<String>(
          value: ProfileBasicInfo.emotionOptions.any((o) => o.value == _single)
              ? _single
              : null,
          hint: const Text('选择情感状态'),
          isExpanded: true,
          items: [
            for (final o in ProfileBasicInfo.emotionOptions)
              DropdownMenuItem(value: o.value, child: Text(o.label)),
          ],
          onChanged: _saving
              ? null
              : (v) {
                  if (v == null) return;
                  _save(
                    () async {
                      await _svc.updateProfileSingle(v);
                      return '';
                    },
                    onOk: () => setState(() => _single = v),
                  );
                },
        ),
        if (info.provinceNames.isNotEmpty) ...[
          const SizedBox(height: 8),
          _label('地区'),
          Row(
            children: [
              Expanded(child: _provinceDropdown(info)),
              const SizedBox(width: 12),
              Expanded(child: _cityDropdown(info)),
            ],
          ),
        ],
        const SizedBox(height: 24),
        Text(
          '头像更换暂不支持，请在网页端完成。',
          style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _provinceDropdown(ProfileBasicInfo info) {
    final entries = info.provinceNames.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return DropdownButton<String>(
      value: info.provinceNames.containsKey(_province) ? _province : null,
      hint: const Text('省份'),
      isExpanded: true,
      items: [
        for (final e in entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: _saving
          ? null
          : (v) {
              if (v == null) return;
              _save(
                () => _svc.updateProfileBasic({'province': v}),
                onOk: () => setState(() {
                  _province = v;
                  _city = '';
                }),
              );
            },
    );
  }

  Widget _cityDropdown(ProfileBasicInfo info) {
    final options =
        info.cityNames[info.provinceNames[_province] ?? ''] ??
            const <String, String>{};
    final entries = options.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return DropdownButton<String>(
      value: options.containsKey(_city) ? _city : null,
      hint: const Text('城市'),
      isExpanded: true,
      items: [
        for (final e in entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: _saving || entries.isEmpty
          ? null
          : (v) {
              if (v == null) return;
              _save(
                () => _svc.updateProfileBasic({
                  'province': _province,
                  'city': v,
                }),
                onOk: () => setState(() => _city = v),
              );
            },
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}
