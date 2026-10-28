import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/quality.dart';
import '../services/settings_service.dart';
import 'theme_screen.dart';
import '../widgets/detail_scaffold.dart';

/// 设置：外观入口 + 播放设置（关于/访客模式说明已移至「我的」页）。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('外观'),
            subtitle: const Text('主题模式 · 主题色 · 纯黑模式'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const DetailScaffold(child: ThemeScreen()),
            )),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.play_circle_outline),
            title: const Text('视频自动播放'),
            subtitle: const Text('打开视频详情时是否自动播放预览'),
            value: settings.videoAutoplay,
            onChanged: (v) => settings.setVideoAutoplay(v),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.high_quality_outlined),
            title: const Text('默认视频清晰度'),
            subtitle: Text(settings.videoQuality.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickVideoQuality(context, settings),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('默认图片清晰度'),
            subtitle: Text(
              '${settings.imageQuality.label} · 列表与查看器用图档位',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickImageQuality(context, settings),
          ),
          const Divider(height: 1),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _pickVideoQuality(
    BuildContext context,
    SettingsService settings,
  ) async {
    final picked = await showDialog<VideoQualityPref>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('默认视频清晰度'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final q in VideoQualityPref.values)
              RadioListTile<VideoQualityPref>(
                title: Text(q.label),
                value: q,
                groupValue: settings.videoQuality,
                onChanged: (_) => Navigator.of(ctx).pop(q),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await settings.setVideoQuality(picked);
  }

  Future<void> _pickImageQuality(
    BuildContext context,
    SettingsService settings,
  ) async {
    final picked = await showDialog<ImageQualityPref>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('默认图片清晰度'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final q in ImageQualityPref.values)
              RadioListTile<ImageQualityPref>(
                title: Text(q.label),
                value: q,
                groupValue: settings.imageQuality,
                onChanged: (_) => Navigator.of(ctx).pop(q),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await settings.setImageQuality(picked);
  }
}
