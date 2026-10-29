import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'app_shell.dart';
import 'core/ime.dart';
import 'core/nav.dart';
import 'core/platform_shell.dart';
import 'core/theme.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/theme_screen.dart';
import 'services/session_service.dart';
import 'services/settings_service.dart';
import 'services/visitor_service.dart';
import 'services/weiyue_service.dart';
import 'widgets/detail_scaffold.dart';

export 'app_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final visitor = VisitorService();
  final session = SessionService();
  await session.init();
  final weibo = WeiyueService(visitor, session: session);
  final settings = SettingsService();
  await settings.init();
  // 启动即预热两栈访客身份（失败不阻塞进主界面，进页面时还会重试）
  visitor
      .ensure(WbStack.pc)
      .catchError((_) => const VisitorIdentity('', '', 0));
  visitor.ensure(WbStack.m).catchError((_) => const VisitorIdentity('', '', 0));
  // 表情映射异步装入（本地缓存优先，无缓存才拉 config；失败不阻塞）
  weibo.loadEmoticons();

  // Windows IME 第二轮守卫：全局焦点监听 + 回前台补关联（见 core/ime.dart）
  installImeGuards();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<VisitorService>.value(value: visitor),
        ChangeNotifierProvider<SessionService>.value(value: session),
        Provider<WeiyueService>.value(value: weibo),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
      ],
      child: const WeiyueApp(),
    ),
  );

  // Windows IME 缓解①：启动首帧后先把 IME 上下文关联回主窗口，
  // 避免原生插件初始化顺序导致一进应用就无法调起中文输入法。
  //（非 Windows 平台 ensureImeAttached 内部直接跳过。）
  WidgetsBinding.instance.addPostFrameCallback((_) => ensureImeAttached());
}

/// 应用根（换壳第一阶段）：按平台分流三套应用壳——
/// Windows → FluentApp、iOS/macOS → CupertinoApp、Android/Linux → MaterialApp。
/// 三壳共用同一套主题设置（主题模式驱动三壳明暗）与业务屏幕；
/// 非 Material 壳靠 [_materialBridge] 给现有 Material 屏幕垫桥接层。
class WeiyueApp extends StatefulWidget {
  const WeiyueApp({super.key, this.platformOverride});

  /// 仅供测试注入平台（决定用哪套壳）；生产为 null，走真实平台。
  final TargetPlatform? platformOverride;

  @override
  State<WeiyueApp> createState() => _WeiyueAppState();
}

class _WeiyueAppState extends State<WeiyueApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 跟随系统模式下系统明暗变化时，CupertinoApp 的静态 brightness
  /// 需要重算（MaterialApp/FluentApp 由 themeMode 内部处理，一并重建无妨）。
  @override
  void didChangePlatformBrightness() => setState(() {});

  Route<dynamic>? _onGenerateRoute(RouteSettings routeSettings) {
    switch (routeSettings.name) {
      case '/search':
        return appPageRoute(
          builder: (_) =>
              const DetailScaffold(child: SearchScreen(autofocus: true)),
          settings: routeSettings,
        );
      case '/settings':
        return appPageRoute(
          builder: (_) => const DetailScaffold(child: SettingsScreen()),
          settings: routeSettings,
        );
      case '/theme':
        return appPageRoute(
          builder: (_) => const DetailScaffold(child: ThemeScreen()),
          settings: routeSettings,
        );
    }
    return null;
  }

  /// 非 Material 壳的内容桥接层：现有屏幕全部是 Material 控件，依赖
  /// Theme、Material 祖先与 ScaffoldMessenger。在应用根 builder 里统一垫：
  /// 桥接主题用应用红种子（Fluent/Cupertino 侧不用 M3 动态取色），
  /// 明暗与纯黑跟随用户设置。垫在 Navigator 之上，二级页同样受益。
  Widget _materialBridge(
    Widget? child, {
    required Brightness brightness,
    required bool pureBlack,
  }) {
    return Theme(
      data: buildTheme(
        brightness: brightness,
        seedColor: AppColors.accent,
        pureBlack: pureBlack,
      ),
      child: ScaffoldMessenger(
        child: Material(
          type: MaterialType.transparency,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final kind = shellKindForPlatform(
      widget.platformOverride ?? defaultTargetPlatform,
    );
    switch (kind) {
      case AppShellKind.material:
        // M3 主题：主题模式 + 动态取色/种子色 + 纯黑模式（原行为不变）
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
          home: AppShell(platformOverride: widget.platformOverride),
          onGenerateRoute: _onGenerateRoute,
        );
      case AppShellKind.cupertino:
        final brightness = brightnessForThemeMode(
          settings.themeMode,
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
        );
        final bridgeTheme = buildTheme(
          brightness: brightness,
          seedColor: AppColors.accent,
          pureBlack: settings.pureBlack,
        );
        return CupertinoApp(
          title: '微阅',
          debugShowCheckedModeBanner: false,
          theme: CupertinoThemeData(
            brightness: brightness,
            primaryColor: AppColors.accent,
            scaffoldBackgroundColor: bridgeTheme.scaffoldBackgroundColor,
          ),
          // 现有 Material 屏幕会用到 Material 本地化（如文本选择工具栏）
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          builder: (context, child) => _materialBridge(
            child,
            brightness: brightness,
            pureBlack: settings.pureBlack,
          ),
          home: AppShell(platformOverride: widget.platformOverride),
          onGenerateRoute: _onGenerateRoute,
        );
      case AppShellKind.fluent:
        final brightness = brightnessForThemeMode(
          settings.themeMode,
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
        );
        final accent = AppColors.accent.toAccentColor();
        return fluent.FluentApp(
          title: '微阅',
          debugShowCheckedModeBanner: false,
          themeMode: fluentThemeModeFor(settings.themeMode),
          // FluentApp 自带的是其 material_ui 包的同名 MaterialLocalizations，
          // 与 Flutter material 的类型不是同一个，AppBar/RefreshIndicator 等
          // 控件查不到会断言。这里显式补 Flutter 自己的本地化委托
          //（类型不同、与 Fluent 自带委托并存不冲突）。
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: fluent.FluentThemeData(
            brightness: Brightness.light,
            accentColor: accent,
          ),
          darkTheme: fluent.FluentThemeData(
            brightness: Brightness.dark,
            accentColor: accent,
          ),
          builder: (context, child) => _materialBridge(
            child,
            brightness: brightness,
            pureBlack: settings.pureBlack,
          ),
          home: AppShell(platformOverride: widget.platformOverride),
          onGenerateRoute: _onGenerateRoute,
        );
    }
  }
}
