import 'dart:async';

import 'package:flutter/foundation.dart';

import 'configuration_edits.dart';
import 'configuration_fields_schema.dart';
import 'configuration_state.dart';
import 'credentials_data.dart';
import 'runtime.dart';

const webSearchNamespace = 'web-search-deepseek';
const webApiNamespace = 'web-deepseek-api';
const webRoutingNamespace = 'web';

enum WebSearchMode { messages, api, custom }

String webSearchModeLabel(WebSearchMode mode) => switch (mode) {
  WebSearchMode.messages => '对话式搜索',
  WebSearchMode.api => '搜索与网页读取',
  WebSearchMode.custom => '自定义组合',
};

String webSearchSectionLabel(String namespace) => switch (namespace) {
  webSearchNamespace => '对话式搜索参数',
  webApiNamespace => '搜索与网页读取参数',
  webRoutingNamespace => '搜索与读取方式',
  _ => namespace,
};

/// One staged workflow over DSH's three versioned settings sections. Writes
/// remain sequential, not atomic: a confirmed section is never rolled back or
/// replayed when a later section fails. Credential literals stay in memory.
class WebSearchSettingsController extends ChangeNotifier {
  WebSearchSettingsController(this.runtime)
    : credentials = runtime.credentials {
    sections = {
      for (final namespace in [
        webRoutingNamespace,
        webSearchNamespace,
        webApiNamespace,
      ])
        namespace: ConfigurationEditingController(
          runtime,
          namespace: namespace,
        ),
    };
    for (final section in sections.values) {
      section.addListener(_changed);
    }
    credentials.addListener(_credentialsChanged);
  }

  final RuntimeController runtime;
  final CredentialsController credentials;
  late final Map<String, ConfigurationEditingController> sections;
  final Map<String, String> _keys = {};
  final Map<String, CredentialWrite> _keyWrites = {};
  final Map<String, int> _keyWriteConnections = {};
  final Map<String, CredentialWrite?> _observedKeyWrites = {};
  final Set<String> _keyReviews = {};
  String? _writingReference;
  final Set<String> _watchedReferences = {};
  final List<String> completed = [];
  bool saving = false, initialized = false;
  String? notice;
  bool _disposed = false, _syncing = false;
  int _editors = 0;

  ConfigurationEditingController section(String namespace) =>
      sections[namespace]!;
  bool available(String namespace) => section(namespace).accepted != null;
  bool get loading => sections.values.any((section) => section.loading);
  bool get canChooseMode =>
      !saving &&
      [webRoutingNamespace, webSearchNamespace, webApiNamespace].every(
        (ns) => available(ns) && section(ns).canEdit && section(ns).writable,
      );
  bool editable(String namespace) =>
      !saving && section(namespace).canEdit && section(namespace).writable;

  List<ConfigurationEditingController> get served =>
      sections.values.where((section) => section.accepted != null).toList();

  bool _edited(ConfigurationEditingController scope) =>
      scope.accepted != null &&
      scope.draft != null &&
      configurationEdits(scope.accepted!, scope.draft!).isNotEmpty;

  bool get hasDraft =>
      _editors > 0 ||
      _keys.isNotEmpty ||
      served.any((section) => _edited(section) || section.uncertain);

  bool get needsReview =>
      _keyReviews.isNotEmpty ||
      served.any((section) => section.conflict || section.uncertain) ||
      _keys.keys.any(
        (ref) => credentials.entry(ref).write?.state == 'unconfirmed',
      );

  bool get canOpenAdvanced => !saving && !hasDraft && !needsReview;

  bool get canSave =>
      !saving &&
      initialized &&
      runtime.ready &&
      available(webSearchNamespace) &&
      hasDraft &&
      _editors == 0 &&
      served.every(
        (scope) =>
            scope.fresh &&
            scope.writable &&
            !scope.busy &&
            !scope.conflict &&
            !scope.uncertain,
      ) &&
      _keys.keys.every((ref) {
        final row = credentials.entry(ref);
        return credentials.canWrite(row) &&
            !_keyReviews.contains(ref) &&
            row.write?.state != 'unconfirmed' &&
            (row.draft.isEmpty || row.draft == _keys[ref]);
      });

  /// Removed fields display the deployment's inherited value without storing
  /// it back into the draft. No hard-coded endpoint overrides a launch setting.
  dynamic value(String namespace, String field) {
    final scope = section(namespace);
    final current = configurationValueAt(scope.draft, [field]);
    return configurationHasValue(current)
        ? current
        : configurationValueAt(scope.accepted?['base'], [field]);
  }

  WebSearchMode get mode {
    final search = value(webRoutingNamespace, 'searchProvider');
    final fetch = value(webRoutingNamespace, 'fetchProvider');
    if (search == 'deepseek-official' && fetch == 'http') {
      return WebSearchMode.messages;
    }
    if (search == 'deepseek-search-api' && fetch == 'deepseek-fetch-api') {
      return WebSearchMode.api;
    }
    return WebSearchMode.custom;
  }

  ConfigurationFieldSchema? field(String namespace, String name) {
    final descriptor = section(namespace).accepted;
    if (descriptor == null) return null;
    final schema = ConfigurationSchema(descriptor['schema']);
    return ConfigurationFieldSchema(schema, schema.root).fields[name];
  }

  String? reference(String namespace) {
    final ref = value(namespace, 'apiKeyEnv');
    if (!configurationHasValue(ref) || ref == null || ref == '') {
      return 'DEEPSEEK_API_KEY';
    }
    return ref is String && validCredentialReference(ref) ? ref : null;
  }

  String keyDraft(String reference) => _keys[reference] ?? '';
  bool keyNeedsReview(String reference) => _keyReviews.contains(reference);
  Iterable<String> get stagedReferences => _keys.keys;

  void editKey(String reference, String text) {
    if (saving || !validCredentialReference(reference)) return;
    final row = credentials.entry(reference);
    if (row.write?.inFlight == true || row.write?.state == 'unconfirmed') {
      return;
    }
    _keyWrites.remove(reference);
    _keyWriteConnections.remove(reference);
    _keyReviews.remove(reference);
    _observedKeyWrites[reference] = row.write;
    if (text.isEmpty) {
      _keys.remove(reference);
    } else {
      _keys[reference] = text;
    }
    notice = null;
    _changed();
  }

  /// This abandons only this screen's input. It does not remove a credential or
  /// pretend that an unconfirmed request was cancelled.
  void discardKey(String reference) {
    if (saving || credentials.entry(reference).write?.inFlight == true) return;
    _keys.remove(reference);
    _keyWrites.remove(reference);
    _keyWriteConnections.remove(reference);
    _observedKeyWrites.remove(reference);
    _keyReviews.remove(reference);
    _changed();
  }

  void holdEditor(bool held) {
    _editors = (_editors + (held ? 1 : -1)).clamp(0, 100);
    _changed();
  }

  void edit(String namespace, String key, dynamic next, {bool remove = false}) {
    if (!editable(namespace)) return;
    final schema = field(namespace, key);
    if (schema == null || schema.secret) return;
    if (!remove && schema.validate(next) != null) return;
    if (!remove &&
        key == 'apiKeyEnv' &&
        (next is! String || !validCredentialReference(next))) {
      return;
    }
    section(namespace).edit([key], next, remove: remove);
    notice = null;
    _changed();
  }

  void chooseMode(WebSearchMode next) {
    if (!canChooseMode || next == WebSearchMode.custom || next == mode) return;
    final targets = next == WebSearchMode.api
        ? {
            'searchProvider': 'deepseek-search-api',
            'fetchProvider': 'deepseek-fetch-api',
          }
        : {'searchProvider': 'deepseek-official', 'fetchProvider': 'http'};
    final scope = section(webRoutingNamespace);
    final draft = cloneConfiguration(scope.draft!);
    for (final item in targets.entries) {
      final inherited = configurationValueAt(scope.accepted!['base'], [
        item.key,
      ]);
      final wasOverridden = configurationHasValue(
        configurationValueAt(scope.accepted!['user'], [item.key]),
      );
      // An already inherited target needs no fake removal edit. An explicit
      // override equal to the deployment target is intentionally cleared.
      if (inherited == item.value &&
          (wasOverridden ||
              configurationValueAt(scope.accepted!['value'], [item.key]) !=
                  item.value)) {
        draft.remove(item.key);
      } else {
        draft[item.key] = item.value;
      }
    }
    scope.replaceDraft(draft);
    notice = null;
    _changed();
  }

  Future<void> start() async {
    credentials.start();
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed || saving) return;
    await Future.wait(sections.values.map((section) => section.refresh()));
    if (_disposed) return;
    initialized = true;
    await Future.wait(
      {
        for (final ns in [webSearchNamespace, webApiNamespace])
          if (available(ns) && reference(ns) != null) reference(ns)!,
        ..._keys.keys,
      }.map(credentials.readReference),
    );
    _changed();
  }

  void _credentialsChanged() {
    if (_disposed) return;
    for (final ref in _keys.keys) {
      if (_writingReference == ref) continue;
      final current = credentials.entry(ref).write;
      if (!identical(current, _observedKeyWrites[ref])) {
        // Another editor may have replaced or removed this shared credential.
        // A later combined save must never silently restore our older input.
        _keyReviews.add(ref);
      }
    }
    // A late receipt is evidence only for the exact write this workflow began.
    // Merely seeing "configured" cannot confirm the submitted key literal.
    for (final ref in _keyWrites.keys.toList()) {
      final action = _keyWrites[ref]!;
      if (identical(credentials.entry(ref).write, action) &&
          action.state == 'confirmed') {
        if (_keyWriteConnections[ref] != runtime.connectionGeneration) {
          _keyReviews.add(ref);
          continue;
        }
        _keys.remove(ref);
        _keyWrites.remove(ref);
        _keyWriteConnections.remove(ref);
        _observedKeyWrites.remove(ref);
        _keyReviews.remove(ref);
      }
    }
    _changed();
  }

  void _changed() {
    if (_disposed || _syncing) return;
    _syncing = true;
    final held = hasDraft || saving;
    for (final scope in served) {
      scope.holdDraft(held);
    }
    for (final ns in [webSearchNamespace, webApiNamespace]) {
      if (!available(ns)) continue;
      final ref = reference(ns);
      if (ref != null && _watchedReferences.add(ref)) {
        unawaited(credentials.readReference(ref));
      }
    }
    _syncing = false;
    notifyListeners();
  }

  /// Preflight every served revision before any write. Settings API checks
  /// each revision again at commit; no client-side transaction is claimed.
  Future<void> save() async {
    if (!canSave) return;
    saving = true;
    notice = null;
    completed.clear();
    final connection = runtime.connectionGeneration;
    _changed();
    bool current() =>
        !_disposed &&
        runtime.ready &&
        runtime.connectionGeneration == connection;
    bool ready() =>
        current() &&
        served.every(
          (scope) =>
              scope.fresh &&
              scope.writable &&
              !scope.conflict &&
              !scope.uncertain,
        );
    try {
      await Future.wait(served.map((scope) => scope.refresh()));
      if (!ready()) {
        notice = '配置已经变化或尚未核对，未开始保存。请处理后再保存。';
        return;
      }
      for (final ns in [webSearchNamespace, webApiNamespace]) {
        final scope = section(ns);
        if (!_edited(scope)) continue;
        if (!ready() || !await scope.save() || !current()) {
          notice = '保存停在${webSearchSectionLabel(ns)}；后续凭据和服务切换尚未提交。';
          return;
        }
        completed.add(webSearchSectionLabel(ns));
      }
      for (final entry in _keys.entries.toList()) {
        if (!ready()) {
          notice = '配置状态已变化，未继续保存凭据和服务切换。';
          return;
        }
        final row = credentials.entry(entry.key);
        await credentials.readReference(entry.key);
        if (!current() ||
            _keyReviews.contains(entry.key) ||
            !credentials.canWrite(row) ||
            row.write?.state == 'unconfirmed' ||
            row.draft.isNotEmpty && row.draft != entry.value) {
          notice = '凭据 ${entry.key} 尚不能确认写入，后续服务切换未提交。请核对凭据状态。';
          return;
        }
        credentials.edit(entry.key, entry.value);
        _writingReference = entry.key;
        final operation = credentials.save(entry.key);
        final action = row.write;
        _observedKeyWrites[entry.key] = action;
        _writingReference = null;
        if (action != null) {
          _keyWrites[entry.key] = action;
          _keyWriteConnections[entry.key] = connection;
        }
        await operation;
        if (!current() ||
            action == null ||
            !identical(row.write, action) ||
            action.state != 'confirmed') {
          notice = '凭据写入未确认；未提交后续服务切换，不会自动重发。';
          return;
        }
        _keys.remove(entry.key);
        _keyWrites.remove(entry.key);
        _keyWriteConnections.remove(entry.key);
        _observedKeyWrites.remove(entry.key);
        _keyReviews.remove(entry.key);
        completed.add('凭据 ${entry.key}');
      }
      if (!ready()) {
        notice = '服务切换前配置已变化，请核对后再保存。';
        return;
      }
      final routing = section(webRoutingNamespace);
      if (_edited(routing)) {
        if (!await routing.save() || !current()) {
          notice = '服务切换尚未确认。已确认的参数仍保留，不会自动重放。';
          return;
        }
        completed.add(webSearchSectionLabel(webRoutingNamespace));
      }
      notice = '网页搜索设置已保存。';
    } finally {
      if (!_disposed) {
        saving = false;
        _changed();
      }
    }
  }

  List<ConfigurationConflict> conflicts(String namespace) {
    final scope = section(namespace);
    if (scope.accepted == null || scope.draft == null || scope.latest == null) {
      return [];
    }
    return rebaseConfiguration(
      scope.accepted!,
      scope.draft!,
      scope.latest!,
    ).conflicts;
  }

  bool keepDraft(String namespace) {
    final scope = section(namespace);
    if (saving || scope.uncertain) return false;
    return scope.rebase(
      useLocal: {
        for (final conflict in conflicts(namespace)) conflict.id: true,
      },
    );
  }

  void useRemote(String namespace) {
    if (!saving) section(namespace).discardDraft();
  }

  @override
  void dispose() {
    _disposed = true;
    credentials.removeListener(_credentialsChanged);
    for (final scope in sections.values) {
      scope.removeListener(_changed);
      scope.dispose();
    }
    _keys.clear();
    _keyWrites.clear();
    _keyWriteConnections.clear();
    _observedKeyWrites.clear();
    _keyReviews.clear();
    super.dispose();
  }
}
