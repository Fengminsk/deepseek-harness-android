import 'package:flutter/foundation.dart';

import 'configuration_state.dart';
import 'runtime.dart';

/// One revisioned Host boolean. The accepted value remains visible until a
/// write is confirmed; an uncertain write requires an explicit fresh read.
class ConfigurationBooleanPreference extends ChangeNotifier {
  ConfigurationBooleanPreference(
    RuntimeController runtime, {
    required String namespace,
    this.field = 'enabled',
  }) : _form = ConfigurationEditingController(runtime, namespace: namespace) {
    _form.addListener(notifyListeners);
  }

  final String field;
  final ConfigurationEditingController _form;
  bool _disposed = false;
  bool _failed = false;

  bool get value {
    final accepted = _form.accepted?['value'];
    return accepted is Map && accepted[field] == true;
  }

  bool get confirmed {
    final accepted = _form.accepted?['value'];
    final schema = _form.accepted?['schema'];
    final fields = schema is Map ? schema['dict'] : null;
    final fieldSchema = fields is Map ? fields[field] : null;
    return _form.fresh &&
        _form.runtime.ready &&
        accepted is Map &&
        accepted[field] is bool &&
        fieldSchema is Map &&
        fieldSchema['type'] == 'boolean';
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

  Future<bool> setValue(bool next) async {
    if (_disposed || !canChange || next == value) return false;
    _failed = false;
    _form.edit([field], next);
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
