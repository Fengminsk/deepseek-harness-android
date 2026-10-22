import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agent_presets_data.dart';
import 'runtime.dart';

/// Keeps the next-session default usable when the accepted Coding Tools
/// preference is off. Existing sessions and their selected presets are never
/// changed. A write is fenced by the Host settings revision and is never
/// replayed automatically after an ambiguous reply.
class AgentPresetDefaultReconciler extends ChangeNotifier {
  AgentPresetDefaultReconciler(this.runtime);

  static final Expando<AgentPresetDefaultReconciler> _byRuntime = Expando();

  /// Several screen controllers observe one RuntimeController. They must share
  /// the same write fence and uncertain-result state.
  factory AgentPresetDefaultReconciler.forRuntime(RuntimeController runtime) {
    final existing = _byRuntime[runtime];
    if (existing != null && !existing._disposed) return existing;
    final created = AgentPresetDefaultReconciler(runtime);
    _byRuntime[runtime] = created;
    return created;
  }

  final RuntimeController runtime;
  final Set<bool Function()> _owners = {};
  bool _disposed = false;
  Future<void>? _pending;
  bool _again = false;
  final Set<String> _attempted = {};
  bool uncertain = false;
  String? error;

  VoidCallback attach(bool Function() disabled) {
    if (_disposed) throw StateError('Default reconciler is closed');
    _owners.add(disabled);
    return () => _owners.remove(disabled);
  }

  bool get _disabled => _owners.any((owner) => owner());

  Future<dynamic> _api(
    String namespace,
    String method, [
    Json args = const {},
  ]) => runtime
      .call('api.call', {
        'namespace': namespace,
        'method': method,
        'args': args,
      })
      .timeout(agentPresetRequestTimeout);

  bool _current(int connection) =>
      !_disposed &&
      runtime.ready &&
      connection == runtime.connectionGeneration &&
      _disabled;

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  /// Coalesces settings invalidations while a read or write is in flight.
  Future<void> reconcile() {
    if (_disposed || !runtime.ready || !_disabled) return Future.value();
    if (_pending != null) {
      _again = true;
      return _pending!;
    }
    late final Future<void> operation;
    operation =
        () async {
          do {
            _again = false;
            await _reconcileOnce(allowWrite: true);
          } while (_again && !_disposed && runtime.ready && _disabled);
        }().whenComplete(() {
          if (!identical(_pending, operation)) return;
          _pending = null;
          // A late invalidation can land after the loop's final check but
          // before this completion callback clears the shared in-flight slot.
          if (_again && !_disposed && runtime.ready && _disabled) {
            unawaited(reconcile());
          }
        });
    return _pending = operation;
  }

  /// Inspect the current Host state without attempting another default write.
  /// This is safe after an unknown result and is the settings row's action.
  Future<void> review() async {
    if (_pending != null) await _pending;
    await _reconcileOnce(allowWrite: false);
  }

  Future<void> _reconcileOnce({required bool allowWrite}) async {
    final connection = runtime.connectionGeneration;
    if (!_current(connection)) return;
    try {
      final described = await _api('settings', 'describe');
      if (!_current(connection)) return;
      if (described is! Json ||
          described['writable'] is! bool ||
          described['namespaces'] is! List) {
        throw const FormatException('默认预设设置状态不完整');
      }
      Json? tools, preset;
      for (final raw in described['namespaces'] as List) {
        if (raw is! Json) continue;
        if (raw['ns'] == 'ui-settings') tools = raw;
        if (raw['ns'] == agentPresetSettingsNamespace) preset = raw;
      }
      // The observable toggle may be temporarily false before the first Host
      // document. Only a resolved false value can authorize reconciliation.
      if (tools?['value'] is! Json ||
          (tools!['value'] as Json)['enabled'] != false ||
          preset == null ||
          described['writable'] != true) {
        return;
      }
      final revision = preset['revision'];
      if (revision is! int || revision < 0) return;

      final roster = await _api('agentPresets', 'list');
      if (!_current(connection)) return;
      if (roster is! Json || roster['presets'] is! List) {
        throw const FormatException('预设目录不完整');
      }
      final rows = <AgentPresetOption>[];
      for (final raw in roster['presets'] as List) {
        rows.add(AgentPresetOption.fromJson(raw));
      }
      final defaults = rows.where((row) => row.isDefault).toList();
      if (defaults.length != 1) return;
      final current = defaults.single;
      final configured = preset['value'];
      if (configured is Json) {
        final selected = configured['selectedDefault'] ?? configured['default'];
        if (selected is String && selected != current.id) {
          error = '默认预设目录与配置不同步，请刷新核对。';
          _publish();
          return;
        }
      }
      if (!current.requiresCodingTools) {
        if (uncertain || error != null) {
          uncertain = false;
          error = null;
          _publish();
        }
        return;
      }
      final standard = rows.where((row) => row.id == 'standard');
      if (standard.length != 1 || !standard.single.available) {
        error = '标准模式不可用，请恢复该模式或选择其他可用模式。';
        _publish();
        return;
      }
      if (uncertain || !allowWrite) return;
      final key = '$revision:${current.id}';
      if (!_attempted.add(key)) return;
      if (!_current(connection)) return;

      try {
        final reply = await _api('settings', 'update', {
          'ns': agentPresetSettingsNamespace,
          'patch': {'selectedDefault': 'standard'},
          'expectedRevision': revision,
        });
        if (_disposed) return;
        if (!_current(connection)) {
          uncertain = true;
          error = '连接变化，默认预设回退结果待核对；不会自动重发。';
          _publish();
          return;
        }
        if (reply is! Json ||
            reply['value'] is! Json ||
            (reply['value'] as Json)['selectedDefault'] != 'standard') {
          throw const FormatException('默认预设回执未确认 Standard');
        }
        uncertain = false;
        error = null;
        _publish();
      } catch (failure) {
        if (_disposed) return;
        // settings/rejected can also follow a committed write when the Host's
        // post-write describe fails. Only a revision conflict proves refusal.
        uncertain =
            failure is! PlatformException ||
            failure.code != 'settings/conflict';
        error = uncertain
            ? '默认预设回退结果待核对；不会自动重发：$failure'
            : '默认预设已被其他修改更新，请刷新核对。';
        _publish();
      }
    } catch (failure) {
      if (!_current(connection)) return;
      error = '无法核对默认预设：$failure';
      _publish();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _owners.clear();
    super.dispose();
  }
}
