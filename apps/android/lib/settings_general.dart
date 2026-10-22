import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'agent_preset_default_reconciliation.dart';
import 'configuration_state.dart';
import 'runtime.dart';
import 'ui.dart';

/// Presents the original ui-settings preference through its revisioned Host
/// document. The accepted value is the only displayed selection; an uncertain
/// write is never retried automatically.
class DeveloperToolsPreference extends ChangeNotifier {
  DeveloperToolsPreference(RuntimeController runtime)
    : _form = ConfigurationEditingController(
        runtime,
        namespace: 'ui-settings',
      ) {
    _form.addListener(notifyListeners);
  }

  final ConfigurationEditingController _form;
  bool _disposed = false;
  bool _failed = false;

  bool get enabled {
    final value = _form.accepted?['value'];
    return value is Map && value['enabled'] == true;
  }

  bool get confirmed {
    final value = _form.accepted?['value'];
    return _form.fresh &&
        _form.runtime.ready &&
        value is Map &&
        value['enabled'] is bool;
  }

  bool get busy => _form.busy || _form.loading;
  bool get canChange =>
      confirmed &&
      _form.writable &&
      !_form.busy &&
      !_form.uncertain &&
      !_form.conflict &&
      !_form.hasDraft;
  bool get needsReview => _form.uncertain || _form.conflict;
  bool get failed => _failed || _form.error != null;
  bool get canAdoptCurrent => needsReview && _form.fresh && !_form.busy;

  Future<void> start() => _form.start();
  Future<void> refresh() async {
    await _form.refresh();
    if (_disposed) return;
    if (_form.fresh && !_form.uncertain && !_form.conflict) {
      _failed = false;
      notifyListeners();
    }
  }

  void adoptCurrent() {
    if (!canAdoptCurrent) return;
    _form.discardDraft();
    _failed = false;
    notifyListeners();
  }

  Future<bool> setEnabled(bool value) async {
    if (_disposed || !canChange || value == enabled) return false;
    _failed = false;
    _form.edit(['enabled'], value);
    final saved = await _form.save();
    if (_disposed) return saved;
    if (!saved && !_form.uncertain && !_form.conflict && _form.fresh) {
      _form.discardDraft();
    }
    if (!saved) _failed = true;
    notifyListeners();
    return saved;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _form.removeListener(notifyListeners);
    _form.dispose();
    super.dispose();
  }
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
