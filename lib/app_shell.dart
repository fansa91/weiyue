import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'core/platform_shell.dart';
import 'core/scroll_signal.dart';
import 'screens/discover_screen.dart';
import 'screens/home_screen.dart';
import 'screens/me_screen.dart';
import 'screens/video_tab_screen.dart';

/// 四个一级页（顺序即 tab 顺序，三壳共用）：
/// 首页 / 视频 / 发现 / 我的。
const _tabLabels = ['首页', '视频', '发现', '我的'];

const _tabPages = [
  HomeScreen(),
  VideoTabScreen(),
  DiscoverScreen(),
  MeScreen(),
];

/// 主壳分发器：按平台选壳（见 [shellKindForPlatform]）。
/// [platformOverride] 仅供测试注入，生产传 null 走真实平台。
class AppShell extends StatelessWidget {
  const AppShell({super.key, this.platformOverride});

  final TargetPlatform? platformOverride;

  @override
  Widget build(BuildContext context) {
    final kind = shellKindForPlatform(
      platformOverride ?? defaultTargetPlatform,
    );
    return switch (kind) {
      AppShellKind.fluent => const FluentAppShell(),
      AppShellKind.cupertino => const CupertinoAppShell(),
      AppShellKind.material => const MaterialAppShell(),
    };
  }
}

/// tab 切换的共用选择逻辑（三壳一致）：
/// 已在首页时再次选中首页不切页，改为发回顶信号让信息流滚回顶部；
/// 重复选中当前 tab 为无操作。
mixin _TabSelection<T extends StatefulWidget> on State<T> {
  int tabIndex = 0;

  void selectTab(int i) {
    if (i == 0 && tabIndex == 0) {
      signalHomeTop();
      return;
    }
    if (i == tabIndex) return;
    setState(() => tabIndex = i);
  }
}

// ---------------------------------------------------------------------------
// Material 壳（Android/Linux）：底部 NavigationBar，宽屏（>=900）左侧
// NavigationRail。换壳前的原 AppShell 实现，行为不变。
// ---------------------------------------------------------------------------

class MaterialAppShell extends StatefulWidget {
  const MaterialAppShell({super.key});

  @override
  State<MaterialAppShell> createState() => _MaterialAppShellState();
}

class _MaterialAppShellState extends State<MaterialAppShell>
    with _TabSelection {
  static const _destinations = [
    (Icons.home_outlined, Icons.home, '首页'),
    (Icons.play_circle_outline, Icons.play_circle_fill, '视频'),
    (Icons.explore_outlined, Icons.explore, '发现'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: tabIndex,
                  onDestinationSelected: selectTab,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final (icon, selectedIcon, label) in _destinations)
                      NavigationRailDestination(
                        icon: Icon(icon),
                        selectedIcon: Icon(selectedIcon),
                        label: Text(label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: IndexedStack(index: tabIndex, children: _tabPages),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          body: IndexedStack(index: tabIndex, children: _tabPages),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tabIndex,
            onDestinationSelected: selectTab,
            destinations: [
              for (final (icon, selectedIcon, label) in _destinations)
                NavigationDestination(
                  icon: Icon(icon),
                  selectedIcon: Icon(selectedIcon),
                  label: label,
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Cupertino 壳（iOS/macOS）：窄屏底部 CupertinoTabBar；
// 宽屏（>=900，macOS 窗口形态）左侧 Cupertino 风格侧栏。
// 内容区用 IndexedStack 保状态，与 Material 壳语义一致；
// 二级页仍走根 Navigator（盖住 tab 栏），与原行为一致。
// ---------------------------------------------------------------------------

class CupertinoAppShell extends StatefulWidget {
  const CupertinoAppShell({super.key});

  @override
  State<CupertinoAppShell> createState() => _CupertinoAppShellState();
}

class _CupertinoAppShellState extends State<CupertinoAppShell>
    with _TabSelection {
  static const _icons = [
    (CupertinoIcons.home, CupertinoIcons.house_fill),
    (CupertinoIcons.play_circle, CupertinoIcons.play_circle_fill),
    (CupertinoIcons.compass, CupertinoIcons.compass_fill),
    (CupertinoIcons.person, CupertinoIcons.person_fill),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    return CupertinoPageScaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final content = IndexedStack(index: tabIndex, children: _tabPages);
          if (constraints.maxWidth >= 900) {
            return Row(
              children: [
                _CupertinoSidebar(
                  selected: tabIndex,
                  onSelect: selectTab,
                  icons: _icons,
                ),
                Container(
                  width: 0.5,
                  color: CupertinoColors.separator.resolveFrom(context),
                ),
                Expanded(child: content),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: content),
              CupertinoTabBar(
                currentIndex: tabIndex,
                onTap: selectTab,
                items: [
                  for (var i = 0; i < _tabLabels.length; i++)
                    BottomNavigationBarItem(
                      icon: Icon(_icons[i].$1),
                      activeIcon: Icon(_icons[i].$2),
                      label: _tabLabels[i],
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// macOS 宽屏侧栏：品牌名 + 四个导航项，选中项红字加粗 + 浅红底。
class _CupertinoSidebar extends StatelessWidget {
  const _CupertinoSidebar({
    required this.selected,
    required this.onSelect,
    required this.icons,
  });

  final int selected;
  final ValueChanged<int> onSelect;
  final List<(IconData, IconData)> icons;

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    final labelColor = CupertinoColors.label.resolveFrom(context);
    final secondaryColor = CupertinoColors.secondaryLabel.resolveFrom(context);
    return Container(
      width: 220,
      color: theme.barBackgroundColor,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 18),
                child: Text(
                  '微阅',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: labelColor,
                  ),
                ),
              ),
              for (var i = 0; i < _tabLabels.length; i++)
                _item(context, i, theme, labelColor, secondaryColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(
    BuildContext context,
    int i,
    CupertinoThemeData theme,
    Color labelColor,
    Color secondaryColor,
  ) {
    final isSelected = i == selected;
    final fg = isSelected ? theme.primaryColor : secondaryColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: isSelected
              ? BoxDecoration(
                  color: theme.primaryColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Row(
            children: [
              Icon(isSelected ? icons[i].$2 : icons[i].$1, size: 19, color: fg),
              const SizedBox(width: 10),
              Text(
                _tabLabels[i],
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? theme.primaryColor : labelColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fluent 壳（Windows）：NavigationView 左侧导航窗格，
// displayMode=auto 由 NavigationView 按宽度自适应展开/紧凑/最小。
// 注意：NavigationView 默认只挂载选中页 body（状态不保留），
// 这里用 paneBodyBuilder 换成自有 IndexedStack，与另外两壳语义对齐。
// ---------------------------------------------------------------------------

class FluentAppShell extends StatefulWidget {
  const FluentAppShell({super.key});

  @override
  State<FluentAppShell> createState() => _FluentAppShellState();
}

class _FluentAppShellState extends State<FluentAppShell> with _TabSelection {
  static const _icons = [
    fluent.FluentIcons.home,
    fluent.FluentIcons.video,
    fluent.FluentIcons.globe,
    fluent.FluentIcons.contact,
  ];

  @override
  Widget build(BuildContext context) {
    return fluent.NavigationView(
      pane: fluent.NavigationPane(
        selected: tabIndex,
        onChanged: selectTab,
        displayMode: fluent.PaneDisplayMode.auto,
        items: [
          for (var i = 0; i < _tabLabels.length; i++)
            fluent.PaneItem(
              icon: Icon(_icons[i]),
              title: Text(_tabLabels[i]),
              body: _tabPages[i],
              // 再次点已选中的首页：NavigationPane 不再触发 onChanged，
              // 由 PaneItem.onTap 补发回顶信号（与另两壳的重选行为对齐）。
              onTap: (i == 0 && tabIndex == 0) ? signalHomeTop : null,
            ),
        ],
      ),
      paneBodyBuilder: (item, body) =>
          IndexedStack(index: tabIndex, children: _tabPages),
    );
  }
}
