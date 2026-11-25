// 远程会话页的悬浮任务卡片：`todos` 投影的收起摘要与展开清单。
//
// 收起态一行：清单图标 +「任务」+ 按状态分段的计数 + 展开箭头。展开态在卡片内
// 列出每条待办的状态图标与文本，已完成的文本划掉，长文本最多两行；清单区最高
// 占屏幕 28% 且不超过 220dp，内部滚动，待办再多也不会把输入区挤出屏幕。投影里
// 没有待办（null / 空列表）时整张卡片不渲染。
//
// 组件只负责绘制与回调：[todos]、[expanded] 与 [onToggle] 都由页面持有，因此
// 同一会话内的面板重建（窗口刷新、流式增量）保留展开状态，换到别的会话重建
// 页面即回到收起态。组件内部没有动画、定时器或订阅，只在父级传入新读数时重建；
// 视觉沿用本地会话页 `ChatTodoDock`（chat_deliverables.dart）那套玻璃卡片。

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'design/typography.dart';
import 'remote_session_insights.dart';
import 'ui.dart';

/// 远程会话的待办卡片。
class RemoteTodoCard extends StatelessWidget {
  /// 创建待办卡片。
  const RemoteTodoCard({
    super.key,
    required this.todos,
    required this.expanded,
    required this.onToggle,
  });

  /// 当前待办；null 或空列表时不渲染卡片（宿主没有这份投影的记录）。
  final List<RemoteTodoItem>? todos;

  /// 是否展开清单。
  final bool expanded;

  /// 点按摘要行：由页面翻转 [expanded]。
  final VoidCallback onToggle;

  /// 摘要行的测试与无障碍标识。
  static const Key toggleKey = ValueKey('remote-todo-toggle');

  /// 展开清单的测试标识。
  static const Key listKey = ValueKey('remote-todo-list');

  /// 第 [index] 条待办的测试标识（顺序即宿主给出的顺序）。
  static Key itemKey(int index) => ValueKey('remote-todo-item-$index');

  @override
  Widget build(BuildContext context) {
    final todos = this.todos;
    if (todos == null || todos.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final summary = _summaryOf(todos);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassSurface(
        radius: 26,
        child: Material(
          type: MaterialType.transparency,
          shape: AppShape.all(26),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                button: true,
                expanded: expanded,
                label: '任务：$summary，${expanded ? '收起' : '展开'}任务清单',
                onTap: onToggle,
                child: ExcludeSemantics(
                  child: ElasticPress(
                    child: InkWell(
                      key: toggleKey,
                      customBorder: AppShape.all(26),
                      onTap: onToggle,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                          child: Row(
                            children: [
                              Icon(
                                Icons.checklist_rounded,
                                size: 20,
                                color: colors.onSurfaceVariant,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '任务',
                                style: AppTextStyle.subheadline.of(
                                  context,
                                  emphasized: true,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  summary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyle.caption1
                                      .of(context)
                                      .copyWith(color: colors.onSurfaceVariant),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                expanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                size: 20,
                                color: colors.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (expanded) _list(context, todos),
            ],
          ),
        ),
      ),
    );
  }

  /// 展开态的清单：状态图标 + 文本，最多占屏幕 28%（不超过 220dp），内部滚动。
  Widget _list(BuildContext context, List<RemoteTodoItem> todos) {
    final colors = Theme.of(context).colorScheme;
    final maxHeight = math.min(MediaQuery.sizeOf(context).height * .28, 220.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Column(
            key: listKey,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Divider(
                height: 1,
                thickness: .5,
                indent: 16,
                endIndent: 16,
                color: colors.outlineVariant.withValues(alpha: .4),
              ),
              for (var index = 0; index < todos.length; index++)
                _RemoteTodoRow(key: itemKey(index), item: todos[index]),
            ],
          ),
        ),
      ),
    );
  }

  /// 摘要行里按状态分段的计数；计数为 0 的状态不写。
  ///
  /// 顺序与措辞按本页要求（已完成 / 进行中 / 待处理），与本地 `ChatTodoDock`
  /// 的「N 项待开始 · N 项进行中」写法不同。
  static String _summaryOf(List<RemoteTodoItem> todos) {
    var completed = 0;
    var inProgress = 0;
    for (final item in todos) {
      switch (item.status) {
        case RemoteTodoStatus.pending:
          break;
        case RemoteTodoStatus.inProgress:
          inProgress++;
        case RemoteTodoStatus.completed:
          completed++;
      }
    }
    final pending = todos.length - completed - inProgress;
    return [
      if (completed > 0) '已完成 $completed',
      if (inProgress > 0) '进行中 $inProgress',
      if (pending > 0) '待处理 $pending',
    ].join(' · ');
  }
}

/// 展开清单里的一行：状态图标、文本（已完成划掉）。
class _RemoteTodoRow extends StatelessWidget {
  const _RemoteTodoRow({super.key, required this.item});

  final RemoteTodoItem item;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final completed = item.status == RemoteTodoStatus.completed;
    final (icon, tint, label) = switch (item.status) {
      RemoteTodoStatus.pending => (
        Icons.radio_button_unchecked_rounded,
        colors.onSurfaceVariant,
        '待处理',
      ),
      RemoteTodoStatus.inProgress => (
        Icons.timelapse_rounded,
        colors.primary,
        '进行中',
      ),
      RemoteTodoStatus.completed => (
        Icons.check_circle_outline_rounded,
        colors.primary,
        '已完成',
      ),
    };
    return Semantics(
      label: '$label：${item.content}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: tint),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline
                      .of(context)
                      .copyWith(
                        color: completed
                            ? colors.onSurfaceVariant.withValues(alpha: .7)
                            : colors.onSurface,
                        decoration: completed
                            ? TextDecoration.lineThrough
                            : null,
                        decorationColor: colors.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
