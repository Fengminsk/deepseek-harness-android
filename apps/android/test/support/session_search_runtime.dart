import 'dart:async';

import 'package:dsh_android/runtime.dart';

class SessionSearchTestRuntime extends RuntimeController {
  SessionSearchTestRuntime() {
    phase = 'ready';
  }

  int generation = 1;
  final calls = <({String method, Json params})>[];
  final pending = <Completer<dynamic>>[];
  bool deferSearch = false, deferCatalog = false;
  Object? searchFailure, catalogFailure;
  dynamic response = <String, dynamic>{'items': [], 'hasMore': false};
  dynamic catalog = <String, dynamic>{
    'sessions': [
      {
        'sessionId': 'first',
        'projections': {
          'values': {'title': '手机里的本地助手'},
        },
      },
      {
        'sessionId': 'archived',
        'projections': {
          'values': {'title': '旧的测试会话'},
        },
      },
    ],
    'archivedSessionIds': ['archived'],
  };
  Completer<dynamic>? catalogRead;

  @override
  int get connectionGeneration => generation;

  void changeConnection({bool ready = true, bool sameGeneration = false}) {
    if (!sameGeneration) generation++;
    phase = ready ? 'ready' : 'disconnected';
    notifyListeners();
  }

  void changeEpoch() {
    taskState = {'epoch': '${taskState['epoch']} next'};
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: params));
    if (method == 'library.catalog') {
      if (catalogFailure != null) throw catalogFailure!;
      if (deferCatalog) {
        catalogRead = Completer<dynamic>();
        return catalogRead!.future;
      }
      return catalog;
    }
    if (method == 'api.call' &&
        params['namespace'] == 'session' &&
        params['method'] == 'search') {
      if (searchFailure != null) throw searchFailure!;
      if (deferSearch) {
        final read = Completer<dynamic>();
        pending.add(read);
        return read.future;
      }
      return response;
    }
    throw StateError('Unexpected search side effect: $method $params');
  }
}

Json sessionSearchResponse(
  String snippet, {
  String id = 'first',
  bool more = false,
}) => {
  'items': [
    {'sessionId': id, 'snippet': snippet},
  ],
  'hasMore': more,
};
