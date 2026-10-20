import 'package:material_ui/material_ui.dart';

import 'tool_activity_data.dart';
import 'tool_activity_presentation.dart';
import 'ui.dart';

export 'tool_activity_data.dart' show ToolActivity, ToolActivityProjection;

/// Stable-keyed Tool card. Fold state survives streamed conversation rebuilds.
class ToolActivityCard extends StatefulWidget {
  const ToolActivityCard({
    required this.activity,
    this.initiallyExpanded = false,
    super.key,
  });
  final ToolActivity activity;
  final bool initiallyExpanded;
  @override
  State<ToolActivityCard> createState() => _ToolActivityCardState();
}

class _ToolActivityCardState extends State<ToolActivityCard>
    with AutomaticKeepAliveClientMixin {
  late bool expanded = widget.initiallyExpanded;
  late ToolActivityPresentation presentation = ToolActivityPresentation.from(
    widget.activity,
  );
  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(ToolActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.activity, widget.activity)) {
      presentation = ToolActivityPresentation.from(widget.activity);
    }
  }

  IconData get icon => switch (presentation.kind) {
    'shell' => Icons.terminal_rounded,
    'file' => Icons.description_outlined,
    'search' => Icons.search_rounded,
    _ => Icons.build_outlined,
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final activity = widget.activity;
    final fields = presentation.fields;
    final preview =
        fields['命令'] ?? fields['路径'] ?? fields['相对路径'] ?? fields['搜索表达式'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: PocketCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PocketRow(
              icon: icon,
              title: activity.name.isEmpty ? '工具调用（名称未记录）' : activity.name,
              subtitle:
                  '${toolActivityStatus(activity)}'
                  '${activity.parentCallId == null ? '' : '\n子调用 · ${activity.callId}'}'
                  '${preview == null ? '' : '\n${_preview(preview, 140)}'}',
              onTap: () => setState(() => expanded = !expanded),
              trailing: AnimatedRotation(
                turns: expanded ? .25 : 0,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                child: const Icon(Icons.chevron_right_rounded),
              ),
            ),
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: !expanded
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!activity.hasCall)
                          const _ToolText('缺少调用开始记录；未记录的名称、参数或开始时间不作推测。'),
                        if (!activity.hasResult)
                          _ToolText(
                            activity.phase == ToolActivityPhase.interrupted
                                ? '所属步骤或回合已结束，但未记录工具结果。'
                                : !activity.hasCall
                                ? '当前记录只包含子调用；上级调用的开始与结果未记录。'
                                : '尚未收到工具结果；可能仍在等待执行或授权。',
                          ),
                        if (activity.error != null)
                          _ToolText(
                            '错误：${activity.error!['name'] ?? '未命名'}'
                            ' · ${activity.error!['code'] ?? '未知代码'}'
                            '${activity.error!['reason'] == null ? '' : '\n${activity.error!['reason']}'}',
                          ),
                        for (final field in fields.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                            child: Text(
                              field.key,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ),
                          _ToolText(
                            field.value.isEmpty
                                ? '（空）'
                                : _preview(field.value, 6000),
                          ),
                        ],
                        if (fields.isEmpty && activity.hasResult)
                          const _ToolText('此工具的结构化内容保留在完整原始详情中。'),
                        if (fields.values.any((value) => value.length > 6000))
                          const _ToolText('卡片为长内容预览，完整内容可在原始详情查看。'),
                        for (final warning in activity.warnings)
                          _ToolText(warning),
                        for (final child in activity.children)
                          ToolActivityCard(
                            key: ValueKey(child.identity),
                            activity: child,
                          ),
                        PocketDisclosure(
                          key: ValueKey('raw-${activity.identity}'),
                          title: '完整原始详情',
                          child: _RawToolDetails(activity: activity),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RawToolDetails extends StatelessWidget {
  const _RawToolDetails({required this.activity});
  final ToolActivity activity;
  @override
  Widget build(BuildContext context) =>
      SelectableText(activity.rawJson, style: const TextStyle(fontSize: 12));
}

class _ToolText extends StatelessWidget {
  const _ToolText(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    child: SelectableText(text),
  );
}

String _preview(String value, int limit) =>
    value.length <= limit ? value : '${value.substring(0, limit)}…';
