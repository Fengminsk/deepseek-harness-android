import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'agent_preset_default_reconciliation.dart';
import 'configuration_boolean_preference.dart';
import 'runtime.dart';
import 'ui.dart';

/// The original ui-settings preference, shared with the Web client.
class DeveloperToolsPreference extends ConfigurationBooleanPreference {
  DeveloperToolsPreference(super.runtime) : super(namespace: 'ui-settings');

  bool get enabled => value;
  Future<bool> setEnabled(bool next) => setValue(next);
}

class DeveloperToolsSettingsRow extends StatefulWidget {
  const DeveloperToolsSettingsRow({required this.runtime, super.key});
  final RuntimeController runtime;

  @override
  State<DeveloperToolsSettingsRow> createState() =>
      _DeveloperToolsSettingsRowState();
}

class _DeveloperToolsSettingsRowState extends State<DeveloperToolsSettingsRow> {
  late DeveloperToolsPreference preference;
  late AgentPresetDefaultReconciler defaultReconciler;

  @override
  void initState() {
    super.initState();
    preference = DeveloperToolsPreference(widget.runtime);
    defaultReconciler = AgentPresetDefaultReconciler.forRuntime(widget.runtime);
    unawaited(preference.start());
  }

  @override
  void didUpdateWidget(DeveloperToolsSettingsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime) return;
    preference.dispose();
    preference = DeveloperToolsPreference(widget.runtime);
    defaultReconciler = AgentPresetDefaultReconciler.forRuntime(widget.runtime);
    unawaited(preference.start());
  }

  @override
  void dispose() {
    preference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([preference, defaultReconciler]),
    builder: (context, _) => Column(
      children: [
        PocketSwitchRow(
          key: const ValueKey('developer-tools-switch'),
          title: const Text('显示代码工作视图'),
          subtitle: Text(
            preference.needsReview
                ? '保存结果待核对；请刷新后再操作'
                : preference.failed
                ? '设置暂不可用，请刷新后重试'
                : '与原版共用设置，控制工作区改动展示',
          ),
          value: preference.enabled,
          onChanged: preference.canChange
              ? (value) => unawaited(preference.setEnabled(value))
              : null,
        ),
        if (preference.failed || preference.needsReview)
          PocketRow(
            icon: Icons.refresh_rounded,
            title: '重新核对代码工作视图',
            onTap: preference.busy
                ? null
                : () => unawaited(preference.refresh()),
          ),
        if (preference.canAdoptCurrent)
          PocketRow(
            icon: Icons.check_circle_outline_rounded,
            title: '以当前配置为准',
            subtitle: '放弃尚未确认的本次修改',
            onTap: preference.adoptCurrent,
          ),
        if (defaultReconciler.error != null &&
            (!preference.confirmed || !preference.enabled))
          PocketRow(
            key: const ValueKey('coding-tools-default-review'),
            icon: Icons.refresh_rounded,
            title: '核对默认 Agent 预设',
            subtitle: defaultReconciler.error,
            onTap: () => unawaited(defaultReconciler.review()),
          ),
      ],
    ),
  );
}
