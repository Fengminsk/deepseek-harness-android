// B1：远程会话页的「+」弹层（数据驱动指令目录）。
//
// 菜单数据源是电脑上的 `commands.list`；这些测试用
// `test/support/remote_conversation_fakes.dart` 的假数据源驱动目录，覆盖：
// 调用面（`RemoteComposerCommandSurface`）的请求形状、打开即读目录与分组、
// 宿主指令执行、计划模式入口、置灰原因、目录读失败可重试、`api.call` 不支持时
// `+` 置灰。不连宿主、不拨号。

import 'package:dsh_android/chat_plan.dart';
import 'package:dsh_android/composer_commands.dart';
import 'package:dsh_android/remote_commands.dart';
import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_dsh_conversation.dart';
import 'package:dsh_android/remote_dsh_widgets.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection_test.dart' as fixture;
import 'support/remote_conversation_fakes.dart';

Widget _host(RemoteConversationSource source) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: RemoteDshConversationPage(
    source: source,
    deviceName: '客厅的电脑',
    projectName: 'Pocket',
    title: '修复登录',
  ),
);

RemoteConversationWindow _window() {
  final events = <Map<String, dynamic>>[
    fixture.input(0, '你好'),
    fixture.assistant(1, '你好，我在。'),
  ];
  return RemoteConversationWindow(
    events: events,
    throughSeq: events.last['seq'] as int,
    firstSeq: events.first['seq'] as int,
  );
}

FakeRemoteConversationSource _source({
  Set<String>? supported,
  RemoteConnectionPhase phase = RemoteConnectionPhase.ready,
}) => FakeRemoteConversationSource(
  window: _window(),
  supported: supported,
  phase: phase,
);

/// 打开「+」弹层并等待目录读取完成。
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('添加与指令'));
  await tester.pumpAndSettle();
}

void main() {
  test('调用面投影连接阶段并在读目录前先恢复会话', () async {
    final source = _source();
    final surface = RemoteComposerCommandSurface(source);
    expect(surface.ready, isTrue);

    source.phase = RemoteConnectionPhase.connecting;
    expect(surface.ready, isFalse);
    source.phase = RemoteConnectionPhase.ready;

    final catalog = await loadComposerCatalog(surface, source.sessionId);
    expect(catalog.map((row) => row['name']), <String>[
      'plan',
      'compact',
      'export',
    ]);
    expect(source.ensureCalls, 1, reason: '先 session.ensure 再读目录');
    final request = source.requests.single;
    expect(request.method, 'api.call');
    expect(request.params, {
      'namespace': 'commands',
      'method': 'list',
      'args': {'agentId': 's-1'},
    });
  });

  test('调用面拒绝为另一个会话恢复', () async {
    final source = _source();
    final surface = RemoteComposerCommandSurface(source);
    expect(
      () => surface.ensureSession('other-session'),
      throwsA(isA<StateError>()),
    );
    expect(source.ensureCalls, 0);
  });

  test('调用面的 call 原样转发门面方法', () async {
    final source = _source();
    source.answers['settings.describe'] = (_) => <String, dynamic>{'ok': true};
    final surface = RemoteComposerCommandSurface(source);
    expect(await surface.call('settings.describe'), {'ok': true});
    expect(source.requests.single.method, 'settings.describe');
    expect(source.requests.single.params, isEmpty);
  });

  testWidgets('「+」打开即读电脑上的指令目录，分组与本地一致', (tester) async {
    final source = _source();
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();
    expect(source.ensureCalls, 0, reason: '未打开菜单不读目录');

    await _openMenu(tester);

    expect(source.ensureCalls, 1);
    expect(find.byType(ComposerCommands), findsOneWidget);
    // 分组与本地一致：客户端动作与宿主指令都在「添加 / 指令」里。
    expect(find.text('添加'), findsOneWidget);
    expect(find.text('指令'), findsOneWidget);
    // 添加分组：文件（客户端动作）与计划（宿主指令）。
    expect(find.text('文件  file'), findsOneWidget);
    expect(find.text('计划  plan'), findsOneWidget);
    // 指令分组：压缩与模型（客户端动作）。
    expect(find.text('压缩  compact'), findsOneWidget);
    expect(find.text('模型  model'), findsOneWidget);
    expect(find.textContaining('压缩以上对话内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择宿主指令后作为 session.command 执行且保留输入草稿', (tester) async {
    final source = _source();
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '还没发出去的草稿');

    await _openMenu(tester);
    await tester.tap(find.text('压缩  compact'));
    await tester.pumpAndSettle();

    expect(source.commands, <String>['/compact']);
    expect(source.sent, isEmpty, reason: '宿主指令不进入模型对话');
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '还没发出去的草稿',
      reason: '从菜单执行指令不清空用户草稿',
    );
    expect(
      find.byKey(const ValueKey('remote-conversation-command-success')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择「计划」进入计划模式页而不是直接执行命令', (tester) async {
    final source = _source();
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.text('计划  plan'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPlanModePage), findsOneWidget);
    expect(source.commands, isEmpty, reason: '开关由计划模式页自己的按钮触发');
    expect(source.projectionReads, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择「模型」打开既有模型目录弹层', (tester) async {
    final source = _source();
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.text('模型  model'));
    await tester.pumpAndSettle();

    expect(source.catalogFetches, 1);
    expect(find.text('DeepSeek 账号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出与技能置灰并写明原因，点击不执行', (tester) async {
    final source = _source();
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await _openMenu(tester);
    expect(find.text('下载日志  export'), findsOneWidget);
    expect(find.text('远程会话暂不支持导出到手机，请在电脑上导出'), findsOneWidget);
    expect(find.text('浏览技能'), findsOneWidget);
    expect(find.text('远程会话暂不支持浏览技能'), findsOneWidget);

    await tester.tap(find.text('下载日志  export'));
    await tester.pumpAndSettle();
    expect(find.byType(ComposerCommands), findsOneWidget);
    expect(source.commands, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('需要输入的宿主指令插入草稿等待补参数', (tester) async {
    final source = _source();
    source.answers['api.call'] = (params) => <Map<String, dynamic>>[
      {
        'name': 'permission',
        'definitionId': '@deepseek-ai/dsh-permission-presets',
        'description': '切换权限预设',
        'input': {'hint': '<preset>'},
      },
    ];
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.text('权限  permission'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, '/permission ');
    expect(source.commands, isEmpty, reason: '参数还没补全，不执行');
    expect(
      find.byKey(const ValueKey('remote-command-hint')),
      findsOneWidget,
      reason: '输入以 / 开头时给出「在电脑上执行」的说明',
    );
  });

  testWidgets('目录读取失败时弹层可重试，重试后显示指令', (tester) async {
    final source = _source();
    var fail = true;
    source.answers['api.call'] = (params) {
      if (fail) {
        throw const RuntimeTransportFailure(
          code: 'gateway/unavailable',
          message: '电脑暂时读不到指令目录。',
        );
      }
      return defaultRemoteCommandCatalog;
    };
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await _openMenu(tester);
    expect(find.text('会话菜单暂不可用'), findsOneWidget);
    expect(find.textContaining('电脑暂时读不到指令目录'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();

    expect(find.text('计划  plan'), findsOneWidget);
    expect(find.textContaining('电脑暂时读不到指令目录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('api.call 不支持时「+」置灰并说明原因', (tester) async {
    final source = _source(
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
        remoteConversationCommandMethod,
      },
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    final composer = tester.widget<RemoteComposer>(find.byType(RemoteComposer));
    expect(composer.onAdd, isNull, reason: '不支持时不给一个点了没反应的入口');
    expect(
      find.byKey(const ValueKey('remote-composer-menu-unavailable')),
      findsOneWidget,
    );
    expect(find.text('这台电脑不支持会话指令与添加菜单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
