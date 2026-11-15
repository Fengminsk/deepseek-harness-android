import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api_streams.dart';
import 'attachment_surface.dart';
import 'approvals_draft.dart';
import 'composer_commands.dart';
import 'plugins_data.dart';
import 'library_data.dart';
import 'credentials_data.dart';
import 'recovery_data.dart';
import 'account_state.dart';
import 'models_data.dart';
import 'runtime_transport.dart';
import 'terminal_runtime.dart';

typedef Json = Map<String, dynamic>;

/// 本地传输的请求执行器：拼出既有 `{'method', 'params'}` 封装并打 MethodChannel。
///
/// `payload` 已经是 `params` 的 JSON 文本，直接拼进外层对象，避免再解码一遍。
Future<String?> _invokeLocal(String method, String payload) =>
    RuntimeController.channel.invokeMethod<String>(
      'call',
      '{"method":${jsonEncode(method)},"params":$payload}',
    );

/// The native transcript keeps one bounded loaded window and a fixed read cut.
class SessionHistoryWindow {
  SessionHistoryWindow({
    required this.throughSeq,
    required this.firstSeq,
    required this.hasMore,
    required this.generation,
  });
  final int throughSeq;
  int? firstSeq;
  bool hasMore;
  final int generation;
  bool loading = false;
}

/// 本地运行时同时是终端页、附件草稿与会话指令菜单的调用面：`ready`、`phase`、
/// `connectionGeneration`、`ensureSession`、`call`、监听器与 `dispose` 已经满足
/// [TerminalCallSurface]、[AttachmentCallSurface] 与 [ComposerCommandSurface]
/// （见 terminal_runtime.dart、attachment_surface.dart、composer_commands.dart）。
class RuntimeController extends ChangeNotifier
    implements
        TerminalCallSurface,
        AttachmentCallSurface,
        ComposerCommandSurface {
  /// 构造时可换入远程传输；缺省是包装既有双通道的本地传输。
  RuntimeController({RuntimeTransport? transport}) {
    this.transport =
        transport ??
        LocalRuntimeTransport(
          localInvoke: _invokeLocal,
          events: _inbound.stream,
        );
  }

  static const configurationReadTimeout = Duration(seconds: 20);
  static const channel = MethodChannel('dsh/runtime');
  static const events = EventChannel('dsh/events');

  /// 本地 EventChannel 帧的注入口：本地传输从这里取入站通知。
  final StreamController<Json> _inbound = StreamController<Json>();

  /// 本地与远程共用的传输缝：请求走 [RuntimeTransport.request]，分发走
  /// [RuntimeTransport.events]。
  late final RuntimeTransport transport;
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<Json>? _eventSubscription;
  @override
  String phase = 'starting';
  String? nativeGeneration, nativeMode;
  String? error;
  Json info = {};
  Json web = {};
  int _webRead = 0;
  List<Json> sessions = [];
  List<Json> forms = [];
  Future<dynamic>? _configurationRead;
  (int, Object)? _configurationReadKey;

  /// Share only an in-flight authoritative read, never a cached permission or
  /// revision. Reconnects, replaced catalogs and writes fence older flights.
  Future<dynamic> describeConfiguration() {
    final key = (connectionGeneration, forms);
    if (_configurationReadKey == key && _configurationRead != null) {
      return _configurationRead!;
    }
    _configurationReadKey = key;
    late final Future<dynamic> operation;
    operation =
        call('api.call', {
          'namespace': 'settings',
          'method': 'describe',
          'args': <String, dynamic>{},
        }).timeout(configurationReadTimeout).whenComplete(() {
          if (identical(_configurationRead, operation)) {
            _configurationRead = null;
          }
        });
    return _configurationRead = operation;
  }

  void invalidateConfigurationRead() {
    _configurationRead = null;
    _configurationReadKey = null;
  }

  List<Json> interactions = [];
  String? interactionsError;
  int _interactionsRevision = -1;
  Json? navigationRequest;
  final questionDrafts = QuestionDraftStore();
  PluginsController? _plugins;
  PluginsController get plugins => _plugins ??= PluginsController(this);
  LibraryController? _library;
  LibraryController get library => _library ??= LibraryController(this);
  CredentialsController? _credentials;
  CredentialsController get credentials =>
      _credentials ??= CredentialsController(this);
  RecoveryController? _recovery;
  RecoveryController get recovery => _recovery ??= RecoveryController(this);
  AccountState? _account;
  AccountState? get accountSnapshot => _account;
  Future<AccountState>? _accountInitialization;
  String? accountError;
  ModelsDirectoryController? _models;
  ModelsDirectoryController get models =>
      _models ??= ModelsDirectoryController(this);
  Future<void>? _resume;
  Timer? _resumeTimer;
  Completer<void>? _resumeWake;
  int _resumeEpoch = 0;
  bool _bindingDisconnected = false;
  int _statusRevision = 0;
  @override
  int get connectionGeneration => _connectionGeneration;

  /// The core retains credentials. This owner retains only its observed view
  /// while pages mount and unmount; closing a page cannot cancel sign-in.
  Future<AccountState> ensureAccount({String locale = 'zh-CN'}) {
    final existing = _account;
    if (existing != null) return Future.value(existing);
    if (_accountInitialization != null) return _accountInitialization!;
    late final Future<AccountState> operation;
    operation =
        () async {
          final raw = await channel.invokeMethod<String>('app.metadata');
          if (raw == null) {
            throw const FormatException('Missing application version');
          }
          final metadata = jsonDecode(raw) as Json;
          if (_disposed) throw StateError('Runtime is closed');
          final account = AccountState(this, {
            'version': metadata['version'],
            'locale': locale,
            'timezoneOffsetSeconds': DateTime.now().timeZoneOffset.inSeconds,
          });
          _account = account;
          account.addListener(_accountChanged);
          accountError = null;
          notifyListeners();
          await account.watch();
          return account;
        }().whenComplete(() {
          if (identical(_accountInitialization, operation)) {
            _accountInitialization = null;
          }
        });
    return _accountInitialization = operation;
  }

  void _accountChanged() {
    if (!_disposed) notifyListeners();
  }

  void _prepareAccount() {
    unawaited(
      ensureAccount().then<void>(
        (_) {},
        onError: (Object failure) {
          if (!_disposed) {
            accountError = '无法读取账号状态，可在账号页重试。';
            notifyListeners();
          }
        },
      ),
    );
  }

  final _remoteEvents = StreamController<Json>.broadcast(sync: true);
  Stream<Json> get remoteEvents => _remoteEvents.stream;
  final _liveSessionEvents = StreamController<Json>.broadcast(sync: true);

  /// Newly delivered Session events only. History reads never enter this feed.
  Stream<Json> get liveSessionEvents => _liveSessionEvents.stream;
  late final AppApiStreams _apiStreams = AppApiStreams(
    (method, params) => call(method, params),
  );
  final Map<String, List<Json>> timelines = {};
  final Map<String, SessionHistoryWindow> historyWindows = {};
  final Map<String, int> _timelineGenerations = {};
  final Map<String, Object> _historyReads = {};
  final Set<String> _replacedHistory = {};
  final Map<String, ({int generation, List<Json> events})> _unreadLiveEvents =
      {};
  final Map<String, String> streaming = {};
  final Map<String, Json> liveMessages = {};
  final Map<String, String> statuses = {};
  final Map<String, String> sessionErrors = {};
  Json taskState = {};
  List<Json> taskSessions = [];
  List<Json>? taskJobs;
  int? tasksNextOffset;
  String? tasksError;
  Future<void>? _tasksRefresh;
  Future<void>? _sessionsRefresh;
  int _sessionsRefreshGeneration = -1;
  Object? _sessionsRefreshToken;
  bool _sessionsRefreshAgain = false;
  int _tasksRefreshGeneration = -1;
  int _connectionGeneration = 0;
  bool _disposed = false;
  Future<void>? _liveRefresh;
  int _liveRefreshGeneration = -1;
  List<({String method, Json data})>? _liveBuffer;
  String provider = 'deepseek-official';
  String model = 'deepseek-flash';
  String? reasoningEffort;
  final Map<String, ({String signature, String id})> _submissions = {};

  void useModelSelection({
    required String provider,
    required String model,
    String? reasoningEffort,
  }) {
    this.provider = provider;
    this.model = model;
    this.reasoningEffort = reasoningEffort;
    notifyListeners();
  }

  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) =>
      _apiStreams.watch(namespace, method, args: args, resumeArgs: resumeArgs);

  List<Json> get observationDiagnostics => _apiStreams.diagnostics;

  @override
  bool get ready => phase == 'ready';
  void _invalidateWeb() {
    _webRead++;
    if (web.isNotEmpty) {
      web = {
        ...web,
        'phase': 'unknown',
        'host': null,
        'url': null,
        'error': null,
      };
    }
  }

  /// Listener observations belong to this connection. Keep the saved preference
  /// but withdraw addresses as soon as the carrier can no longer confirm them.
  Future<void> refreshWeb() async {
    if (_disposed || !ready) return;
    final generation = _connectionGeneration;
    final read = ++_webRead;
    final observed = web;
    bool current() =>
        !_disposed &&
        ready &&
        generation == _connectionGeneration &&
        read == _webRead &&
        identical(observed, web);
    try {
      final next = await call('web.status') as Json;
      if (!current()) return;
      web = next;
      notifyListeners();
    } catch (_) {
      if (!current()) return;
      _invalidateWeb();
      notifyListeners();
      rethrow;
    }
  }

  /// A newer network notification supersedes an older mutation receipt. An
  /// uncertain write is never replayed; only a subsequent status read reconciles it.
  Future<void> configureWeb(Json preferences, {bool rotate = false}) async {
    if (_disposed || !ready || web.isEmpty || web['phase'] == 'unknown') {
      throw StateError('Web 状态尚未确认，请先刷新。');
    }
    final generation = _connectionGeneration;
    final observed = web;
    ++_webRead;
    bool current() =>
        !_disposed && ready && generation == _connectionGeneration;
    try {
      final next = await call(
        rotate ? 'web.rotate' : 'web.configure',
        preferences,
      ) as Json;
      if (!current() || !identical(observed, web)) return;
      web = next;
      notifyListeners();
    } catch (_) {
      if (!current()) return;
      if (identical(observed, web)) {
        _invalidateWeb();
        notifyListeners();
      }
      rethrow;
    }
  }

  void _markLiveUnconfirmed() {
    for (final id in liveMessages.keys.toList()) {
      liveMessages[id] = {...liveMessages[id]!, 'unconfirmed': true};
    }
  }

  void _advanceConnectionGeneration() {
    _connectionGeneration++;
    _unreadLiveEvents.clear();
  }

  void fail(Object exception) {
    _bindingDisconnected = false;
    _statusRevision++;
    _wakeResume();
    _advanceConnectionGeneration();
    error = '$exception';
    phase = 'failed';
    _invalidateWeb();
    _markLiveUnconfirmed();
    _apiStreams.setReady(false);
    notifyListeners();
  }

  Future<void> start() async {
    // 分发只从 transport.events 走：本地与远程共用同一段逻辑。
    _eventSubscription ??= transport.events.listen(
      (Json frame) {
        final data = (frame['params'] as Json?) ?? {};
        switch (frame['method']) {
          case 'runtime.status':
            _acceptStatus(data);
          case 'session.event':
            final id = data['sessionId'] as String;
            final event = data['event'] as Json;
            final timeline = timelines.putIfAbsent(id, () => []);
            // A confirmed replacement must not bring old display rows back
            // when the repaired history is read. Retain only new notifications.
            if (_replacedHistory.contains(id)) {
              final pending = _unreadLiveEvents[id];
              final events = pending?.generation == _connectionGeneration
                  ? pending!.events
                  : <Json>[];
              if (!events.any((item) => item['seq'] == event['seq'])) {
                events.add(event);
              }
              _unreadLiveEvents[id] = (
                generation: _connectionGeneration,
                events: events,
              );
            }
            if (!timeline.any((item) => item['seq'] == event['seq'])) {
              timeline.add(event);
              _liveSessionEvents.add({'sessionId': id, 'event': event});
            }
            if (event['type'] == 'assistant/message') streaming.remove(id);
          case 'session.stream':
            _receiveLive('session.stream', data);
          case 'session.live':
            _receiveLive('session.live', data);
          case 'session.status':
            _receiveLive('session.status', data);
          case 'session.error':
            _receiveLive('session.error', data);
          case 'runtime.tasks.changed':
            _applyTasks(data);
          case 'settings.changed':
            if (ready) {
              unawaited(
                refreshForms().catchError((Object e) {
                  error = '$e';
                  notifyListeners();
                }),
              );
            }
          case 'sessions.changed':
            if (ready) {
              unawaited(
                refreshSessions().catchError((Object e) {
                  error = '$e';
                  notifyListeners();
                }),
              );
            }
          case 'web.changed':
            if (ready) {
              _webRead++;
              web = data;
            }
          case 'interactions.changed':
            _applyInteractions(data);
          case 'navigation.open':
            navigationRequest = data;
          case 'notifications.error':
            interactionsError = data['message'] as String?;
          case 'api.stream':
            _apiStreams.receive(data);
          case 'api.event':
            _remoteEvents.add(data);
        }
        notifyListeners();
      },
      onError: (Object exception) {
        if (!_disposed) fail(exception);
      },
    );
    if (transport is LocalRuntimeTransport) {
      // 本地 EventChannel 的监听保留：每帧原样泵给本地传输的 events 流。
      _subscription ??= events.receiveBroadcastStream().listen(
        (dynamic raw) {
          final frame = jsonDecode(raw as String) as Json;
          if (!_inbound.isClosed) _inbound.add(frame);
        },
        onError: (Object exception) {
          if (!_inbound.isClosed) _inbound.addError(exception);
        },
      );
      await channel.invokeMethod<void>('start');
      // 账号观察依赖本地应用元数据与服务侧账号监听，只有本地服务有这一段。
      _prepareAccount();
    }
  }

  void _acceptStatus(Json data) {
    _statusRevision++;
    _wakeResume();
    final disconnected = data['connection'] == 'disconnected';
    _bindingDisconnected = disconnected;
    final nextGeneration = data['generation'] as String?;
    final changedProcess =
        nextGeneration != null && nativeGeneration != nextGeneration;
    final nextPhase = data['phase'] as String;
    final newProcess =
        !disconnected && (changedProcess || nextPhase == 'starting');
    if (disconnected || newProcess || (ready && nextPhase != 'ready')) {
      _advanceConnectionGeneration();
      _interactionsRevision = -1;
      _apiStreams.setReady(false);
      _markLiveUnconfirmed();
      _invalidateWeb();
    }
    if (newProcess) {
      // These projections belong to one native process. A transient disconnect
      // may retain them as unconfirmed; a new process must supply a new baseline.
      _replacedHistory.addAll(timelines.keys);
      taskState = {};
      taskJobs = null;
      liveMessages.clear();
      statuses.clear();
      streaming.clear();
    }
    phase = nextPhase;
    if (!disconnected) {
      nativeGeneration = nextGeneration;
      nativeMode = data['mode'] as String?;
    }
    error = data['error'] as String?;
    if (!ready) {
      _markLiveUnconfirmed();
      _invalidateWeb();
    }
    // Invalidate domain observations before a replacement stream can emit its
    // baseline. A synchronous first frame must not be cleared by a later notify.
    notifyListeners();
    _apiStreams.setReady(ready);
    if (ready) {
      final generation = _connectionGeneration;
      unawaited(
        refresh().catchError((Object failure) {
          if (!_disposed && generation == _connectionGeneration && ready) {
            error = '$failure';
            notifyListeners();
          }
        }),
      );
    }
  }

  /// Reconcile the existing service after returning to the foreground. Only
  /// observations are reopened; writes and model submissions are never replayed.
  Future<void> resume() {
    if (_disposed) return Future.value();
    if (_resume != null) return _resume!;
    final epoch = _resumeEpoch;
    final observedGeneration = _connectionGeneration;
    final observedReady = ready;
    bool current() => !_disposed && epoch == _resumeEpoch;
    late final Future<void> operation;
    operation =
        () async {
          for (var attempt = 0; current(); attempt++) {
            var statusRevision = _statusRevision;
            try {
              // A foreground Activity can outlive its killed service process.
              // Native code restores the saved service mode and binds once;
              // this receipt alone never makes Agent observations ready.
              await channel.invokeMethod<void>('runtime.ensureBound');
              if (!current()) return;
              statusRevision = _statusRevision;
              final state = await call('runtime.status') as Json;
              if (!current()) return;
              // Pushed transitions supersede both late results and late errors.
              if (statusRevision == _statusRevision) _acceptStatus(state);
              statusRevision = _statusRevision;
              if (!ready) {
                if (!_bindingDisconnected &&
                    phase != 'starting' &&
                    phase != 'restarting') {
                  return;
                }
                if (attempt >= 6) return; // Real startup remains event-driven.
              } else {
                final generation = _connectionGeneration;
                bool connected() =>
                    current() && ready && generation == _connectionGeneration;
                // A ready transition already opens fresh observations. Only
                // an unchanged connection needs foreground reattachment.
                if (observedReady && generation == observedGeneration) {
                  await _apiStreams.reconnect();
                }
                if (!connected()) return;
                statusRevision = _statusRevision;
                await Future.wait([
                  () async {
                    final account = await ensureAccount();
                    if (!connected()) return;
                    await account.ensureWatching();
                    if (connected() && account.connected) {
                      await account.refreshDetails();
                    }
                  }(),
                  if (_models != null) _models!.refresh(),
                ]);
                return;
              }
            } catch (failure) {
              if (!current() ||
                  (statusRevision != _statusRevision &&
                      !_bindingDisconnected)) {
                return;
              }
              if (failure is PlatformException &&
                  (failure.code == 'not-foreground' ||
                      failure.code == 'busy')) {
                return; // Backgrounding or an explicit transition owns recovery.
              }
              final connecting =
                  _bindingDisconnected ||
                  (failure is PlatformException &&
                      (failure.code == 'starting' ||
                          failure.code == 'disconnected'));
              if (!connecting || attempt >= 6) {
                error = connecting
                    ? '尚未连接本地服务，请返回前台重试或查看诊断。'
                    : '返回前台后的状态同步未完成：$failure';
                notifyListeners();
                return;
              }
              // Binder absence is not proof of a new Node process. Preserve
              // existing projections as unconfirmed until native status arrives.
              _statusRevision++;
              _advanceConnectionGeneration();
              _bindingDisconnected = true;
              phase = 'starting';
              error = null;
              _markLiveUnconfirmed();
              _apiStreams.setReady(false);
              notifyListeners();
            }
            final revision = _statusRevision;
            await _waitForResume(Duration(milliseconds: 250 * (1 << attempt)));
            if (!current()) return;
            if (revision != _statusRevision &&
                !_bindingDisconnected &&
                !ready &&
                phase != 'starting' &&
                phase != 'restarting') {
              return;
            }
          }
        }().whenComplete(() {
          if (identical(_resume, operation)) _resume = null;
        });
    return _resume = operation;
  }

  Future<void> _waitForResume(Duration delay) {
    final wake = Completer<void>();
    _resumeWake = wake;
    _resumeTimer = Timer(delay, _wakeResume);
    return wake.future;
  }

  void _wakeResume() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    final wake = _resumeWake;
    _resumeWake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _cancelResume() {
    _resumeEpoch++;
    _resume = null;
    _wakeResume();
  }

  Future<void> restart() async {
    _cancelResume();
    _bindingDisconnected = false;
    _statusRevision++;
    phase = 'restarting';
    _invalidateWeb();
    error = null;
    _interactionsRevision = -1;
    _replacedHistory.addAll(timelines.keys);
    _advanceConnectionGeneration();
    taskState = {};
    taskJobs = null;
    _markLiveUnconfirmed();
    statuses.clear();
    streaming.clear();
    _apiStreams.setReady(false);
    notifyListeners();
    try {
      await channel.invokeMethod<void>('restart');
    } catch (exception) {
      fail(exception);
      rethrow;
    }
  }

  /// 一次请求。`_pocket_error` 的解码已收敛到传输层，这里不再解第二遍。
  ///
  /// 传输层的 [RuntimeTransportFailure] 仍按既有页面约定转回
  /// [PlatformException]：`code` / `message` / `details` 与改造前逐字段一致，
  /// 各页面里 `failure is PlatformException` 的分支不需要改。
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    try {
      return await transport.request(method, params);
    } on RuntimeTransportFailure catch (failure) {
      throw PlatformException(
        code: failure.code,
        message: failure.message,
        details: failure.details,
      );
    }
  }

  Future<void>? _formsRefresh;
  int? _formsRefreshConnection;
  bool _formsRefreshAgain = false;

  Future<void> refreshForms() {
    final generation = connectionGeneration;
    if (_formsRefresh != null && _formsRefreshConnection == generation) {
      _formsRefreshAgain = true;
      return _formsRefresh!;
    }
    _formsRefreshConnection = generation;
    bool current() => !_disposed && generation == connectionGeneration;
    late final Future<void> operation;
    operation =
        () async {
          do {
            _formsRefreshAgain = false;
            final next = (await call(
              'settings.describe',
            ).timeout(configurationReadTimeout) as List).cast<Json>();
            if (!current()) return;
            // A newer invalidation arrived during this read. Read once more before
            // publishing, rather than exposing an intermediate stale catalog.
            if (_formsRefreshAgain) continue;
            forms = next;
            for (final form in forms) {
              if (form['ns'] == 'agent-default-model' &&
                  form['value'] is Json) {
                final selected = form['value'] as Json;
                if (selected['provider'] is String &&
                    selected['model'] is String) {
                  provider = selected['provider'] as String;
                  model = selected['model'] as String;
                  reasoningEffort = selected['reasoningEffort'] as String?;
                }
              }
            }
            notifyListeners();
          } while (_formsRefreshAgain && current());
        }().whenComplete(() async {
          if (!identical(_formsRefresh, operation)) return;
          _formsRefresh = null;
          // An invalidation can land between the loop exit and this completion.
          if (_formsRefreshAgain && current()) await refreshForms();
        });
    return _formsRefresh = operation;
  }

  Future<void> refresh() async {
    final generation = _connectionGeneration;
    bool current() => !_disposed && generation == _connectionGeneration;
    final nextInfo = await call('runtime.info') as Json;
    if (!current()) return;
    info = nextInfo;
    Object? firstFailure;
    StackTrace? firstStack;
    Future<void> read(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (failure, stack) {
        firstFailure ??= failure;
        firstStack ??= stack;
      }
    }

    await read(refreshLive);
    if (!current()) return;
    // A new process has no live attempts to publish for the old turn. Refresh
    // retained transcripts through the core's read-only interruption recovery.
    // The event bus also carries child Sessions, whose reads need a parent
    // address. Only refresh the ordinary chats explicitly opened or created.
    for (final id in _timelineGenerations.keys.toList()) {
      final observed = _timelineGenerations[id];
      if (observed == generation ||
          (timelines[id]?.isEmpty == true && observed != -1)) {
        continue;
      }
      await read(() => openSession(id));
      if (!current()) return;
    }
    await read(refreshInteractions);
    if (!current()) return;
    await read(refreshWeb);
    if (!current()) return;
    await read(refreshSessions);
    if (!current()) return;
    await read(refreshForms);
    if (!current()) return;
    await read(refreshTasks);
    if (!current()) return;
    if (firstFailure != null) {
      Error.throwWithStackTrace(firstFailure!, firstStack!);
    }
  }

  bool _applyTasks(Json snapshot) {
    if (snapshot['epoch'] == taskState['epoch'] &&
        (snapshot['revision'] as int) < (taskState['revision'] as int? ?? -1)) {
      return false;
    }
    taskState = {
      'epoch': snapshot['epoch'],
      'revision': snapshot['revision'],
      'summary': snapshot['summary'],
      'active': snapshot['active'],
    };
    return true;
  }

  Future<void> refreshTasks() {
    if (_tasksRefresh != null &&
        _tasksRefreshGeneration == _connectionGeneration) {
      return _tasksRefresh!;
    }
    _tasksRefreshGeneration = _connectionGeneration;
    late final Future<void> operation;
    operation = _readTasks().whenComplete(() {
      if (identical(_tasksRefresh, operation)) _tasksRefresh = null;
    });
    return _tasksRefresh = operation;
  }

  Future<void> _readTasks() async {
    final generation = _connectionGeneration;
    try {
      final snapshot = await call('tasks.list') as Json;
      if (generation != _connectionGeneration) return;
      if (!_applyTasks(snapshot)) return;
      taskSessions = (snapshot['sessions'] as List).cast<Json>();
      taskJobs = (snapshot['jobs'] as List?)?.cast<Json>();
      tasksNextOffset = snapshot['nextOffset'] as int?;
      tasksError = null;
    } catch (failure) {
      if (generation == _connectionGeneration) tasksError = '$failure';
      rethrow;
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> loadMoreTasks() async {
    final offset = tasksNextOffset;
    if (offset == null) return;
    final generation = _connectionGeneration;
    final snapshot = await call('tasks.list', {'offset': offset}) as Json;
    if (generation != _connectionGeneration) return;
    if (!_applyTasks(snapshot)) return;
    taskJobs = (snapshot['jobs'] as List?)?.cast<Json>();
    final byId = {for (final row in taskSessions) row['sessionId']: row};
    for (final row in (snapshot['sessions'] as List).cast<Json>()) {
      byId[row['sessionId']] = row;
    }
    taskSessions = byId.values.toList();
    tasksNextOffset = snapshot['nextOffset'] as int?;
    notifyListeners();
  }

  void _applyInteractions(Json snapshot) {
    final revision = snapshot['revision'] as int;
    if (revision < _interactionsRevision) return;
    _interactionsRevision = revision;
    interactions = (snapshot['requests'] as List).cast<Json>();
    interactionsError = snapshot['error'] as String?;
  }

  Future<void> refreshInteractions() async {
    final generation = _connectionGeneration;
    bool current() => !_disposed && generation == _connectionGeneration;
    try {
      final snapshot = await call('interactions.list') as Json;
      if (current()) _applyInteractions(snapshot);
    } catch (exception) {
      if (current()) interactionsError = '$exception';
      rethrow;
    } finally {
      if (current()) notifyListeners();
    }
  }

  void consumeNavigation() {
    navigationRequest = null;
  }

  void _receiveLive(String method, Json data) {
    _liveBuffer?.add((method: method, data: data));
    _applyLive(method, data);
  }

  void _applyLive(String method, Json data) {
    final id = data['sessionId'] as String;
    if (method == 'session.live') {
      final value = data['value'] as Json?;
      if (value == null) {
        liveMessages.remove(id);
      } else {
        liveMessages[id] = value;
      }
      return;
    }
    if (method == 'session.status') {
      if (data['attached'] == false) {
        statuses.remove(id);
        streaming.remove(id);
        return;
      }
      statuses[id] = data['status'] as String;
      if (data['status'] == 'idle') streaming.remove(id);
      if (data['status'] == 'running') sessionErrors.remove(id);
      return;
    }
    if (method == 'session.error') {
      sessionErrors[id] = data['error'] as String;
      return;
    }
    final frame = data['frame'] as Json;
    if (frame['type'] == 'start') streaming[id] = '';
    if (frame['type'] == 'end') streaming.remove(id);
    if (frame['type'] == 'chunk') {
      final chunk = frame['chunk'] as Json;
      if (chunk['type'] == 'text-delta') {
        streaming[id] = '${streaming[id] ?? ''}${chunk['text']}';
      }
    }
  }

  Future<void> refreshLive() {
    if (_liveRefresh != null &&
        _liveRefreshGeneration == _connectionGeneration) {
      return _liveRefresh!;
    }
    _liveRefreshGeneration = _connectionGeneration;
    late final Future<void> operation;
    operation = _readLive().whenComplete(() {
      if (identical(_liveRefresh, operation)) _liveRefresh = null;
    });
    return _liveRefresh = operation;
  }

  Future<void> _readLive() async {
    final generation = _connectionGeneration;
    final buffer = <({String method, Json data})>[];
    _liveBuffer = buffer;
    try {
      final baseline = await call('runtime.live') as Json;
      if (generation != _connectionGeneration) return;
      statuses
        ..clear()
        ..addAll((baseline['statuses'] as Json).cast<String, String>());
      streaming
        ..clear()
        ..addAll((baseline['streaming'] as Json).cast<String, String>());
      sessionErrors
        ..clear()
        ..addAll(
          ((baseline['errors'] as Json?) ?? const {}).cast<String, String>(),
        );
      liveMessages
        ..clear()
        ..addAll(
          ((baseline['liveMessages'] as Json?) ?? const {})
              .cast<String, Json>(),
        );
      for (final update in buffer) {
        if ((update.data['revision'] as int) > (baseline['revision'] as int)) {
          _applyLive(update.method, update.data);
        }
      }
      notifyListeners();
    } finally {
      if (identical(_liveBuffer, buffer)) _liveBuffer = null;
    }
  }

  Future<void> refreshSessions() {
    final generation = _connectionGeneration;
    if (_sessionsRefresh != null && _sessionsRefreshGeneration == generation) {
      _sessionsRefreshAgain = true;
      return _sessionsRefresh!;
    }
    final token = Object();
    _sessionsRefreshGeneration = generation;
    _sessionsRefreshToken = token;
    _sessionsRefreshAgain = false;
    late final Future<void> operation;
    operation = _readSessions(generation, token).whenComplete(() {
      if (identical(_sessionsRefreshToken, token)) {
        _sessionsRefresh = null;
        _sessionsRefreshToken = null;
      }
    });
    return _sessionsRefresh = operation;
  }

  Future<void> _readSessions(int generation, Object token) async {
    bool current() =>
        !_disposed &&
        generation == _connectionGeneration &&
        identical(_sessionsRefreshToken, token);
    do {
      if (!current()) return;
      _sessionsRefreshAgain = false;
      List<Json> next;
      try {
        next = (await call('sessions.list') as List).cast<Json>();
      } catch (_) {
        if (!current()) return;
        // A queued invalidation still owns a fresh read after this one fails.
        if (_sessionsRefreshAgain && ready && !_disposed) continue;
        rethrow;
      }
      if (!current()) return;
      sessions = next;
      notifyListeners();
    } while (_sessionsRefreshAgain && current());
  }

  String newSession() {
    final random = Random.secure();
    final id =
        'android-${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 30)}';
    timelines[id] = [];
    historyWindows.remove(id);
    _timelineGenerations[id] = _connectionGeneration;
    return id;
  }

  Future<void> openSession(String id) async {
    _timelineGenerations.putIfAbsent(id, () => -1);
    final generation = _connectionGeneration;
    final read = Object();
    _historyReads[id] = read;
    bool current() =>
        !_disposed &&
        generation == _connectionGeneration &&
        identical(_historyReads[id], read);
    late final Json window;
    try {
      window = await call('session.readWindow', {'sessionId': id}) as Json;
      if (!current()) return;
      final accumulated = (window['events'] as List).cast<Json>().toList();
      final firstSeq = window['firstSeq'] as int?;
      final throughSeq = window['throughSeq'] as int;
      if (accumulated.isNotEmpty && firstSeq != accumulated.first['seq']) {
        throw StateError('Session window has an invalid first sequence');
      }
      // A transient disconnect may resume the same process and keep its
      // displayed rows. A confirmed replacement instead trusts only the
      // repaired history and notifications from the replacement process.
      final seen = {for (final event in accumulated) event['seq'] as int};
      final pending = _unreadLiveEvents[id];
      final currentEvents = _replacedHistory.contains(id)
          ? pending?.generation == generation
                ? pending!.events
                : <Json>[]
          : timelines[id] ?? <Json>[];
      for (final event in currentEvents) {
        final seq = event['seq'] as int;
        if (seq >= (firstSeq ?? 0) && seen.add(seq)) {
          accumulated.add(event);
        }
      }
      accumulated.sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
      timelines[id] = accumulated;
      historyWindows[id] = SessionHistoryWindow(
        throughSeq: throughSeq,
        firstSeq: firstSeq,
        hasMore: window['hasMore'] == true,
        generation: generation,
      );
      _timelineGenerations[id] = generation;
      _replacedHistory.remove(id);
      _unreadLiveEvents.remove(id);
      notifyListeners();
    } catch (_) {
      if (current()) rethrow;
    } finally {
      if (identical(_historyReads[id], read)) _historyReads.remove(id);
    }
  }

  /// Prepend one original Turn-aware page. The caller owns the visual anchor;
  /// no listener notification should make the chat shell follow the tail.
  Future<int> loadOlderSession(String id) async {
    final window = historyWindows[id];
    final timeline = timelines[id];
    if (window == null ||
        timeline == null ||
        !window.hasMore ||
        window.firstSeq == null ||
        window.loading ||
        window.generation != _connectionGeneration) {
      return 0;
    }
    window.loading = true;
    try {
      final page = await call('session.readWindow', {
        'sessionId': id,
        'throughSeq': window.throughSeq,
        'beforeSeq': window.firstSeq,
      }) as Json;
      if (_disposed ||
          window.generation != _connectionGeneration ||
          !identical(historyWindows[id], window) ||
          !identical(timelines[id], timeline)) {
        return 0;
      }
      final records = (page['events'] as List).cast<Json>();
      final nextFirst = page['firstSeq'] as int?;
      if (records.isEmpty ||
          nextFirst == null ||
          nextFirst >= window.firstSeq! ||
          records.first['seq'] != nextFirst) {
        throw StateError('Older Session page did not advance');
      }
      final newEvents = records
          .where((event) => (event['seq'] as int) < window.firstSeq!)
          .toList();
      if (newEvents.isEmpty) {
        throw StateError('Older Session page overlaps the loaded window');
      }
      timeline.insertAll(0, newEvents);
      window.firstSeq = nextFirst;
      window.hasMore = page['hasMore'] == true;
      return newEvents.length;
    } finally {
      window.loading = false;
    }
  }

  /// Audit surfaces explicitly requesting the complete ledger retain the
  /// original stable-snapshot reader. Chat itself uses bounded windows.
  Future<List<Json>> readCompleteSession(String id) async {
    final generation = _connectionGeneration;
    final accumulated = <Json>[];
    var offset = 0;
    String? snapshot;
    try {
      while (true) {
        final request = <String, dynamic>{'sessionId': id, 'offset': offset};
        if (snapshot != null) request['snapshot'] = snapshot;
        final page = await call('session.read', request) as Json;
        if (_disposed || generation != _connectionGeneration) {
          throw StateError('Session history reader changed during the audit');
        }
        snapshot = page['snapshot'] as String?;
        final records = (page['events'] as List).cast<Json>();
        accumulated.addAll(records);
        if (records.length < 200) return accumulated;
        offset = (records.last['seq'] as int) + 1;
      }
    } finally {
      if (snapshot != null) {
        try {
          await call('session.read.release', {
            'sessionId': id,
            'snapshot': snapshot,
          });
        } catch (_) {
          // A disconnected runtime also releases temporary snapshots.
        }
      }
    }
  }

  @override
  Future<Json> ensureSession(String id) async {
    return await call('session.ensure', {'sessionId': id}) as Json;
  }

  Future<void> send(String id, String text) =>
      sendAttachments(id, text, const []);

  Future<void> sendAttachments(
    String id,
    String text,
    List<String> attachmentIds,
  ) async {
    final requestedProvider = provider;
    final requestedModel = model;
    final requestedEffort = reasoningEffort;
    final selectedAttachments = List<String>.of(attachmentIds);
    final signature = jsonEncode([text, selectedAttachments]);
    final previous = _submissions[id];
    final request = previous?.signature == signature
        ? previous!
        : (
            signature: signature,
            id: 'app-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}',
          );
    _submissions[id] = request;
    await call('session.send', {
      'sessionId': id,
      'requestId': request.id,
      'text': text,
      if (selectedAttachments.isNotEmpty) 'attachmentIds': selectedAttachments,
      'provider': requestedProvider,
      'model': requestedModel,
      'reasoningEffort': ?requestedEffort,
      'selectModel': false,
    });
    _submissions.remove(id);
    // Admission has succeeded; a list refresh failure must not invite resubmission.
    unawaited(
      refreshSessions().catchError((Object e) {
        error = '$e';
        notifyListeners();
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelResume();
    _advanceConnectionGeneration();
    _plugins?.dispose();
    _library?.dispose();
    _credentials?.dispose();
    _recovery?.dispose();
    _account?.removeListener(_accountChanged);
    _account?.dispose();
    _models?.dispose();
    unawaited(_subscription?.cancel());
    unawaited(_eventSubscription?.cancel());
    unawaited(_apiStreams.close());
    unawaited(_remoteEvents.close());
    unawaited(_liveSessionEvents.close());
    // 事件流先收口，再关传输：仍在途的 api.unsubscribe 不受影响。
    unawaited(_inbound.close());
    unawaited(transport.close());
    super.dispose();
  }
}
