import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'screens/discover_screen.dart';
import 'screens/home_screen.dart';
import 'screens/me_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/theme_screen.dart';
import 'screens/video_tab_screen.dart';
import 'services/settings_service.dart';
import 'services/visitor_service.dart';
import 'services/weibo_service.dart';
import 'widgets/detail_scaffold.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final visitor = VisitorService();
  final weibo = WeiboService(visitor);
  final settings = SettingsService();
  await settings.init();
  // 启动即预热两栈访客身份（失败不阻塞进主界面，进页面时还会重试）
  visitor.ensure(WbStack.pc).catchError((_) => const VisitorIdentity('', '', 0));
  visitor.ensure(WbStack.m).catchError((_) => const VisitorIdentity('', '', 0));

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<VisitorService>.value(value: visitor),
        Provider<WeiboService>.value(value: weibo),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
      ],
      child: const WeiboApp(),
    ),
  );
}

class WeiboApp extends StatelessWidget {
  const WeiboApp({super.key});

  @override
  Widget build(BuildContext context) {
    // M3 主题：主题模式 + 动态取色/种子色 + 纯黑模式（复用模板主题系统）
    final settings = context.watch<SettingsService>();
    final seedColor = settings.effectiveSeedColor;
    return MaterialApp(
      title: '微阅',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: buildTheme(brightness: Brightness.light, seedColor: seedColor),
      darkTheme: buildTheme(
        brightness: Brightness.dark,
        seedColor: seedColor,
        pureBlack: settings.pureBlack,
      ),
      home: const AppShell(),
      onGenerateRoute: (routeSettings) {
        switch (routeSettings.name) {
          case '/search':
            return MaterialPageRoute(
              builder: (_) =>
                  const DetailScaffold(child: SearchScreen(autofocus: true)),
            );
          case '/settings':
            return MaterialPageRoute(
                builder: (_) => const DetailScaffold(child: SettingsScreen()));
          case '/theme':
            return MaterialPageRoute(
                builder: (_) => const DetailScaffold(child: ThemeScreen()));
        }
        return null;
      },
    );
  }
}

/// 主壳：底部 NavigationBar 四栏（首页/视频/发现/我的）；
/// 宽屏（>=900）左侧 NavigationRail（沿用模板布局模式）。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;

  final _tabs = const [
    HomeScreen(),
    VideoTabScreen(),
    DiscoverScreen(),
    MeScreen(),
  ];

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
                  selectedIndex: _tabIndex,
                  onDestinationSelected: (i) =>
                      setState(() => _tabIndex = i),
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
                  child: IndexedStack(index: _tabIndex, children: _tabs),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          body: IndexedStack(index: _tabIndex, children: _tabs),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (i) => setState(() => _tabIndex = i),
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
