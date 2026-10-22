import 'package:flutter/foundation.dart';

import 'configuration_state.dart';
import 'runtime.dart';

/// The original ui-settings/enabled value, observed through the existing
/// revisioned settings controller. No App-only switch or local default exists.
/// DSH's Host schema supplies true by default; until the Host accepts a boolean,
/// DeveloperToolsPreference and this adapter both keep capabilities disabled.
class WorkspaceChangesPreference extends ChangeNotifier {
  WorkspaceChangesPreference(RuntimeController runtime)
    : _form = ConfigurationEditingController(
        runtime,
        namespace: 'ui-settings',
      ) {
    _form.addListener(_changed);
  }
  final ConfigurationEditingController _form;
  bool _enabled = false, _confirmed = false;
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
    if (_enabled == enabled && _confirmed == confirmed) return;
    _enabled = enabled;
    _confirmed = confirmed;
    notifyListeners();
  }

  @override
  void dispose() {
    _form.removeListener(_changed);
    _form.dispose();
    super.dispose();
  }
}
