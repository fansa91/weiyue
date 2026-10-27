import 'package:flutter/foundation.dart';

/// 「再次点击首页」回顶信号：AppShell 在已选中首页时再次点中
/// 首页（底部栏/侧边栏）递增此值，首页的 HotFeedView 监听后
/// 把当前分类的信息流平滑滚回顶部。计数型信号，无需参数。
final ValueNotifier<int> homeTopSignal = ValueNotifier<int>(0);

/// 触发一次首页回顶。
void signalHomeTop() => homeTopSignal.value++;
