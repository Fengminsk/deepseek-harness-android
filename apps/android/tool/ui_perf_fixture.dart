import 'dart:async';

import 'package:dsh_android/runtime.dart';

/// Synthetic backend for UI measurements only. No device files or real Agent
/// commands are read or executed; all widgets use the production implementation.
class UiPerfRuntime extends RuntimeController {
  UiPerfRuntime({int turns = 1000}) {
    phase = 'ready';
    info = {'workspace': '/fixture/workspace'};
    timelines[session] = [
      for (var turn = 1; turn <= turns; turn++) ...[
        {
          'seq': turn * 2,
          'time': turn * 1000,
          'type': 'user/message',
          'surfaceOp': 'append',
          'data': {
            'id': 'user-$turn',
            'role': 'user',
            'source': {'kind': 'user'},
            'content': [
              {'type': 'text', 'text': '检查工作区文件 $turn'},
            ],
          },
        },
        {
          'seq': turn * 2 + 1,
          'time': turn * 1000 + 500,
          'type': 'assistant/message',
          'surfaceOp': 'append',
          'data': {
            'turn': turn,
            'step': 1,
            'stream': <Json>[],
            'message': {
              'id': 'answer-$turn',
              'role': 'assistant',
              'source': {
                'kind': 'model',
                'provider': 'fixture',
                'model': 'fixture',
              },
              'content': [
                {'type': 'text', 'text': '文件 $turn 已核对。'},
              ],
            },
          },
        },
      ],
    ];
  }
  static const session = 'ui-performance-fixture';
  final control = StreamController<Json>.broadcast(sync: true);
  final requests = <String, int>{};
  bool tools = true;
  int revision = 1;

  Json get toolsDescriptor => {
    'ns': 'ui-settings',
    'revision': revision,
    'value': {'enabled': tools},
    'base': {'enabled': true},
    'user': {'enabled': tools},
    'secrets': <Json>[],
    'schema': {
      'type': 'object',
      'dict': {
        'enabled': {'type': 'boolean'},
      },
    },
  };

  @override
  String newSession() => session;

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) => control.stream;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    final key = method == 'api.call'
        ? '${params['namespace']}.${params['method']}'
        : method;
    requests.update(key, (n) => n + 1, ifAbsent: () => 1);
    return switch (key) {
      'userText.mask' => {'ranges': <Json>[]},
      'settings.describe' => {
        'writable': true,
        'namespaces': [toolsDescriptor],
      },
      'agentPresets.list' => {
        'presets': [
          {'id': 'standard', 'name': '标准', 'isDefault': true},
        ],
      },
      'session.list' => {'items': <Json>[]},
      'session.projections' => {
        'kind': 'sequenced',
        'asOfSeq': 0,
        'values': {'goal': null, 'plan': null},
      },
      'session.modelCatalog' => {'groups': <Json>[]},
      'pluginInventory.list' => {
        'managementAvailable': false,
        'entries': <Json>[],
      },
      'session.ensure' => {'sessionId': session, 'created': false},
      _ => throw StateError('Not part of the UI fixture: $key'),
    };
  }

  void taskTick(int revision) {
    taskState = {
      'epoch': 'fixture',
      'revision': revision,
      'summary': {'backgroundJobs': revision % 3},
      'active': <Json>[],
    };
    notifyListeners();
  }

  void liveTick(int revision) {
    statuses[session] = 'running';
    liveMessages[session] = {
      'attemptId': 'live-fixture',
      'turn': 1001,
      'step': 1,
      'revision': revision,
      'content': [
        {'type': 'text', 'text': '正在检查本地文件，进度 $revision。'},
      ],
    };
    notifyListeners();
  }

  void toolsTick() {
    tools = !tools;
    revision++;
    forms = [toolsDescriptor];
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(control.close());
    super.dispose();
  }
}
