import 'package:dsh_android/resource_hub.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_files.dart';
import 'package:dsh_android/session_terminal.dart';
import 'package:dsh_android/tasks.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'workspace_changes_fixtures.dart';

class _ResourceRuntime extends RuntimeController {
  _ResourceRuntime() {
    phase = 'ready';
  }

  final calls = <(String, Json)>[];
  int historyReads = 0;
  String? terminalId;
  int terminalRevision = 1;

  void connection(String next) {
    phase = next;
    notifyListeners();
  }

  @override
  Future<List<Json>> readCompleteSession(String id) async {
    historyReads++;
    return [
      changeEvent(1, 'turn/start', 1),
      changeEvent(2, 'workspace/changes', 1),
      changeEvent(3, 'turn/end', 1),
    ];
  }

  @override
  Future<void> refreshTasks() async {}

  @override
  Future<void> refreshInteractions() async {}

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) => const Stream.empty();

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, params));
    if (method == 'terminal.list') {
      return terminalId == null
          ? <Json>[]
          : <Json>[
              {'id': terminalId, 'cwd': '/work', 'state': 'running'},
            ];
    }
    if (method == 'terminal.shells') {
      return [
        {'id': 'system-sh', 'label': '系统 Shell'},
      ];
    }
    if (method == 'terminal.create') {
      expectSync(params['shellId'], 'system-sh');
      terminalId = params['id'] as String;
      return {'id': terminalId, 'state': 'running'};
    }
    if (method == 'terminal.read') {
      return {
        'id': terminalId,
        'state': 'running',
        'revision': terminalRevision,
        'display': 'ready\n/work prompt',
      };
    }
    if (method == 'terminal.write') {
      terminalRevision++;
      return {'accepted': true};
    }
    if (method == 'terminal.close') {
      terminalId = null;
      return {'closed': true};
    }
    if (method == 'workspaceChanges.summary') {
      expectSync(params['sessionId'], 'session');
      expectSync(params['seq'], 2);
      return accepted(changeSummary());
    }
    if (method != 'api.call') throw StateError('Unexpected $method');
    final namespace = params['namespace'];
    final operation = params['method'];
    if (namespace == 'settings' && operation == 'describe') {
      return {
        'writable': true,
        'namespaces': [
          {
            'ns': 'ui-settings',
            'revision': 1,
            'schema': <String, dynamic>{},
            'secrets': <dynamic>[],
            'value': {'enabled': true},
            'base': {'enabled': true},
            'user': <String, dynamic>{},
          },
        ],
      };
    }
    if (namespace == 'session' && operation == 'list') {
      return {
        'items': [
          {'sessionId': 'session', 'cwd': '/work'},
        ],
      };
    }
    if (namespace == 'workspaceFiles' && operation == 'list') {
      final path = (params['args'] as Json)['path'] as String;
      return {
        'path': path,
        'entries': [
          {'name': 'notes.md', 'type': 'file', 'size': 24},
          {'name': 'folder', 'type': 'directory'},
          for (var i = 0; i < 45; i++)
            {'name': 'file-$i.txt', 'type': 'file', 'size': i},
        ],
        'truncated': false,
      };
    }
    if (namespace == 'skills' && operation == 'list') {
      expectSync(params['args'], {
        'request': {'sessionId': 'session'},
      });
      return {
        'skills': [
          {
            'name': 'summarize',
            'description': '汇总文档',
            'modelInvocable': true,
            'path': '/work/skills/summarize/SKILL.md',
          },
        ],
      };
    }
    throw StateError('Unexpected $namespace.$operation');
  }
}

Future<void> _mount(
  WidgetTester tester,
  RuntimeController runtime, {
  String sessionId = 'session',
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      builder: (_, child) => MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: SessionResourcesPage(runtime: runtime, sessionId: sessionId),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'tabs mount on selection and retain browser draft and file scroll',
    (tester) async {
      final runtime = _ResourceRuntime();
      await _mount(tester, runtime);
      expect(runtime.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('resource-files')));
      await tester.pumpAndSettle();
      final listing = find.byKey(const ValueKey('file-browser-list'));
      await tester.drag(listing, const Offset(0, -520));
      await tester.pumpAndSettle();
      final before = tester.widget<ListView>(listing).controller!.offset;
      expect(before, greaterThan(0));
      expect(runtime.historyReads, 0);
      await tester.tap(find.byKey(const ValueKey('resource-tab-guide')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-browser')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('browser-address')),
        'https://example.org/draft',
      );
      await tester.tap(find.byKey(const ValueKey('resource-tab-files')));
      await tester.pumpAndSettle();
      expect(tester.widget<ListView>(listing).controller!.offset, before);
      await tester.tap(find.byKey(const ValueKey('resource-tab-browser')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('browser-address')))
            .controller!
            .text,
        'https://example.org/draft',
      );
      expect(runtime.calls.any((call) => call.$1 == 'session.ensure'), false);
      expect(runtime.calls.any((call) => call.$1 == 'session.send'), false);
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
    },
  );

  testWidgets(
    'Session changes isolate tabs; re-entry restores safe identities',
    (tester) async {
      final runtime = _ResourceRuntime();
      await _mount(tester, runtime);
      await tester.tap(find.byKey(const ValueKey('resource-browser')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('browser-address')),
        'https://example.org/private-draft',
      );
      await _mount(tester, runtime, sessionId: 'other');
      expect(find.byKey(const ValueKey('resource-tab-browser')), findsNothing);
      expect(find.byKey(const ValueKey('resource-browser')), findsOneWidget);
      expect(runtime.calls, isEmpty);
      await _mount(tester, runtime, sessionId: 'session');
      expect(
        find.byKey(const ValueKey('resource-tab-browser')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('browser-address')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('browser-address')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('resource-close-browser')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('resource-tab-browser')), findsNothing);
      expect(find.byKey(const ValueKey('resource-browser')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
    },
  );

  testWidgets('re-entry reads only the selected tab until another is chosen', (
    tester,
  ) async {
    final runtime = _ResourceRuntime();
    await _mount(tester, runtime);
    await tester.tap(find.byKey(const ValueKey('resource-files')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resource-tab-guide')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resource-changes')));
    await tester.pumpAndSettle();
    int fileReads() => runtime.calls
        .where(
          (call) =>
              call.$1 == 'api.call' && call.$2['namespace'] == 'workspaceFiles',
        )
        .length;
    expect(fileReads(), 1);
    expect(runtime.historyReads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await _mount(tester, runtime);
    expect(find.byType(SessionChangesPage), findsOneWidget);
    expect(runtime.historyReads, 2);
    expect(fileReads(), 1);
    await tester.tap(find.byKey(const ValueKey('resource-tab-files')));
    await tester.pumpAndSettle();
    expect(fileReads(), 2);
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });

  testWidgets('terminal remains attached on tab switch and reconnect', (
    tester,
  ) async {
    final runtime = _ResourceRuntime();
    runtime.terminalId = 'existing-pty';
    await _mount(tester, runtime);
    await tester.tap(find.byKey(const ValueKey('resource-terminal')));
    await tester.pumpAndSettle();
    expect(
      runtime.calls.where((call) => call.$1 == 'terminal.list'),
      hasLength(1),
    );
    await tester.tap(find.byKey(const ValueKey('resource-tab-guide')));
    await tester.pumpAndSettle();
    runtime.connection('failed');
    await tester.pumpAndSettle();
    runtime.connection('ready');
    await tester.pumpAndSettle();
    expect(
      runtime.calls.where((call) => call.$1 == 'terminal.list'),
      hasLength(2),
    );
    expect(runtime.terminalId, 'existing-pty');
    expect(runtime.calls.any((call) => call.$1 == 'terminal.create'), false);
    await tester.tap(find.byKey(const ValueKey('resource-tab-terminal')));
    await tester.pumpAndSettle();
    expect(find.byType(SessionTerminalsPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('resource-close-terminal')));
    await tester.pumpAndSettle();
    expect(runtime.calls.any((call) => call.$1 == 'terminal.close'), false);
    expect(runtime.terminalId, 'existing-pty');
    expect(find.byKey(const ValueKey('resource-tab-terminal')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });

  testWidgets('resource back selects guide without closing the tab', (
    tester,
  ) async {
    final runtime = _ResourceRuntime();
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                PocketRoute<void>(
                  builder: (_) => SessionResourcesPage(
                    runtime: runtime,
                    sessionId: 'session',
                  ),
                ),
              ),
              child: const Text('打开资源'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开资源'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resource-browser')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('resource-browser')), findsOneWidget);
    expect(find.byKey(const ValueKey('resource-tab-browser')), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('打开资源'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });

  testWidgets(
    'resource hub keeps one Session and opens original file browser',
    (tester) async {
      final runtime = _ResourceRuntime();
      await _mount(tester, runtime);
      expect(find.text('会话资源'), findsOneWidget);
      expect(find.byKey(const ValueKey('resource-files')), findsOneWidget);
      expect(find.byKey(const ValueKey('resource-changes')), findsOneWidget);
      expect(find.byKey(const ValueKey('resource-skills')), findsOneWidget);
      expect(find.byKey(const ValueKey('resource-tasks')), findsOneWidget);
      expect(find.byKey(const ValueKey('resource-terminal')), findsOneWidget);
      expect(runtime.calls, isEmpty);
      expect(runtime.historyReads, 0);

      await tester.tap(find.byKey(const ValueKey('resource-files')));
      await tester.pumpAndSettle();
      final page = tester.widget<SessionFilesPage>(
        find.byType(SessionFilesPage),
      );
      expect(page.sessionId, 'session');
      expect(find.text('folder'), findsOneWidget);
      expect(runtime.calls.any((call) => call.$1 == 'session.ensure'), false);
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
    },
  );

  testWidgets('changes use recorded turn coordinates and read-only history', (
    tester,
  ) async {
    final runtime = _ResourceRuntime();
    await _mount(tester, runtime);
    await tester.tap(find.byKey(const ValueKey('resource-changes')));
    await tester.pumpAndSettle();
    expect(find.byType(SessionChangesPage), findsOneWidget);
    expect(runtime.historyReads, 1);
    expect(find.text('example.dart'), findsOneWidget);
    expect(
      runtime.calls.any((call) => call.$1 == 'workspaceChanges.summary'),
      true,
    );
    expect(runtime.calls.any((call) => call.$1 == 'session.ensure'), false);
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });

  testWidgets('skills are read-only and tasks retain the Session filter', (
    tester,
  ) async {
    final runtime = _ResourceRuntime();
    await _mount(tester, runtime);
    await tester.tap(find.byKey(const ValueKey('resource-skills')));
    await tester.pumpAndSettle();
    final skills = tester.widget<SessionResourceSkillsPage>(
      find.byType(SessionResourceSkillsPage),
    );
    expect(skills.sessionId, 'session');
    expect(find.text('summarize'), findsOneWidget);
    expect(runtime.calls.any((call) => call.$1 == 'session.ensure'), false);
    expect(runtime.calls.any((call) => call.$1 == 'session.send'), false);
    await tester.tap(find.byKey(const ValueKey('resource-tab-guide')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resource-tasks')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TasksPage>(find.byType(TasksPage)).sessionId,
      'session',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });

  testWidgets(
    'terminal entry creates a Session PTY, sends input and closes it',
    (tester) async {
      final runtime = _ResourceRuntime();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          if (call.method == 'terminal.shell.load') return 'system-sh';
          throw StateError('Unexpected ${call.method}');
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await _mount(tester, runtime);
      await tester.tap(find.byKey(const ValueKey('resource-terminal')));
      await tester.pumpAndSettle();
      expect(find.byType(SessionTerminalsPage), findsOneWidget);
      expect(
        runtime.calls
            .where((call) => call.$1 == 'terminal.list')
            .single
            .$2['sessionId'],
        'session',
      );
      await tester.tap(find.byTooltip('新建终端'));
      await tester.pumpAndSettle();
      expect(
        runtime.calls.map((call) => call.$1),
        containsAllInOrder(['terminal.shells', 'terminal.create']),
      );
      expect(find.byType(SessionTerminalView), findsOneWidget);
      expect(find.textContaining('ready'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'pwd');
      await tester.pump();
      expect(
        runtime.calls
            .lastWhere((call) => call.$1 == 'terminal.write')
            .$2['data'],
        'pwd',
      );
      await tester.tap(find.byTooltip('发送回车'));
      await tester.pump();
      expect(
        runtime.calls
            .lastWhere((call) => call.$1 == 'terminal.write')
            .$2['data'],
        '\r',
      );
      await tester.tap(find.byTooltip('关闭终端进程'));
      await tester.pumpAndSettle();
      expect(runtime.terminalId, isNull);
      expect(runtime.calls.any((call) => call.$1 == 'session.ensure'), false);
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
    },
  );
}
