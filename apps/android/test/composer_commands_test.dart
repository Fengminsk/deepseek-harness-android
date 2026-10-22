import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/composer_commands.dart';
import 'package:dsh_android/chat_goal.dart';
import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/chat_projection.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/models.dart';
import 'package:dsh_android/models_provider.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_models.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final catalog = <Json>[
  for (final name in [
    'export',
    'feedback',
    'compact',
    'goal',
    'permission',
    'plan',
  ])
    {
      'name': name,
      'definitionId': commandDefinitions[name],
      'description': 'original $name',
      if (name == 'goal' || name == 'plan') 'input': {'attachments': true},
    },
  {'name': 'plugin-command', 'description': 'Plugin contribution'},
];

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }
  final calls = <({String method, Json params})>[];
  bool failCommand = false;
  bool failCatalog = false;
  Completer<Json>? admission;
  int prompts = 0;
  final sentPrompts = <String>[];
  Json currentModel = {'provider': 'provider-fixture', 'model': 'one'};
  int modelSeq = 4;
  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) => const Stream.empty();
  @override
  Future<Json> ensureSession(String id) async => {
    'sessionId': id,
    'created': false,
  };
  @override
  Future<void> openSession(String id) async {}
  @override
  Future<void> send(String id, String text) async {
    prompts++;
    sentPrompts.add(text);
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: params));
    if (method == 'session.command') {
      if (admission != null) return admission!.future;
      return {
        'commandId': 'command-1',
        'result': {
          'kind': failCommand ? 'error' : 'success',
          'text': failCommand ? '原命令拒绝了输入' : '原命令完成',
        },
      };
    }
    if (method == 'attachments.prepare') {
      return {
        'id': params['id'],
        'kind': 'file',
        'receiptId': 'receipt',
        'name': 'report.txt',
        'bytes': 5,
      };
    }
    if (method == 'attachments.release') return {'released': true};
    if (method == 'api.call') {
      switch ('${params['namespace']}.${params['method']}') {
        case 'skills.list':
          return {
            'skills': [
              {
                'name': 'summarize',
                'description': '整理文件',
                'modelInvocable': false,
              },
            ],
          };
        case 'commands.list':
          if (failCatalog) throw StateError('命令目录不可用');
          if (!(params['args'] as Json).containsKey('agentId')) {
            throw StateError('Gateway requires agentId');
          }
          return catalog;
        case 'permissionPresets.catalog':
          return {
            'options': [
              {'value': 'read-only', 'name': 'Read only'},
              {'value': 'danger-full-access', 'name': 'Full access'},
            ],
          };
        case 'session.modelCatalog':
          return {
            'default': {'provider': 'provider-fixture', 'model': 'one'},
            'routableProviders': ['provider-fixture'],
            'failures': <Json>[],
            'groups': [
              {
                'id': 'provider-fixture',
                'name': 'Fixture',
                'models': [
                  {'id': 'one', 'name': 'Model one'},
                  {'id': 'two', 'name': 'Model two'},
                ],
              },
            ],
          };
        case 'session.projections':
          return {
            'kind': 'sequenced',
            'asOfSeq': modelSeq,
            'values': {
              'permissions': {'currentValue': 'read-only'},
              'modelSelection': {
                'next': Json.of(currentModel),
                'lastUsed': null,
              },
            },
          };
        case 'session.selectModel':
          final request = params['args']['request'] as Json;
          currentModel = {
            'provider': request['provider'],
            'model': request['model'],
          };
          modelSeq++;
          return {'selected': Json.of(currentModel)};
      }
    }
    throw StateError('Unexpected $method $params');
  }
}

/// Model configuration APIs remain usable when creating the chat Agent fails.
class _RecoveryRuntime extends _Runtime {
  bool failEnsure = true;
  int ensureCalls = 0;

  @override
  Future<Json> ensureSession(String id) async {
    ensureCalls++;
    if (failEnsure) throw StateError('Select an available model before use');
    return super.ensureSession(id);
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'settings.describe') {
      calls.add((method: method, params: params));
      return [
        {
          'ns': 'llm-fixture',
          'revision': 1,
          'value': {'apiKeyEnv': 'FIXTURE_KEY'},
          'user': <String, dynamic>{},
          'base': <String, dynamic>{},
          'schema': <String, dynamic>{},
          'secrets': [],
        },
      ];
    }
    if (method == 'credentials.describe') {
      calls.add((method: method, params: params));
      return {'configured': false, 'writable': true, 'source': 'keystore'};
    }
    if (method == 'api.call' && params['namespace'] == 'llm') {
      calls.add((method: method, params: params));
      switch (params['method']) {
        case 'listProviders':
          return [
            {'id': 'fixture', 'name': 'Fixture configuration'},
          ];
        case 'listConfigurableProviders':
          return [
            {
              'provider': 'fixture',
              'displayName': 'Fixture configuration',
              'settingsNs': 'llm-fixture',
              'settingsPath': <String>[],
              'declared': false,
            },
          ];
      }
    }
    return super.call(method, params);
  }
}

Widget host(Widget child, {double scale = 1}) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

void main() {
  testWidgets(
    'cold history menu reaches skills without initializing Agent commands',
    (tester) async {
      phone(tester);
      final runtime = _RecoveryRuntime();
      addTearDown(runtime.dispose);
      Json? chosen;
      await tester.pumpWidget(
        host(
          Scaffold(
            body: ComposerCommands(
              runtime: runtime,
              sessionId: 'cold-history',
              deferActivation: true,
              onPick: (value) => chosen = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(runtime.ensureCalls, 0);
      expect(runtime.calls, isEmpty);
      await tester.ensureVisible(find.text('浏览技能'));
      await tester.tap(find.text('浏览技能'));
      await tester.pumpAndSettle();
      expect(chosen?['clientAction'], 'skills');
      expect(runtime.ensureCalls, 0);
    },
  );

  testWidgets('slash skill selection stays plain text until the user submits', (
    tester,
  ) async {
    phone(tester);
    final runtime = _Runtime();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(host(ChatPage(runtime: runtime)));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('chat-composer-input'));
    await tester.enterText(field, '/su');
    await tester.pumpAndSettle();
    await tester.tap(find.text('/summarize'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '/summarize ');
    expect(runtime.prompts, 0);
    expect(
      runtime.calls.where((call) => call.method == 'session.command'),
      isEmpty,
    );
    await tester.enterText(field, '/summarize 整理报告');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(runtime.sentPrompts, ['/summarize 整理报告']);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(
      runtime.calls.where((call) => call.method == 'session.command'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'menu creation failure still reaches native model and credential pages',
    (tester) async {
      phone(tester);
      final runtime = _RecoveryRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(host(ChatPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();
      expect(find.text('请先配置可用模型与凭据，再使用会话指令。'), findsOneWidget);
      expect(find.text('文件  file'), findsOneWidget);
      final ensureBeforeConfiguration = runtime.ensureCalls;

      await tester.ensureVisible(find.text('配置模型与凭据'));
      await tester.tap(find.text('配置模型与凭据'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelsPage), findsOneWidget);
      await tester.ensureVisible(find.text('Fixture configuration'));
      await tester.tap(find.text('Fixture configuration'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderSettingsPage), findsOneWidget);
      await tester.tap(find.text('API Key'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelCredentialPage), findsOneWidget);
      expect(find.text('尚未配置凭据'), findsOneWidget);
      expect(find.byKey(const Key('model-key-input')), findsNothing);
      await tester.tap(find.text('新的 API Key'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-key-input')), findsOneWidget);
      expect(runtime.ensureCalls, ensureBeforeConfiguration);
      expect(
        runtime.calls
            .where((call) => call.method == 'credentials.describe')
            .single
            .params,
        {'ref': 'FIXTURE_KEY'},
      );
      expect(runtime.prompts, 0);
      expect(
        runtime.calls.where((call) => call.method == 'session.command'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed menu keeps the file picker and its selected attachment draft',
    (tester) async {
      phone(tester);
      final runtime = _Runtime()..failCatalog = true;
      addTearDown(runtime.dispose);
      final native = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          if (call.method == 'notifications.viewing') return null;
          native.add(call.method);
          if (call.method != 'attachment.pick') {
            throw StateError('Unexpected native action ${call.method}');
          }
          return jsonEncode({
            'items': [
              {
                'id': 'recovery-file',
                'name': 'report.txt',
                'bytes': 5,
                'mediaType': 'text/plain',
              },
            ],
          });
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(host(ChatPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();
      expect(find.textContaining('命令目录不可用'), findsOneWidget);
      await tester.ensureVisible(find.text('文件  file'));
      await tester.tap(find.text('文件  file'));
      await tester.pumpAndSettle();
      expect(native, ['attachment.pick']);
      expect(find.text('report.txt'), findsOneWidget);
      expect(
        runtime.calls
            .where((call) => call.method == 'attachments.prepare')
            .single
            .params,
        {'id': 'recovery-file', 'sessionId': runtime.timelines.keys.single},
      );
      expect(runtime.prompts, 0);
      expect(find.byType(ComposerCommands), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retrying a failed menu only reloads its catalog until a command is picked',
    (tester) async {
      phone(tester);
      final runtime = _Runtime()..failCatalog = true;
      addTearDown(runtime.dispose);
      await tester.pumpWidget(host(ChatPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '保留这段草稿');
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重新读取'));
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(find.textContaining('命令目录不可用'), findsOneWidget);
      expect(runtime.prompts, 0);
      expect(
        runtime.calls.where((call) => call.method == 'session.command'),
        isEmpty,
      );

      runtime.failCatalog = false;
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(find.text('配置模型与凭据'), findsNothing);
      expect(find.textContaining('命令目录不可用'), findsNothing);
      expect(runtime.prompts, 0);
      expect(
        runtime.calls.where((call) => call.method == 'session.command'),
        isEmpty,
      );
      expect(
        runtime.calls.where(
          (call) =>
              call.method == 'api.call' &&
              call.params['namespace'] == 'commands' &&
              call.params['method'] == 'list',
        ),
        hasLength(3),
      );
      await tester.ensureVisible(find.text('压缩  compact'));
      await tester.tap(find.text('压缩  compact'));
      await tester.pumpAndSettle();
      expect(
        runtime.calls
            .where((call) => call.method == 'session.command')
            .single
            .params['line'],
        '/compact',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留这段草稿',
      );
      expect(runtime.prompts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final failCreation in [false, true]) {
    testWidgets(
      'typed command survives repeated ${failCreation ? 'Agent creation' : 'catalog'} failure and retries as a command',
      (tester) async {
        phone(tester);
        final runtime = _RecoveryRuntime()
          ..failEnsure = failCreation
          ..failCatalog = !failCreation;
        addTearDown(runtime.dispose);
        await tester.pumpWidget(host(ChatPage(runtime: runtime)));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '/计划 off');
        for (var attempt = 0; attempt < 2; attempt++) {
          await tester.tap(find.byTooltip('发送'));
          await tester.pumpAndSettle();
          expect(runtime.prompts, 0);
          expect(
            runtime.calls.where((call) => call.method == 'session.command'),
            isEmpty,
          );
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            '/计划 off',
          );
        }
        runtime
          ..failEnsure = false
          ..failCatalog = false;
        await tester.tap(find.byTooltip('发送'));
        await tester.pumpAndSettle();
        final executed = runtime.calls
            .where((call) => call.method == 'session.command')
            .single;
        expect(executed.params['line'], '/plan off');
        expect(executed.params['sessionId'], runtime.timelines.keys.single);
        expect(runtime.prompts, 0);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('typed aliases follow definition identity and bare-only commands do not claim arguments', () {
    expect(typedComposerCommand('/计划 off', catalog)?.line, '/plan off');
    expect(typedComposerCommand('/压缩', catalog)?.line, '/compact');
    expect(typedComposerCommand('/compact explain this', catalog), isNull);
    expect(typedComposerCommand('/unknown text', catalog), isNull);
    expect(
      typedComposerCommand('/目标 text', [
        {'name': 'goal', 'definitionId': 'other/plugin', 'input': {}},
      ]),
      isNull,
    );
    expect(
      typedComposerCommand('/goal text', [
        {'name': 'goal', 'definitionId': 'other/plugin', 'input': {}},
      ])?.line,
      '/goal text',
    );
  });

  testWidgets(
    'typed commands execute canonically and an unavailable directory never silently prompts',
    (tester) async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(host(ChatPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '/压缩');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(runtime.calls.last.params['line'], '/compact');
      expect(runtime.prompts, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      runtime.failCatalog = true;
      await tester.enterText(find.byType(TextField), '/计划 off');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(runtime.prompts, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '/计划 off',
      );
      expect(find.textContaining('命令目录不可用'), findsOneWidget);
      runtime.failCatalog = false;
      await tester.enterText(
        find.byType(TextField),
        '/not-a-command please explain',
      );
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(runtime.prompts, 1);
    },
  );

  testWidgets(
    'paired command history keeps recorded input without inventing omitted arguments',
    (tester) async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(host(ChatPage(runtime: runtime)));
      runtime.timelines.values.single.addAll([
        {
          'seq': 1,
          'type': 'command/run',
          'data': {'commandId': 'one', 'name': 'goal', 'args': ' 整理项目'},
        },
        {
          'seq': 2,
          'type': 'command/done',
          'data': {'commandId': 'one', 'kind': 'success', 'text': '目标已保存'},
        },
        {
          'seq': 3,
          'type': 'command/run',
          'data': {'commandId': 'two', 'name': 'feedback'},
        },
      ]);
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('/goal 整理项目'), findsOneWidget);
      expect(find.text('目标已保存', findRichText: true), findsWidgets);
      expect(find.text('/feedback'), findsOneWidget);
      expect(find.text('指令执行中…', findRichText: true), findsWidgets);
      expect(find.text('会话指令'), findsNothing);
    },
  );

  test('catalog ordering matches DSH while overridden commands keep their plugin face', () {
    final rows = composerCommandRows(catalog);
    expect(rows.map((row) => row['name']), [
      'file',
      'goal',
      'plan',
      'feedback',
      'compact',
      'permission',
      'model',
      'export',
      'plugin-command',
    ]);
    expect(rows.take(4).map((row) => row['section']).toSet(), {'添加'});
    expect(
      commandLabel({'name': 'goal', 'definitionId': 'example/plugin'}),
      'goal',
    );
    expect(
      commandDescription({
        'name': 'goal',
        'definitionId': 'example/plugin',
        'description': 'Plugin goal',
      }),
      'Plugin goal',
    );
    expect(
      () => composerCommandRows([
        {'name': 'file'},
      ]),
      throwsFormatException,
    );
  });

  testWidgets(
    'plus shows original commands and file opens the attachment picker',
    (tester) async {
      phone(tester);
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final native = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          if (call.method == 'notifications.viewing') return null;
          native.add(call.method);
          return jsonEncode({
            'items': [
              {
                'id': 'picked-1',
                'name': 'report.txt',
                'bytes': 5,
                'mediaType': 'text/plain',
              },
            ],
          });
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(host(ChatPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();
      expect(find.text('目标  goal'), findsOneWidget);
      expect(find.text('计划  plan'), findsOneWidget);
      await tester.tap(find.text('文件  file'));
      await tester.pumpAndSettle();
      expect(native, ['attachment.pick']);
      expect(
        runtime.calls
            .where((call) => call.method == 'attachments.prepare')
            .single
            .params['sessionId'],
        runtime.timelines.keys.single,
      );
      expect(find.text('report.txt'), findsOneWidget);
      expect(find.byType(ComposerCommands), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'goal opens its dedicated management page without submitting a chat command',
    (tester) async {
      phone(tester);
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(host(ChatPage(runtime: runtime)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('目标  goal'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatGoalPage), findsOneWidget);
      expect(runtime.prompts, 0);
      expect(
        runtime.calls.any((call) => call.method == 'session.command'),
        isFalse,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(ComposerCommandChip), findsNothing);
    },
  );

  testWidgets(
    'modal menu stays inside safe area and preserves composer with keyboard and enlarged text',
    (tester) async {
      phone(tester);
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(host(ChatPage(runtime: runtime), scale: 1.5));
      await tester.enterText(find.byType(TextField), '一\n二\n三\n四\n五');
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加与指令'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The popup owns taps until dismissed; the composer keeps its geometry.
      expect(
        tester.getRect(find.byTooltip('发送', skipOffstage: false)).bottom,
        lessThanOrEqualTo(480),
      );
      expect(
        tester.getRect(find.byType(ComposerCommands)).top,
        greaterThanOrEqualTo(
          tester.view.padding.top / tester.view.devicePixelRatio,
        ),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byTooltip('发送').hitTestable(), findsOneWidget);
      expect(find.byTooltip('打开侧栏').hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'session model applies its own session without changing the new-chat default',
    (tester) async {
      phone(tester);
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      final defaultModel = runtime.model;
      await tester.pumpWidget(
        host(SessionModelPage(runtime: runtime, sessionId: 'session-A')),
      );
      await tester.pumpAndSettle();
      final modelTwo = find.byKey(
        const ValueKey('session-model-provider-fixture-two'),
      );
      await tester.ensureVisible(modelTwo);
      await tester.tap(modelTwo);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('apply-session-model')));
      await tester.pumpAndSettle();
      final request = runtime.calls
          .lastWhere(
            (call) =>
                call.method == 'api.call' &&
                call.params['method'] == 'selectModel',
          )
          .params['args']['request'];
      expect(request, {
        'sessionId': 'session-A',
        'provider': 'provider-fixture',
        'model': 'two',
      });
      expect(runtime.model, defaultModel);
      expect(find.textContaining('已应用。此会话的后续请求'), findsOneWidget);
    },
  );

  testWidgets(
    'permission selection reads the current projection and retains the original full-access confirmation',
    (tester) async {
      final runtime = _Runtime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        host(
          SessionPermissionPage(
            runtime: runtime,
            sessionId: 'one',
            command: catalog.firstWhere((row) => row['name'] == 'permission'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.tap(find.text('完全权限'));
      await tester.pumpAndSettle();
      expect(
        runtime.calls.where((call) => call.method == 'session.command'),
        isEmpty,
      );
      await tester.ensureVisible(find.text('我已了解风险，并愿意继续'));
      await tester.tap(find.text('我已了解风险，并愿意继续'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('启用'));
      await tester.tap(find.text('启用'));
      await tester.pumpAndSettle();
      expect(
        runtime.calls
            .where((call) => call.method == 'session.command')
            .single
            .params['line'],
        '/permission danger-full-access',
      );
      expect(runtime.prompts, 0);
    },
  );

  testWidgets(
    'saved file attachments and original command results remain visible in history',
    (tester) async {
      final projection = ChatProjection()
        ..reconcile([
          {
            'seq': 0,
            'time': 0,
            'type': 'user/message',
            'surfaceOp': 'append',
            'data': {
              'id': 'saved-file',
              'role': 'user',
              'source': {'kind': 'user'},
              'content': [
                {
                  'type': 'file',
                  'attachment': {
                    'attachmentId': 'hash',
                    'name': 'report.txt',
                    'bytes': 5,
                  },
                },
              ],
            },
          },
          {
            'seq': 1,
            'time': 1,
            'type': 'command/done',
            'data': {'commandId': 'id', 'kind': 'success', 'text': '原命令的结果'},
          },
        ]);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        host(
          PocketScaffold(
            title: const Text('会话'),
            body: ChatTimeline(
              sessionId: 'saved-session',
              projection: projection,
              controller: scroll,
            ),
          ),
        ),
      );
      expect(find.text('report.txt'), findsOneWidget);
      expect(find.text('原命令的结果', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
