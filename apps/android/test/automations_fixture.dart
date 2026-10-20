import 'dart:async';

import 'package:dsh_android/runtime.dart';

Json taskFixture({
  String id = 'task-a',
  String title = '整理进度',
  String status = 'active',
}) => {
  'id': id,
  'sessionId': 'conversation-a',
  'title': title,
  'prompt': '检查任务进度并总结。',
  'kind': 'every',
  'everySeconds': 3600,
  'scheduledAt': '2030-01-01T12:00:00.123Z',
  'status': status,
};

class AutomationRuntime extends RuntimeController {
  AutomationRuntime() {
    phase = 'ready';
    sessions = [
      {
        'header': {'id': 'conversation-a'},
      },
    ];
  }
  final events = StreamController<Json>.broadcast(sync: true);
  final requests = <({String method, Json args})>[];
  List<Json> tasks = [taskFixture()];
  Future<dynamic> Function(String method, Json args)? handler;
  @override
  Stream<Json> get remoteEvents => events.stream;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method != 'api.call' || params['namespace'] != 'schedule') {
      throw StateError('Unexpected runtime operation: $method');
    }
    final name = params['method'] as String;
    final args = params['args'] as Json;
    requests.add((method: name, args: args));
    if (handler != null) return handler!(name, args);
    if (name == 'catalog') return tasks;
    throw StateError('Unexpected schedule operation: $name');
  }

  void connection(bool ready) {
    phase = ready ? 'ready' : 'failed';
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(events.close());
    super.dispose();
  }
}
