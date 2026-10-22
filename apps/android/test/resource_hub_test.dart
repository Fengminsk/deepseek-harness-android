import 'package:dsh_android/resource_hub.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_files.dart';
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

  @override
  Future<void> openSession(String id) async {
    historyReads++;
    timelines[id] = [
      changeEvent(1, 'turn/start', 1),
      changeEvent(2, 'workspace/changes', 1),
      changeEvent(3, 'turn/end', 1),
    ];
    notifyListeners();
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
      return {
        'path': '',
        'entries': [
          {'name': 'notes.md', 'type': 'file', 'size': 24},
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

Future<void> _mount(WidgetTester tester, RuntimeController runtime) async {
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
      home: SessionResourcesPage(runtime: runtime, sessionId: 'session'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
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
      expect(runtime.calls, isEmpty);
      expect(runtime.historyReads, 0);

      await tester.tap(find.byKey(const ValueKey('resource-files')));
      await tester.pumpAndSettle();
      final page = tester.widget<SessionFilesPage>(
        find.byType(SessionFilesPage),
      );
      expect(page.sessionId, 'session');
      expect(find.text('notes.md'), findsOneWidget);
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
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
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
}
