import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'configuration_edits.dart' show configurationEqual;
import 'runtime.dart';

Future<dynamic> pluginsApi(
  RuntimeController runtime,
  String method, [
  Json args = const {},
]) => runtime.call('api.call', {
  'namespace': 'pluginManager',
  'method': method,
  'args': args,
});

String pluginText(dynamic value, String fallback, [String language = 'zh']) =>
    value is String
    ? value
    : value is Map
    ? '${value[language] ?? value['en'] ?? fallback}'
    : fallback;

String pluginName(Json item) => pluginText(
  item['meta']?['title'],
  '${item['name'] ?? item['moduleName'] ?? item['entryId']}',
);

String pluginChangeSummary(Json result) => switch (result['application']) {
  'applied' => result['changed'] == true ? '变更已应用。' : '当前配置无需更改。',
  'restart-required' =>
    '配置已保存，重启 DSH 服务后生效。原因：${result['restartReason'] ?? '运行时要求重启'}',
  'overridden' => '配置已保存，但被优先级更高的配置覆盖。',
  'cancelled' => '安装已取消，核心已确认还原相关文件。',
  'failed' =>
    '操作失败：${result['error']?['diagnostic'] ?? result['error']?['code'] ?? result['packageResult']?['kind'] ?? '请查看诊断'}',
  _ => '未能识别核心返回的结果，请刷新核对。',
};

String _installationId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Target-local feedback. A toggle never changes the observed inventory optimistically.
class PluginActionState extends ChangeNotifier {
  bool running = false, verifying = false, awaitingRefresh = false;
  bool unknown = false;
  String? message;
  Json? result;
  void publish() => notifyListeners();
}

/// App presentation cache only: all plugin changes/install lifetimes belong to
/// the original pluginManager. Closing a page never cancels its operation.
class PluginsController extends ChangeNotifier {
  PluginsController(this.runtime)
    : _connection = runtime.connectionGeneration,
      _ready = runtime.ready {
    runtime.addListener(_runtimeChanged);
  }
  final RuntimeController runtime;
  StreamSubscription<Json>? _events;
  int _views = 0;
  bool _disposed = false;
  void publish() {
    if (!_disposed) notifyListeners();
  }

  Json? inventory;
  List<Json> bundles = [], entries = [];
  bool loading = false;
  String? error, actionMessage;
  final actions = <String>{};
  int generation = 0;
  final _changes = <String, PluginActionState>{};
  Future<void>? _load;
  bool _reload = false, _fresh = false;
  int _connection, _writes = 0;
  bool _ready;
  bool get fresh =>
      _fresh && runtime.ready && _connection == runtime.connectionGeneration;
  PluginActionState actionFor(String key) =>
      _changes.putIfAbsent(key, PluginActionState.new);
  bool canChange(String key) =>
      !_disposed &&
      managementAvailable &&
      fresh &&
      !actions.contains(key) &&
      !actionFor(key).awaitingRefresh;

  void _runtimeChanged() {
    if (_disposed ||
        (_connection == runtime.connectionGeneration &&
            _ready == runtime.ready)) {
      return;
    }
    _connection = runtime.connectionGeneration;
    _ready = runtime.ready;
    generation++;
    _fresh = false;
    _reload = runtime.ready;
    publish();
    if (runtime.ready && (_views > 0 || actions.isNotEmpty)) unawaited(load());
  }

  String spec = '', registry = '';
  bool enableAfterInstall = false;
  bool saveExact = false;
  Json? inspection, installResult;
  String? inspectedSpec, inspectedRegistry, requestId, installError;
  String installPhase = 'idle';
  bool checking = false, cancelling = false, recovering = false;
  final List<Json> logs = [];
  bool logTruncated = false;
  bool get managementAvailable => inventory?['managementAvailable'] == true;
  bool get pending => const [
    'installing',
    'applying',
    'cancelling',
    'unconfirmed',
  ].contains(installPhase);
  bool get canInstall =>
      !checking &&
      !pending &&
      inspection?['status'] == 'accepted' &&
      inspectedSpec == spec.trim() &&
      inspectedRegistry == registry.trim();

  void attach() {
    if (_disposed) return;
    _views++;
    _events ??= runtime.remoteEvents.listen(
      receive,
      onError: (Object failure) {
        generation++;
        _fresh = false;
        _reload = false;
        error = '插件变更通知中断：$failure\n请刷新核对实际状态。';
        publish();
      },
      onDone: () {
        _events = null;
        generation++;
        _fresh = false;
        _reload = false;
        error = '插件变更通知已结束，请刷新核对实际状态。';
        publish();
      },
    );
  }

  void detach() {
    if (_views > 0) _views--;
    releaseIdleObserver();
  }

  void releaseIdleObserver() {
    if (_views == 0 && !pending) {
      unawaited(_events?.cancel());
      _events = null;
    }
  }

  void receive(Json event) {
    final name = event['event'];
    if (name == 'plugin-manager/changed' || name == 'plugin-market/changed') {
      // The core emits changed before completing an App mutation. Its completion
      // requests the authoritative refresh once; avoid racing two full inventories.
      if (_writes == 0) unawaited(load(invalidate: true));
      return;
    }
    final args = event['args'] as List? ?? [];
    if (args.isEmpty || args.first is! Map) return;
    final value = Map<String, dynamic>.from(args.first as Map);
    if (requestId == null || value['requestId'] != requestId) return;
    if (name == 'plugin-manager/install-state') {
      final phase = value['phase'];
      if (const ['installing', 'cancelling', 'applying'].contains(phase)) {
        installPhase = phase as String;
        publish();
      }
    } else if (name == 'plugin-manager/install-log' &&
        value['text'] is String) {
      logs.add(value);
      var length = logs.fold<int>(
        0,
        (count, chunk) => count + (chunk['text'] as String).length,
      );
      while (length > 60000 && logs.length > 1) {
        length -= (logs.removeAt(0)['text'] as String).length;
        logTruncated = true;
      }
      if (length > 60000) {
        logs[0] = {
          ...logs[0],
          'text': (logs[0]['text'] as String).substring(length - 60000),
        };
        logTruncated = true;
      }
      publish();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    generation++;
    runtime.removeListener(_runtimeChanged);
    unawaited(_events?.cancel());
    for (final action in _changes.values) {
      action.dispose();
    }
    super.dispose();
  }

  Future<void> load({bool invalidate = false}) {
    if (_disposed) return Future.value();
    if (invalidate) {
      generation++;
      _reload = true;
      _fresh = false;
    }
    if (_load != null) return _load!;
    if (!runtime.ready) {
      _fresh = false;
      publish();
      return Future.value();
    }
    // Publish only after installing the flight, so a listener cannot start a
    // second request synchronously. Release it before the final notification;
    // invalidations caused by that notification then get their own flight.
    final completion = Completer<void>();
    _load = completion.future;
    unawaited(_runLoad(completion));
    return completion.future;
  }

  Future<void> _runLoad(Completer<void> completion) async {
    try {
      await _readLoop();
    } finally {
      _load = null;
      loading = false;
      publish();
      completion.complete();
    }
  }

  List<Json> _retainRows(List<Json> before, List<Json> after, String key) {
    final old = {for (final row in before) row[key]: row};
    final next = [
      for (final row in after)
        configurationEqual(old[row[key]], row) ? old[row[key]]! : row,
    ];
    return listEquals(before, next) ? before : next;
  }

  Future<void> _readLoop() async {
    loading = true;
    publish();
    do {
      _reload = false;
      final current = ++generation;
      final connection = runtime.connectionGeneration;
      bool valid() =>
          !_disposed &&
          current == generation &&
          runtime.ready &&
          connection == runtime.connectionGeneration;
      try {
        final snapshot = await runtime.call('api.call', {
          'namespace': 'pluginInventory',
          'method': 'list',
          'args': {},
        }) as Json;
        if (!valid()) continue;
        List<Json> nextBundles = [],
            nextEntries = (snapshot['entries'] as List).cast<Json>();
        if (snapshot['managementAvailable'] == true) {
          final result = await Future.wait([
            pluginsApi(runtime, 'listBundles'),
            pluginsApi(runtime, 'listPlugins'),
          ]);
          nextBundles = (result[0] as List).cast<Json>();
          nextEntries = (result[1] as List).cast<Json>();
        }
        if (!valid()) continue;
        inventory = configurationEqual(inventory, snapshot)
            ? inventory
            : snapshot;
        bundles = _retainRows(bundles, nextBundles, 'name');
        entries = _retainRows(entries, nextEntries, 'entryId');
        _connection = connection;
        _fresh = true;
        error = null;
        for (final action in List<PluginActionState>.of(_changes.values)) {
          if (action.awaitingRefresh && (!action.running || action.verifying)) {
            action.awaitingRefresh = false;
            action.publish();
          }
        }
      } catch (failure) {
        if (valid()) {
          _fresh = false;
          error = '无法刷新插件状态：$failure';
        }
      }
    } while (_reload && !_disposed && runtime.ready);
  }

  Future<void> change(String key, String method, Json args) async {
    if (!canChange(key) || !actions.add(key)) return;
    final action = actionFor(key);
    final connection = runtime.connectionGeneration;
    action.running = true;
    action.verifying = false;
    action.awaitingRefresh = true;
    action.unknown = false;
    action.message = null;
    action.result = null;
    actionMessage = null;
    _writes++;
    action.publish();
    try {
      // Original pluginManager owns the package-file lock and reads current core
      // state within it. These APIs do not accept a client expectedRevision.
      final result = await pluginsApi(runtime, method, args) as Json;
      if (_disposed) return;
      if (connection != runtime.connectionGeneration || !runtime.ready) {
        action.unknown = true;
        action.message = '服务连接已变化，操作结果未确认。请核对当前状态，未自动重试。';
      } else {
        action.result = result;
        action.message = pluginChangeSummary(result);
        action.unknown = !const [
          'applied',
          'restart-required',
          'overridden',
          'cancelled',
          'failed',
        ].contains(result['application']);
      }
    } catch (failure) {
      if (_disposed) return;
      action.unknown = true;
      action.message = '操作结果未确认：$failure\n正在重新核对实际状态，未自动重试。';
    } finally {
      _writes--;
      if (!_disposed) {
        actionMessage = action.message;
        action.verifying = true;
        action.publish();
        await load(invalidate: true);
        if (!_disposed) {
          actions.remove(key);
          action.running = false;
          action.verifying = false;
          action.publish();
        }
      }
    }
  }

  void editSpec(String text, {bool exact = false}) {
    if (pending || checking) return;
    spec = text;
    saveExact = exact;
    inspection = null;
    installResult = null;
    installError = null;
    installPhase = 'idle';
    publish();
  }

  void editRegistry(String text) {
    if (pending || checking) return;
    registry = text;
    inspection = null;
    installResult = null;
    publish();
  }

  Json options() {
    final value = registry.trim();
    if (value.isEmpty) return {};
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('Registry 必须是 HTTP 或 HTTPS 地址。');
    }
    return {'registry': value};
  }

  Future<void> inspect() async {
    if (checking || pending || !managementAvailable) return;
    checking = true;
    installError = null;
    inspection = null;
    installResult = null;
    publish();
    try {
      final normalized = spec.trim();
      if (normalized.isEmpty) {
        throw const FormatException('请输入包名、Git 地址或设备本地路径。');
      }
      final result = await pluginsApi(runtime, 'inspect', {
        'spec': normalized,
        'options': options(),
      }) as Json;
      inspection = result;
      inspectedSpec = normalized;
      inspectedRegistry = registry.trim();
      if (result['status'] == 'refused') installError = '${result['reason']}';
    } catch (failure) {
      installError = '无法核对安装来源：$failure\n输入已保留。';
    } finally {
      checking = false;
      publish();
    }
  }

  Future<void> install({List<String>? approvedBuilds}) async {
    if (!managementAvailable || !canInstall) return;
    if (approvedBuilds != null) {
      final pendingBuilds = (installResult?['pendingBuilds'] as List? ?? [])
          .cast<String>();
      if (installPhase != 'failed' ||
          approvedBuilds.isEmpty ||
          approvedBuilds.any((name) => !pendingBuilds.contains(name))) {
        return;
      }
    }
    final id = _installationId();
    requestId = id;
    installPhase = 'installing';
    installError = null;
    installResult = null;
    logs.clear();
    logTruncated = false;
    publish();
    try {
      final result = await pluginsApi(runtime, 'installBundle', {
        'spec': inspectedSpec,
        'options': {
          ...options(),
          'enabled': enableAfterInstall,
          'requestId': id,
          if (saveExact) 'saveExact': true,
          'approvedBuilds': ?approvedBuilds,
        },
      }) as Json;
      if (requestId == id) settle(result);
    } catch (failure) {
      if (requestId == id) {
        installPhase = 'unconfirmed';
        installError = '安装结果未确认：$failure\n请核对原请求，不能据此认定安装停止。';
        publish();
      }
    }
  }

  void settle(Json result) {
    installResult = result;
    installPhase = switch (result['application']) {
      'failed' => 'failed',
      'cancelled' => 'cancelled',
      'applied' || 'restart-required' || 'overridden' => 'done',
      _ => 'unknown',
    };
    if (installPhase != 'failed') inspection = null;
    installError = null;
    requestId = null;
    publish();
    unawaited(load());
    if (_views == 0) {
      unawaited(_events?.cancel());
      _events = null;
    }
  }

  Future<void> recover() async {
    final id = requestId;
    if (id == null || recovering) return;
    recovering = true;
    publish();
    try {
      final result = await pluginsApi(runtime, 'waitForInstall', {
        'requestId': id,
      });
      if (requestId != id) return;
      if (result == null) {
        installPhase = 'unknown';
        installError = '核心没有保留此请求的结果。这不能证明安装成功或已取消，请核对插件目录。';
        inspection = null;
        requestId = null;
        unawaited(load());
      } else {
        settle(result as Json);
      }
    } catch (failure) {
      if (requestId == id) installError = '仍无法核对安装结果：$failure';
    } finally {
      recovering = false;
      publish();
      releaseIdleObserver();
    }
  }

  Future<void> cancel() async {
    final id = requestId;
    if (id == null || cancelling) return;
    cancelling = true;
    publish();
    try {
      final result =
          await pluginsApi(runtime, 'cancelInstall', {'requestId': id}) as Json;
      if (requestId != id) return;
      switch (result['status']) {
        case 'cancelled':
          installPhase = 'cancelled';
          installError = '核心已确认取消安装并还原相关文件。';
          requestId = null;
          inspection = null;
          unawaited(load());
        case 'too-late':
          installPhase = 'applying';
          installError = '核心正在应用插件，当前阶段无法取消。';
        case 'not-running':
          installPhase = 'unconfirmed';
          installError = '核心未找到进行中的请求，安装结果仍需核对。';
      }
    } catch (failure) {
      if (requestId == id) installError = '取消未得到确认：$failure';
    } finally {
      cancelling = false;
      publish();
      releaseIdleObserver();
    }
  }
}
