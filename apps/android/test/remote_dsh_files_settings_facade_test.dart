// 文件/设置门面：`workspace.files.*`、`settings.describe/mutate` 与模型目录的
// 线上参数与解析。
//
// 这里不连宿主：`RemoteDshFacade` 只接收 `RuntimeTransport`，测试用一个记录请求并
// 注入应答的假传输，因此分页参数、写回 ops 形态与错误透传都能在没有 PC 的情况下
// 验证。页面由 remote_workspace_files_page_test.dart 与
// remote_dsh_settings_page_test.dart 覆盖。

import 'dart:async';

import 'package:dsh_android/remote_dsh_live_source.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求并按方法给出应答的传输替身。
class _RecordingTransport implements RuntimeTransport {
  _RecordingTransport(this.answers);

  /// 每个方法的应答工厂；没有配置的方法返回空对象。
  final Map<String, Object? Function(Map<String, dynamic> params)> answers;

  /// 按调用顺序记录的方法名与参数。
  final List<({String method, Map<String, dynamic> params})> requests =
      <({String method, Map<String, dynamic> params})>[];

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  List<Map<String, dynamic>> paramsOf(String method) => <Map<String, dynamic>>[
    for (final request in requests)
      if (request.method == method) request.params,
  ];

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    requests.add((method: method, params: Map<String, dynamic>.of(params)));
    final answer = answers[method];
    if (answer != null) return answer(params);
    return <String, dynamic>{};
  }

  @override
  void notify(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {}

  @override
  void setRequestHandler(
    Future<dynamic> Function(String method, Map<String, dynamic> params)?
    handler,
  ) {}

  @override
  Future<void> close() async {}
}

/// 一份最小的 `workspace.files.list` 应答。
Map<String, dynamic> _directory({
  String path = '',
  int offset = 0,
  int? nextOffset,
  List<Map<String, dynamic>> entries = const <Map<String, dynamic>>[],
}) => <String, dynamic>{
  'root': r'C:\work',
  'path': path,
  'version': 'dir-v1',
  'offset': offset,
  'nextOffset': nextOffset,
  'truncated': false,
  'listedEntries': entries.length,
  'entries': entries,
};

/// 一份最小的 `settings.describe` 应答（门面实际返回数组）。
List<dynamic> _settings({
  String provider = 'deepseek-account',
  String model = 'deepseek-flash',
  int revision = 3,
}) => <dynamic>[
  <String, dynamic>{
    'ns': 'agent-default-model',
    'revision': revision,
    'schema': <String, dynamic>{
      'type': 'object',
      'dict': <String, dynamic>{
        'provider': <String, dynamic>{'type': 'string'},
        'model': <String, dynamic>{'type': 'string'},
        'reasoningEffort': <String, dynamic>{'type': 'string'},
      },
    },
    'value': <String, dynamic>{'provider': provider, 'model': model},
  },
];

void main() {
  group('workspace.files 门面', () {
    test('读目录：首页不带版本，续页带回偏移与目录版本', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'workspace.files.list': (params) => _directory(
            path: params['path'] as String,
            offset: params['offset'] as int,
            nextOffset: 2,
            entries: <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'src',
                'path': 'src',
                'kind': 'directory',
              },
            ],
          ),
        },
      );
      final facade = RemoteDshFacade(transport);

      final first = await facade.listDirectory(path: '');
      expect(first.entries.single.name, 'src');
      expect(
        transport.paramsOf('workspace.files.list').single,
        <String, dynamic>{'path': '', 'offset': 0},
      );

      await facade.listDirectory(path: '', offset: 2, version: 'dir-v1');
      expect(transport.paramsOf('workspace.files.list').last, <String, dynamic>{
        'path': '',
        'offset': 2,
        'version': 'dir-v1',
      });
    });

    test('读文件：透传偏移与版本并解析文本', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'workspace.files.read': (params) => <String, dynamic>{
            'root': r'C:\work',
            'path': params['path'],
            'version': 'file-v1',
            'bytes': 8,
            'offset': params['offset'],
            'nextOffset': 8,
            'eof': true,
            'text': '你好',
          },
        },
      );
      final facade = RemoteDshFacade(transport);

      final page = await facade.readFile(path: 'a.txt', offset: 0);
      expect(page.text, '你好');
      expect(page.eof, isTrue);
      expect(
        transport.paramsOf('workspace.files.read').single,
        <String, dynamic>{'path': 'a.txt', 'offset': 0},
      );
    });

    test('非文本文件把宿主错误原样抛成可展示的 PlatformException', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'workspace.files.read': (_) => throw const RuntimeTransportFailure(
            code: 'workspace-files/not-text',
            message: '此文件不是可预览的 UTF-8 文本。',
          ),
        },
      );
      final facade = RemoteDshFacade(transport);
      await expectLater(
        facade.readFile(path: 'image.bin'),
        throwsA(
          isA<PlatformException>()
              .having(
                (failure) => failure.code,
                'code',
                'workspace-files/not-text',
              )
              .having(
                (failure) => failure.message,
                'message',
                '此文件不是可预览的 UTF-8 文本。',
              ),
        ),
      );
    });
  });

  group('settings 门面', () {
    test('读设置：解析数组应答里的默认模型路由', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'settings.describe': (_) => _settings(),
        },
      );
      final facade = RemoteDshFacade(transport);

      final snapshot = await facade.describeSettings();
      expect(
        snapshot.defaultModelSection?.defaultModelRoute?.label,
        'deepseek-account/deepseek-flash',
      );
      expect(transport.paramsOf('settings.describe').single, isEmpty);
    });

    test('改默认模型：set 服务商与模型，未指定强度时 unset，并带回修订号', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'settings.mutate': (_) =>
              _settings(model: 'deepseek-v4-pro', revision: 4),
        },
      );
      final facade = RemoteDshFacade(transport);

      final snapshot = await facade.saveDefaultModel(
        route: const RemoteDshModelRoute(
          provider: 'deepseek-account',
          model: 'deepseek-v4-pro',
        ),
        revision: 3,
      );

      final params = transport.paramsOf('settings.mutate').single;
      expect(params['ns'], 'agent-default-model');
      expect(params['revision'], 3);
      expect(params['ops'], <Map<String, dynamic>>[
        <String, dynamic>{
          'op': 'set',
          'path': <String>['provider'],
          'value': 'deepseek-account',
        },
        <String, dynamic>{
          'op': 'set',
          'path': <String>['model'],
          'value': 'deepseek-v4-pro',
        },
        <String, dynamic>{
          'op': 'unset',
          'path': <String>['reasoningEffort'],
        },
      ]);
      expect(snapshot.defaultModelSection?.revision, 4);
    });

    test('带推理强度时用 set 写回', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'settings.mutate': (_) => _settings(),
        },
      );
      final facade = RemoteDshFacade(transport);
      await facade.saveDefaultModel(
        route: const RemoteDshModelRoute(
          provider: 'deepseek-account',
          model: 'deepseek-v4-pro',
          reasoningEffort: 'high',
        ),
        revision: 1,
      );
      final ops =
          transport.paramsOf('settings.mutate').single['ops'] as List<dynamic>;
      expect(ops.last, <String, dynamic>{
        'op': 'set',
        'path': <String>['reasoningEffort'],
        'value': 'high',
      });
    });

    test('版本冲突保留稳定错误码供页面识别', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'settings.mutate': (_) => throw const RuntimeTransportFailure(
            code: 'SETTINGS_CONFLICT',
            message: 'settings namespace "agent-default-model" changed since it was read',
          ),
        },
      );
      final facade = RemoteDshFacade(transport);
      await expectLater(
        facade.saveDefaultModel(
          route: const RemoteDshModelRoute(
            provider: 'deepseek-account',
            model: 'deepseek-flash',
          ),
          revision: 2,
        ),
        throwsA(
          isA<PlatformException>().having(
            (failure) => failure.code,
            'code',
            'SETTINGS_CONFLICT',
          ),
        ),
      );
    });
  });

  group('模型目录门面', () {
    test('走 api.call 的 session.modelCatalog 并解析分组', () async {
      final transport = _RecordingTransport(
        <String, Object? Function(Map<String, dynamic>)>{
          'api.call': (_) => <String, dynamic>{
            'groups': <dynamic>[
              <String, dynamic>{
                'id': 'deepseek-account',
                'name': 'DeepSeek 账号',
                'models': <dynamic>[
                  <String, dynamic>{
                    'id': 'deepseek-flash',
                    'name': 'DeepSeek-V4-Flash',
                  },
                ],
              },
            ],
          },
        },
      );
      final facade = RemoteDshFacade(transport);

      final catalog = await facade.describeModelCatalog();
      expect(catalog.groups.single.id, 'deepseek-account');
      expect(transport.paramsOf('api.call').single, <String, dynamic>{
        'namespace': 'session',
        'method': 'modelCatalog',
        'args': <String, dynamic>{},
      });
    });
  });
}
