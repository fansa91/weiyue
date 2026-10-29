import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 查看器（图库 / 长图阅读器）桌面导航共用件：
/// - 宽屏（≥900，与应用既有桌面断点一致）时在查看区左右两侧显示
///   上一张/下一张圆形按钮；窄屏（移动端）不显示，靠手势翻页。
/// - 键盘左右方向键切换（[ViewerKeyboardShortcuts] 挂在查看器内部，
///   只在查看器路由内生效，不影响其他页面）。

/// 当前宽度是否显示两侧按钮（桌面/宽屏）。
bool viewerShowsSideButtons(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 900;

/// 查看区两侧的上一张/下一张圆形按钮。
///
/// 自身是一个填满 Stack 的覆盖层，调用方需把它放进 Stack 并用
/// Positioned.fill 包裹。多图（count>1）才由调用方挂载；首张时
/// 上一张禁用、末张时下一张禁用。
class ViewerSideButtons extends StatelessWidget {
  final int index;
  final int count;
  final ValueChanged<int> onGoTo;

  const ViewerSideButtons({
    super.key,
    required this.index,
    required this.count,
    required this.onGoTo,
  });

  Widget _button({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: IconButton(
        key: key,
        icon: Icon(icon, size: 26),
        color: Colors.white,
        disabledColor: Colors.white24,
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    return Stack(
      children: [
        Positioned(
          left: 10,
          top: 0,
          bottom: 0,
          child: Center(
            child: _button(
              key: const ValueKey('viewer-prev-button'),
              icon: Icons.chevron_left,
              tooltip: '上一张',
              onPressed: index > 0 ? () => onGoTo(index - 1) : null,
            ),
          ),
        ),
        Positioned(
          right: 10,
          top: 0,
          bottom: 0,
          child: Center(
            child: _button(
              key: const ValueKey('viewer-next-button'),
              icon: Icons.chevron_right,
              tooltip: '下一张',
              onPressed: index < count - 1 ? () => onGoTo(index + 1) : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// 方向键快捷键包装：聚焦后左右方向键触发上一张/下一张。
///
/// 用 Focus 自带 autofocus 抢焦点（查看器是全屏路由，抢焦点无副作用）；
/// 不可切换的方向（首张左键/末张右键）直接忽略不拦截。
class ViewerKeyboardShortcuts extends StatelessWidget {
  final Widget child;
  final bool canPrev;
  final bool canNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  const ViewerKeyboardShortcuts({
    super.key,
    required this.child,
    required this.canPrev,
    required this.canNext,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft && canPrev) {
          onPrev();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight && canNext) {
          onNext();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
