import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef Json = Map<String, dynamic>;

class RuntimeController extends ChangeNotifier {
  static const channel = MethodChannel('dsh/runtime');
  static const events = EventChannel('dsh/events');
  StreamSubscription<dynamic>? _subscription;
  String phase = 'starting';
  String? error;
  Json info = {};
  Json web = {};
  List<Json> sessions = [];
  List<Json> forms = [];
  List<Json> interactions = [];
  String? interactionsError;
  int _interactionsRevision = -1;
  Json? navigationRequest;
  final Map<String, List<Json>> timelines = {};
  final Map<String, String> streaming = {};
  final Map<String, String> statuses = {};
  Future<void>? _liveRefresh;
  List<({String method, Json data})>? _liveBuffer;
  String _provider = 'deepseek-official';
  String _model = 'deepseek-flash';
  bool _modelChanged = false;
  final Map<String, ({String text, String id})> _submissions = {};
  String get provider => _provider;
  set provider(String value) {
    if (_provider != value) _modelChanged = true;
    _provider = value;
  }

  String get model => _model;
  set model(String value) {
    if (_model != value) _modelChanged = true;
    _model = value;
  }

  bool get ready => phase == 'ready';
  void fail(Object exception) {
    error = '$exception';
    phase = 'failed';
    notifyListeners();
  }

  Future<void> start() async {
    _subscription ??= events.receiveBroadcastStream().listen(
      (dynamic raw) {
        final frame = jsonDecode(raw as String) as Json;
        final data = (frame['params'] as Json?) ?? {};
        switch (frame['method']) {
          case 'runtime.status':
            phase = data['phase'] as String;
            error = data['error'] as String?;
            if (phase == 'starting') {
              _interactionsRevision = -1;
            }
            if (ready) {
              unawaited(
                refresh().catchError((Object e) {
                  error = '$e';
                  notifyListeners();
                }),
              );
            }
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
          case 'session.status':
            _receiveLive('session.status', data);
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
        }
        notifyListeners();
      },
      onError: (Object exception) {
        phase = 'failed';
        error = '$exception';
        notifyListeners();
      },
    );
    await channel.invokeMethod<void>('start');
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
    forms = (await call('settings.describe') as List).cast<Json>();
    for (final form in forms) {
      if (form['ns'] == 'agent-default-model' && form['value'] is Json) {
        final selected = form['value'] as Json;
        if (selected['provider'] is String && selected['model'] is String) {
          _provider = selected['provider'] as String;
          _model = selected['model'] as String;
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
    if (method == 'session.status') {
      statuses[id] = data['status'] as String;
      if (data['status'] == 'idle') streaming.remove(id);
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

  Future<void> refreshLive() => _liveRefresh ??= _readLive().whenComplete(() {
    _liveRefresh = null;
  });

  Future<void> _readLive() async {
    _liveBuffer = [];
    try {
      final baseline = await call('runtime.live') as Json;
      statuses
        ..clear()
        ..addAll((baseline['statuses'] as Json).cast<String, String>());
      streaming
        ..clear()
        ..addAll((baseline['streaming'] as Json).cast<String, String>());
      for (final update in _liveBuffer!) {
        if ((update.data['revision'] as int) > (baseline['revision'] as int)) {
          _applyLive(update.method, update.data);
        }
      }
      notifyListeners();
    } finally {
      _liveBuffer = null;
    }
  }

  Future<void> refreshSessions() async {
    sessions = (await call('sessions.list') as List).cast<Json>();
    notifyListeners();
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

  Future<void> send(String id, String text) async {
    final requestedProvider = provider;
    final requestedModel = model;
    final previous = _submissions[id];
    final request = previous?.text == text
        ? previous!
        : (
            text: text,
            id: 'app-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}',
          );
    _submissions[id] = request;
    await call('session.send', {
      'sessionId': id,
      'requestId': request.id,
      'text': text,
      'provider': requestedProvider,
      'model': requestedModel,
      'selectModel': _modelChanged,
    });
    if (provider == requestedProvider && model == requestedModel) {
      _modelChanged = false;
    }
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
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
