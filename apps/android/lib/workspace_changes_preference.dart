import 'dart:async';

import 'package:flutter/foundation.dart';

import 'agent_preset_default_reconciliation.dart';
import 'configuration_state.dart';
import 'runtime.dart';

/// The original ui-settings/enabled value, observed through the existing
/// revisioned settings controller. No App-only switch or local default exists.
/// DSH's Host schema supplies true by default; until the Host accepts a boolean,
/// DeveloperToolsPreference and this adapter both keep capabilities disabled.
class WorkspaceChangesPreference extends ChangeNotifier {
  WorkspaceChangesPreference(RuntimeController runtime)
    : _form = ConfigurationEditingController(runtime, namespace: 'ui-settings'),
      defaultReconciler = AgentPresetDefaultReconciler.forRuntime(runtime) {
    _releaseReconciler = defaultReconciler.attach(
      () => !_disposed && _confirmed && !_enabled,
    );
    _form.addListener(_changed);
  }
  final ConfigurationEditingController _form;
  final AgentPresetDefaultReconciler defaultReconciler;
  late final VoidCallback _releaseReconciler;
  bool _enabled = false, _confirmed = false;
  bool _disposed = false;
  bool get enabled => _enabled;
  bool get confirmed => _confirmed;
  Future<void> start() => _form.start();

  void _changed() {
    final value = _form.accepted?['value'];
    final confirmed =
        _form.fresh &&
        _form.runtime.ready &&
        value is Map &&
        value['enabled'] is bool;
    final enabled = confirmed && value['enabled'] == true;
    final changed = _enabled != enabled || _confirmed != confirmed;
    _enabled = enabled;
    _confirmed = confirmed;
    if (confirmed && !enabled && !_form.busy) {
      // The Host accepted false. Recheck the roster and default even when an
      // unrelated settings invalidation arrives while this view stays mounted.
      unawaited(defaultReconciler.reconcile());
    }
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _form.removeListener(_changed);
    _form.dispose();
    _releaseReconciler();
    super.dispose();
  }
}
