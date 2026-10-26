import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

String reasoningEffortLabel(String? id, {String? fallback}) => switch (id) {
  null => '默认',
  'none' || 'off' => '关闭',
  'minimal' => '极低',
  'low' => '低',
  'medium' => '中',
  'high' => '高',
  'xhigh' => '极高',
  'max' => '最高',
  'ultra' => '超高',
  _ => fallback ?? id,
};

String modelDescription(Json group, Json model) {
  if (group['id'] == 'deepseek-account') {
    if (model['id'] == 'deepseek-v4-pro') return '适合复杂推理与编程，耗时和费用较高';
    if (model['id'] == 'deepseek-flash') return '响应更快，适合日常任务';
  }
  return '${model['description'] ?? ''}';
}

/// Catalog-backed detents; the default detent stays distinct from its value.
class ModelReasoningControl extends StatelessWidget {
  const ModelReasoningControl({
    super.key,
    required this.reasoning,
    required this.value,
    required this.onChanged,
    required this.controlKey,
  });

  final Json reasoning;
  final String? value;
  final ValueChanged<String?>? onChanged;
  final Key controlKey;

  String get description {
    if (value == null) {
      final fallback = reasoning['defaultEffort'] as String?;
      return fallback == null
          ? '使用服务商默认强度'
          : '模型默认：${reasoningEffortLabel(fallback)}';
    }
    return switch (value) {
      'none' || 'off' => '直接回答，关闭推理',
      'minimal' || 'low' => '更快响应，适合简单任务',
      'medium' => '兼顾响应速度与推理深度',
      'high' => '深入推理，适合多数任务',
      'xhigh' || 'max' || 'ultra' => '更充分地推理，耗时较长',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final efforts = (reasoning['efforts'] as List? ?? []).cast<Json>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedControl<String?>(
          key: controlKey,
          segments: [
            (null, '默认'),
            for (final effort in efforts)
              (
                '${effort['id']}',
                reasoningEffortLabel(
                  '${effort['id']}',
                  fallback: effort['name'] as String?,
                ),
              ),
          ],
          value: value,
          onChanged: onChanged,
        ),
        if (description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
