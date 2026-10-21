import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api_streams.dart';
import 'approvals_draft.dart';
import 'plugins_data.dart';
import 'library_data.dart';
import 'credentials_data.dart';
import 'recovery_data.dart';
import 'account_state.dart';
import 'models_data.dart';

typedef Json = Map<String, dynamic>;

class RuntimeController extends ChangeNotifier {
  static const channel = MethodChannel('dsh/runtime');
  static const events = EventChannel('dsh/events');
  StreamSubscription<dynamic>? _subscription;
  String phase = 'starting';
  String? nativeGeneration, nativeMode;
  String? error;
  Json info = {};
  Json web = {};
  List<Json> sessions = [];
  List<Json> forms = [];
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
  int _statusRevision = 0;
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
  late final AppApiStreams _apiStreams = AppApiStreams(
    (method, params) => call(method, params),
  );
  final Map<String, List<Json>> timelines = {};
  final Map<String, String> streaming = {};
  final Map<String, Json> liveMessages = {};
  final Map<String, String> statuses = {};
  final Map<String, String> sessionErrors = {};
  Json taskState = {};
  List<Json> taskSessions = [];
  int? tasksNextOffset;
  String? tasksError;
  Future<void>? _tasksRefresh;
  Future<void>? _sessionsRefresh;
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

  bool get ready => phase == 'ready';
  void _markLiveUnconfirmed() {
    for (final id in liveMessages.keys.toList()) {
      liveMessages[id] = {...liveMessages[id]!, 'unconfirmed': true};
    }
  }

  void fail(Object exception) {
    _statusRevision++;
    _connectionGeneration++;
    error = '$exception';
    phase = 'failed';
    _markLiveUnconfirmed();
    _apiStreams.setReady(false);
    notifyListeners();
  }

  Future<void> start() async {
    _subscription ??= events.receiveBroadcastStream().listen(
      (dynamic raw) {
        final frame = jsonDecode(raw as String) as Json;
        final data = (frame['params'] as Json?) ?? {};
        switch (frame['method']) {
          case 'runtime.status':
            _acceptStatus(data);
          case 'session.event':
            final id = data['sessionId'] as String;
            final event = data['event'] as Json;
            final timeline = timelines.putIfAbsent(id, () => []);
            if (!timeline.any((item) => item['seq'] == event['seq'])) {
              timeline.add(event);
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
            web = data;
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
    await channel.invokeMethod<void>('start');
    _prepareAccount();
  }

  void _acceptStatus(Json data) {
    _statusRevision++;
    final nextGeneration = data['generation'] as String?;
    final changedProcess =
        nextGeneration != null && nativeGeneration != nextGeneration;
    final nextPhase = data['phase'] as String;
    final newProcess = changedProcess || nextPhase == 'starting';
    if (newProcess || (ready && nextPhase != 'ready')) {
      _connectionGeneration++;
      _interactionsRevision = -1;
      _apiStreams.setReady(false);
      _markLiveUnconfirmed();
    }
    if (newProcess) {
      // These projections belong to one native process. A transient disconnect
      // may retain them as unconfirmed; a new process must supply a new baseline.
      taskState = {};
      liveMessages.clear();
      statuses.clear();
      streaming.clear();
    }
    phase = nextPhase;
    nativeGeneration = nextGeneration;
    nativeMode = data['mode'] as String?;
    error = data['error'] as String?;
    if (!ready) _markLiveUnconfirmed();
    // Invalidate domain observations before a replacement stream can emit its
    // baseline. A synchronous first frame must not be cleared by a later notify.
    notifyListeners();
    _apiStreams.setReady(ready);
    if (ready) {
      unawaited(
        refresh().catchError((Object failure) {
          if (!_disposed) {
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
    if (_resume != null) return _resume!;
    late final Future<void> operation;
    operation =
        () async {
          try {
            final statusRevision = _statusRevision;
            final state = await call('runtime.status') as Json;
            if (_disposed) return;
            // A pushed service transition observed after this request is newer than
            // the probe, even if the probe's Future completes afterwards.
            if (statusRevision == _statusRevision) _acceptStatus(state);
            if (!ready) return;
            await _apiStreams.reconnect();
            if (_disposed || !ready) return;
            await Future.wait([
              () async {
                final account = await ensureAccount();
                await account.ensureWatching();
                if (account.connected) await account.refreshDetails();
              }(),
              if (_models != null) _models!.refresh(),
            ]);
          } catch (failure) {
            if (!_disposed) {
              error = '返回前台后的状态同步未完成：$failure';
              notifyListeners();
            }
          }
        }().whenComplete(() {
          if (identical(_resume, operation)) _resume = null;
        });
    return _resume = operation;
  }

  Future<void> restart() async {
    _statusRevision++;
    phase = 'restarting';
    error = null;
    _interactionsRevision = -1;
    _connectionGeneration++;
    taskState = {};
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

  Future<dynamic> call(String method, [Json params = const {}]) async {
    final result = await channel.invokeMethod<String>(
      'call',
      jsonEncode({'method': method, 'params': params}),
    );
    final decoded = result == null ? null : jsonDecode(result);
    if (decoded is Json && decoded['_pocket_error'] is Json) {
      final failure = decoded['_pocket_error'] as Json;
      throw PlatformException(
        code: failure['code'] as String,
        message: failure['message'] as String,
        details: failure,
      );
    }
    return decoded;
  }

  Future<void> refreshForms() async {
    final generation = _connectionGeneration;
    final next = (await call('settings.describe') as List).cast<Json>();
    if (_disposed || generation != _connectionGeneration) return;
    forms = next;
    for (final form in forms) {
      if (form['ns'] == 'agent-default-model' && form['value'] is Json) {
        final selected = form['value'] as Json;
        if (selected['provider'] is String && selected['model'] is String) {
          provider = selected['provider'] as String;
          model = selected['model'] as String;
          reasoningEffort = selected['reasoningEffort'] as String?;
        }
      }
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    info = await call('runtime.info') as Json;
    await refreshLive();
    await refreshInteractions();
    web = await call('web.status') as Json;
    await refreshSessions();
    await refreshForms();
    await refreshTasks();
  }

  void _applyTasks(Json snapshot) {
    if (snapshot['epoch'] == taskState['epoch'] &&
        (snapshot['revision'] as int) < (taskState['revision'] as int? ?? -1)) {
      return;
    }
    taskState = {
      'epoch': snapshot['epoch'],
      'revision': snapshot['revision'],
      'summary': snapshot['summary'],
      'active': snapshot['active'],
    };
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
      _applyTasks(snapshot);
      taskSessions = (snapshot['sessions'] as List).cast<Json>();
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
    _applyTasks(snapshot);
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
    try {
      _applyInteractions(await call('interactions.list') as Json);
    } catch (exception) {
      interactionsError = '$exception';
      rethrow;
    } finally {
      notifyListeners();
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
    if (_sessionsRefresh != null) {
      _sessionsRefreshAgain = true;
      return _sessionsRefresh!;
    }
    late final Future<void> operation;
    operation = _readSessions().whenComplete(() {
      if (identical(_sessionsRefresh, operation)) _sessionsRefresh = null;
    });
    return _sessionsRefresh = operation;
  }

  Future<void> _readSessions() async {
    do {
      _sessionsRefreshAgain = false;
      final generation = _connectionGeneration;
      List<Json> next;
      try {
        next = (await call('sessions.list') as List).cast<Json>();
      } catch (_) {
        // A queued invalidation still owns a fresh read after this one fails.
        if (_sessionsRefreshAgain && ready && !_disposed) continue;
        rethrow;
      }
      if (_disposed) return;
      if (generation != _connectionGeneration) {
        _sessionsRefreshAgain = ready;
        continue;
      }
      sessions = next;
      notifyListeners();
    } while (_sessionsRefreshAgain && !_disposed);
  }

  String newSession() {
    final random = Random.secure();
    final id =
        'android-${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 30)}';
    timelines[id] = [];
    return id;
  }

  Future<void> openSession(String id) async {
    final accumulated = <Json>[];
    var offset = 0;
    while (true) {
      final page = await call('session.read', {
        'sessionId': id,
        'offset': offset,
      }) as Json;
      final records = (page['events'] as List).cast<Json>();
      accumulated.addAll(records);
      if (records.length < 200) break;
      offset = (records.last['seq'] as int) + 1;
    }
    // Merge notifications received while the historical pages were loading.
    for (final event in timelines[id] ?? <Json>[]) {
      if (!accumulated.any((record) => record['seq'] == event['seq'])) {
        accumulated.add(event);
      }
    }
    accumulated.sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
    timelines[id] = accumulated;
    notifyListeners();
  }

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
    _connectionGeneration++;
    _plugins?.dispose();
    _library?.dispose();
    _credentials?.dispose();
    _recovery?.dispose();
    _account?.removeListener(_accountChanged);
    _account?.dispose();
    _models?.dispose();
    unawaited(_subscription?.cancel());
    unawaited(_apiStreams.close());
    unawaited(_remoteEvents.close());
    super.dispose();
  }
}
