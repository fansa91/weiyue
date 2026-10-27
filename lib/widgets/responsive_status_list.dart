import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../models/models.dart';
import 'status_card.dart';

/// 宽屏瀑布流列数：<900 单列（普通列表），之后每档加一列。
/// 纯函数，单元测试锁死阈值——v0.1.1 的教训是列数逻辑写了却因
/// 外层 680 封顶永远触发不了，这次阈值与外层解耦、单独可测。
int feedColumnCount(double width) {
  if (width >= 2200) return 5;
  if (width >= 1750) return 4;
  if (width >= 1300) return 3;
  if (width >= 900) return 2;
  return 1;
}

/// 帖子卡片列表的响应式实现：窄屏单列 ListView，宽屏（≥900）
/// SliverMasonryGrid 瀑布流。热门流/话题/合集/主页各页签/搜索结果
/// 共用，避免每处各写一份宽度判断。
///
/// [header] 显示在列表顶部（两种模式都在）；[footer] 置底
/// （加载/到底/空态文案由调用方决定）。滚动由 [controller] 驱动，
/// 调用方负责监听翻页。
class ResponsiveStatusList extends StatelessWidget {
  final List<WbStatus> items;
  final ScrollController? controller;
  final Widget? header;
  final Widget? footer;
  final EdgeInsets padding;

  const ResponsiveStatusList({
    super.key,
    required this.items,
    this.controller,
    this.header,
    this.footer,
    this.padding = const EdgeInsets.fromLTRB(8, 8, 8, 0),
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = feedColumnCount(constraints.maxWidth);
        if (cols <= 1) {
          return ListView.builder(
            controller: controller,
            padding: padding,
            itemCount:
                items.length +
                (header != null ? 1 : 0) +
                (footer != null ? 1 : 0),
            itemBuilder: (context, i) {
              var idx = i;
              if (header != null) {
                if (idx == 0) return header!;
                idx -= 1;
              }
              if (idx < items.length) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: StatusCard(status: items[idx]),
                );
              }
              return footer ?? const SizedBox.shrink();
            },
          );
        }
        return CustomScrollView(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (header != null) SliverToBoxAdapter(child: header),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              sliver: SliverMasonryGrid.count(
                crossAxisCount: cols,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childCount: items.length,
                itemBuilder: (context, i) => StatusCard(status: items[i]),
              ),
            ),
            if (footer != null) SliverToBoxAdapter(child: footer),
          ],
        );
      },
    );
  }
}
