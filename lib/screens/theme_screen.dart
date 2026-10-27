import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_service.dart';

/// 主题页面（参考 Bettbox）：主题模式 + 纯黑模式 + 主题色 + 自定义颜色
class ThemeScreen extends StatelessWidget {
  const ThemeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('主题'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt_outlined),
            tooltip: '重置主题',
            onPressed: () => _confirmReset(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle(context, '主题模式'),
          const SizedBox(height: 12),
          _ThemeModeSelector(settings: settings),
          if (isDark) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('纯黑模式'),
              subtitle: Text('深色下背景全黑（AMOLED 更省电）',
                  style:
                      TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              value: settings.pureBlack,
              onChanged: (v) =>
                  context.read<SettingsService>().setPureBlack(v),
            ),
          ],
          const Divider(height: 32),
          _sectionTitle(context, '主题色'),
          const SizedBox(height: 12),
          _ColorGrid(settings: settings),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('动态取色'),
            subtitle: Text('跟随系统壁纸生成主题色（Android 12+）',
                style:
                    TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            value: settings.dynamicColor,
            onChanged: (v) =>
                context.read<SettingsService>().setDynamicColor(v),
          ),
          if (settings.dynamicColor && settings.systemSeedColor == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('当前系统不支持动态取色，将使用所选主题色',
                  style:
                      TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Text(text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ));
  }

  void _confirmReset(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置主题'),
        content: const Text('恢复默认主题设置？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<SettingsService>().resetTheme();
            },
            child: const Text('重置'),
          ),
        ],
      ),
    );
  }
}

/// 主题模式选择：跟随系统 / 浅色 / 深色（Bettbox 风格横向卡片）
class _ThemeModeSelector extends StatelessWidget {
  final SettingsService settings;
  const _ThemeModeSelector({required this.settings});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = [
      (ThemeMode.system, Icons.auto_mode, '跟随系统'),
      (ThemeMode.light, Icons.light_mode, '浅色'),
      (ThemeMode.dark, Icons.dark_mode, '深色'),
    ];
    return Row(
      children: items.map((item) {
        final selected = settings.themeMode == item.$1;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () =>
                  context.read<SettingsService>().setThemeMode(item.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: selected
                      ? cs.primaryContainer
                      : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                  border: selected
                      ? Border.all(color: cs.primary, width: 1.5)
                      : null,
                ),
                child: Column(
                  children: [
                    Icon(item.$2,
                        color: selected
                            ? cs.onPrimaryContainer
                            : cs.onSurfaceVariant),
                    const SizedBox(height: 6),
                    Text(item.$3,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                          color: selected
                              ? cs.onPrimaryContainer
                              : cs.onSurfaceVariant,
                        )),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// 主题色网格：预设 + 自定义（长按删除）+ 添加按钮
class _ColorGrid extends StatelessWidget {
  final SettingsService settings;
  const _ColorGrid({required this.settings});

  @override
  Widget build(BuildContext context) {
    final presets = SettingsService.themePresets;
    final customs = settings.customColors;
    // 网格项：预设 + 自定义 + 添加按钮
    final total = presets.length + customs.length + 1;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 16,
        crossAxisSpacing: 8,
        childAspectRatio: 0.85,
      ),
      itemCount: total,
      itemBuilder: (context, i) {
        if (i < presets.length) {
          final p = presets[i];
          return _ColorItem(
            color: Color(p.value),
            name: p.name,
            selected: settings.themeSeed == p.value &&
                !settings.dynamicColor,
            onTap: () =>
                context.read<SettingsService>().setThemeSeed(p.value),
          );
        }
        final ci = i - presets.length;
        if (ci < customs.length) {
          final value = customs[ci];
          return _ColorItem(
            color: Color(value),
            name: '自定义',
            selected: settings.themeSeed == value &&
                !settings.dynamicColor,
            onTap: () =>
                context.read<SettingsService>().setThemeSeed(value),
            onLongPress: () => _confirmDelete(context, value),
          );
        }
        // 添加自定义颜色
        return _AddColorItem(
          onTap: () => _showColorPicker(context),
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, int value) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除颜色'),
        content: const Text('删除这个自定义主题色？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<SettingsService>().removeCustomColor(value);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _showColorPicker(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => const _CustomColorDialog(),
    );
  }
}

class _ColorItem extends StatelessWidget {
  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _ColorItem({
    required this.color,
    required this.name,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: selected
                  ? Border.all(color: cs.primary, width: 3)
                  : Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.5)),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: selected ? 12 : 6,
                ),
              ],
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.white, size: 26)
                : null,
          ),
          const SizedBox(height: 6),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: selected ? cs.primary : cs.onSurfaceVariant,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
              )),
        ],
      ),
    );
  }
}

/// 添加自定义颜色按钮
class _AddColorItem extends StatelessWidget {
  final VoidCallback onTap;
  const _AddColorItem({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: cs.outlineVariant,
                width: 1.5,
              ),
              color: cs.surfaceContainerHigh,
            ),
            child: Icon(Icons.add, color: cs.onSurfaceVariant, size: 26),
          ),
          const SizedBox(height: 6),
          Text('添加',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// 自定义颜色选择器：色相滑杆 + 饱和度/明度二维选择
class _CustomColorDialog extends StatefulWidget {
  const _CustomColorDialog();

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  double _hue = 0; // 0-360
  double _sat = 0.8; // 0-1
  double _val = 0.8; // 0-1

  Color get _color =>
      HSVColor.fromAHSV(1.0, _hue, _sat, _val).toColor();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义主题色'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 56,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(height: 16),
            _buildHueSlider(),
            const SizedBox(height: 8),
            _buildSVPicker(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            context
                .read<SettingsService>()
                .addCustomColor(_color.toARGB32());
            context
                .read<SettingsService>()
                .setThemeSeed(_color.toARGB32());
          },
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _buildHueSlider() {
    return Row(
      children: [
        const Text('色相', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(
          child: Slider(
            value: _hue,
            min: 0,
            max: 360,
            onChanged: (v) => setState(() => _hue = v),
          ),
        ),
      ],
    );
  }

  Widget _buildSVPicker() {
    return Column(
      children: [
        Row(
          children: [
            const Text('饱和度', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(
              child: Slider(
                value: _sat,
                onChanged: (v) => setState(() => _sat = v),
              ),
            ),
          ],
        ),
        Row(
          children: [
            const Text('明度', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(
              child: Slider(
                value: _val,
                onChanged: (v) => setState(() => _val = v),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
