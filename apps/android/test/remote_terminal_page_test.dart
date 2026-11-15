// 远程终端 App 侧测试：远端调用面、Shell 来源、入口三态与页面复用。
//
// 全部用假传输/假连接驱动，不连宿主、不拨号；本地终端页面的既有行为由
// test/terminal_screen_test.dart 继续覆盖。

import 'dart:async';

import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_terminal_page.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:dsh_android/session_terminal.dart';
import 'package:dsh_android/terminal_runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/remote_terminal_fakes.dart';

/// 用 Pocket 主题挂载一个页面，与真实 App 的视觉/路由环境一致。
Widget hostPage(Widget page) =>
    MaterialApp(theme: pocketTheme(Brightness.dark), home: page);

/// 推进一帧并走完 PocketRoute 的 450 ms 转场。
///
/// 终端视图里有 450 ms 轮询定时器，pumpAndSettle 会一直有下一帧；这里用固定
/// 时长推进到转场结束，再补一帧。
Future<void> settleRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

void main() {
  test('目的地标识稳定，且页面以该标识作为路由名', () {
    expect(
      RemoteSessionTerminalPage.routeDestination,
      'remote-session-terminal',
    );
    expect(
      destinationRouteName(RemoteSessionTerminalPage.routeDestination),
      'dsh-destination:remote-session-terminal',
    );
  });

  test('能力三态把「未连上」与「明确不支持」分开', () {
    final transport = FakeTerminalTransport();
    final connection = FakeRemoteTerminalConnection(transport: transport);

    expect(
      RemoteTerminalCapability.of(connection),
      RemoteTerminalCapability.available,
    );
    expect(RemoteTerminalCapability.available.reason, isNull);

    // 任务栏里还没有连上：pending，不是「不支持」。
    connection.setPhase(RemoteConnectionPhase.connecting);
    expect(
      RemoteTerminalCapability.of(connection),
      RemoteTerminalCapability.pending,
    );
    expect(RemoteTerminalCapability.pending.reason, '正在连接电脑…');

    // 阶段已 ready 但传输还没挂上：仍按 pending 处理，避免误判为永久不支持。
    connection.transport = null;
    connection.setPhase(RemoteConnectionPhase.ready);
    expect(
      RemoteTerminalCapability.of(connection),
      RemoteTerminalCapability.pending,
    );

    // 任一必需方法缺失即整条入口不可用（取最弱一环）。
    connection.transport = transport;
    connection.supportedMethods.remove('terminal.write');
    expect(
      RemoteTerminalCapability.of(connection),
      RemoteTerminalCapability.unsupported,
    );
    expect(RemoteTerminalCapability.unsupported.reason, '这台电脑不支持终端');
  });

  test('RemoteTerminalRuntime 为每个 terminal.* 方法补 sessionId', () async {
    final transport = FakeTerminalTransport();
    final connection = FakeRemoteTerminalConnection(transport: transport);
    final runtime = RemoteTerminalRuntime(
      connection: connection,
      sessionId: 'session-9',
    );
    addTearDown(runtime.dispose);

    await runtime.call('terminal.list');
    await runtime.call('terminal.shells');
    await runtime.call('terminal.create', <String, dynamic>{
      'id': 't-1',
      'cols': 80,
      'rows': 24,
      'shellId': '/bin/bash',
    });
    await runtime.call('terminal.read', <String, dynamic>{'id': 't-1'});
    await runtime.call('terminal.write', <String, dynamic>{
      'id': 't-1',
      'data': 'ls\r',
    });
    await runtime.call('terminal.resize', <String, dynamic>{
      'id': 't-1',
      'cols': 100,
      'rows': 30,
    });
    await runtime.call('terminal.rename', <String, dynamic>{
      'id': 't-1',
      'name': '新终端',
    });
    await runtime.call('terminal.close', <String, dynamic>{'id': 't-1'});

    expect(transport.methods, <String>[
      'terminal.list',
      'terminal.shells',
      'terminal.create',
      'terminal.read',
      'terminal.write',
      'terminal.resize',
      'terminal.rename',
      'terminal.close',
    ]);
    expect(transport.paramsOf('terminal.list').single, <String, dynamic>{
      'sessionId': 'session-9',
    });
    expect(transport.paramsOf('terminal.create').single, <String, dynamic>{
      'sessionId': 'session-9',
      'id': 't-1',
      'cols': 80,
      'rows': 24,
      'shellId': '/bin/bash',
    });
    expect(transport.paramsOf('terminal.read').single, <String, dynamic>{
      'sessionId': 'session-9',
      'id': 't-1',
    });
    expect(transport.paramsOf('terminal.write').single, <String, dynamic>{
      'sessionId': 'session-9',
      'id': 't-1',
      'data': 'ls\r',
    });
    expect(transport.paramsOf('terminal.resize').single, <String, dynamic>{
      'sessionId': 'session-9',
      'id': 't-1',
      'cols': 100,
      'rows': 30,
    });
    expect(transport.paramsOf('terminal.rename').single, <String, dynamic>{
      'sessionId': 'session-9',
      'id': 't-1',
      'name': '新终端',
    });
    expect(transport.paramsOf('terminal.close').single, <String, dynamic>{
      'sessionId': 'session-9',
      'id': 't-1',
    });
  });

  test('RemoteTerminalRuntime 把错误信封换成页面可捕获的 PlatformException', () async {
    final transport = FakeTerminalTransport();
    final connection = FakeRemoteTerminalConnection(transport: transport);
    final runtime = RemoteTerminalRuntime(
      connection: connection,
      sessionId: 'session-9',
    );
    addTearDown(runtime.dispose);

    // 传输层已经把 `_pocket_error` 解成 RuntimeTransportFailure 的常规路径。
    transport.failures['terminal.write'] = const RuntimeTransportFailure(
      code: 'terminal/control-unavailable',
      message: '终端只读。',
      details: <String, dynamic>{
        'code': 'terminal/control-unavailable',
        'message': '终端只读。',
        'details': <String, dynamic>{'reason': 'read-only'},
      },
    );
    await expectLater(
      runtime.call('terminal.write', <String, dynamic>{'id': 't-1'}),
      throwsA(
        isA<PlatformException>()
            .having(
              (failure) => failure.code,
              'code',
              'terminal/control-unavailable',
            )
            .having((failure) => failure.message, 'message', '终端只读。'),
      ),
    );

    // 传输实现把错误信封原样返回时，同样换成 PlatformException。
    transport.answers['terminal.read'] = (_) => <String, dynamic>{
      '_pocket_error': <String, dynamic>{
        'code': 'terminal/unavailable',
        'message': '终端已不存在。',
      },
    };
    await expectLater(
      runtime.call('terminal.read', <String, dynamic>{'id': 't-1'}),
      throwsA(
        isA<PlatformException>().having(
          (failure) => failure.code,
          'code',
          'terminal/unavailable',
        ),
      ),
    );
  });

  test('连接代际只在重新握手或换传输时递增', () async {
    final transport = FakeTerminalTransport();
    final connection = FakeRemoteTerminalConnection(transport: transport);
    final runtime = RemoteTerminalRuntime(
      connection: connection,
      sessionId: 'session-9',
    );
    addTearDown(runtime.dispose);

    expect(runtime.ready, isTrue);
    expect(runtime.phase, 'ready');
    expect(runtime.connectionGeneration, 0);

    connection.setPhase(RemoteConnectionPhase.reconnecting);
    expect(runtime.ready, isFalse);
    expect(runtime.connectionGeneration, 0, reason: '断线期间不递增，页面按 ready 置待确认');

    connection.setPhase(RemoteConnectionPhase.ready);
    expect(runtime.connectionGeneration, 1, reason: '重新握手成功即新代际');

    connection.transport = FakeTerminalTransport();
    connection.setPhase(RemoteConnectionPhase.ready);
    expect(runtime.connectionGeneration, 2, reason: '换了一条传输也是新代际');

    connection.setPhase(RemoteConnectionPhase.lost, lastError: '连接已断开。');
    expect(runtime.ready, isFalse);
    await expectLater(
      runtime.call('terminal.list'),
      throwsA(
        isA<PlatformException>().having(
          (failure) => failure.code,
          'code',
          'gateway/cancelled',
        ),
      ),
    );
  });

  test('RemoteTerminalShellSource 读取 PC shell 列表，偏好只留在内存', () async {
    final transport = FakeTerminalTransport()
      ..answers['terminal.shells'] = (_) => terminalShells();
    final connection = FakeRemoteTerminalConnection(transport: transport);
    final runtime = RemoteTerminalRuntime(
      connection: connection,
      sessionId: 'session-9',
    );
    addTearDown(runtime.dispose);
    final source = RemoteTerminalShellSource(runtime);

    final shells = await source.discover();
    expect(shells, const <TerminalShellOption>[
      TerminalShellOption(id: '/bin/bash', label: 'bash'),
      TerminalShellOption(id: '/bin/zsh', label: 'zsh'),
    ]);
    expect(transport.paramsOf('terminal.shells').single, <String, dynamic>{
      'sessionId': 'session-9',
    });

    expect(
      await source.preferred(),
      const TerminalShellOption(id: '/bin/bash', label: 'bash'),
      reason: '没有偏好时取列表首项',
    );
    await source.remember(
      const TerminalShellOption(id: '/bin/zsh', label: 'zsh'),
    );
    expect(
      await source.preferred(),
      const TerminalShellOption(id: '/bin/zsh', label: 'zsh'),
      reason: '偏好优先，且不再发请求',
    );
    expect(transport.paramsOf('terminal.shells').length, 2);

    // 空列表：没有默认 Shell，创建入口由页面报「没有可用的 Shell」。
    transport.answers['terminal.shells'] = (_) => <Map<String, dynamic>>[];
    expect(await RemoteTerminalShellSource(runtime).preferred(), isNull);

    // 形状不合法：id/label 必须是非空字符串且不能重复。
    transport.answers['terminal.shells'] = (_) => <Map<String, dynamic>>[
      <String, dynamic>{'id': 1, 'label': 'bash'},
    ];
    await expectLater(
      RemoteTerminalShellSource(runtime).discover(),
      throwsFormatException,
    );
    transport.answers['terminal.shells'] = (_) => <Map<String, dynamic>>[
      terminalShells().first,
      terminalShells().first,
    ];
    await expectLater(
      RemoteTerminalShellSource(runtime).discover(),
      throwsFormatException,
    );
  });

  test('terminalFailureMessage 只翻译已归因的终端错误', () {
    expect(terminalFailureMessage(StateError('boom')), isNull);
    expect(
      terminalFailureMessage(
        PlatformException(code: 'gateway/internal', message: '内部错误'),
      ),
      isNull,
    );
    expect(
      terminalFailureMessage(
        PlatformException(code: 'terminal/unavailable', message: '不存在'),
      ),
      '终端已不存在，请返回终端列表刷新。',
    );
    expect(
      terminalFailureMessage(
        PlatformException(
          code: 'terminal/control-unavailable',
          message: '只能看',
          details: <String, dynamic>{
            'details': <String, dynamic>{'reason': 'read-only'},
          },
        ),
      ),
      contains('只读'),
    );
    expect(
      terminalFailureMessage(
        PlatformException(
          code: 'terminal/control-unavailable',
          message: '已结束',
          details: <String, dynamic>{
            'details': <String, dynamic>{'reason': 'not-running'},
          },
        ),
      ),
      contains('进程已结束'),
    );
    expect(
      terminalFailureMessage(
        PlatformException(
          code: 'terminal/limit-reached',
          message: 'limit',
          details: <String, dynamic>{
            'details': <String, dynamic>{'limit': 8},
          },
        ),
      ),
      contains('8'),
    );
    expect(
      terminalFailureMessage(
        PlatformException(
          code: 'terminal/control-unavailable',
          message: '只能看',
          details: <String, dynamic>{'reason': 'read-only'},
        ),
      ),
      contains('只读'),
      reason: '错误对象直接就是内层 details 时也要能翻译',
    );
  });

  testWidgets('未就绪时展示连接原因，连上后自动挂载本地终端页', (tester) async {
    final transport = FakeTerminalTransport()
      ..answers['terminal.list'] = (_) => <Map<String, dynamic>>[
        terminalInfo(),
      ];
    final connection = FakeRemoteTerminalConnection(
      phase: RemoteConnectionPhase.connecting,
    );
    await tester.pumpWidget(
      hostPage(
        RemoteSessionTerminalPage(
          connection: connection,
          sessionId: 'session-7',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('正在连接电脑'), findsOneWidget);
    expect(find.byType(SessionTerminalsPage), findsNothing);

    connection.transport = transport;
    connection.setPhase(RemoteConnectionPhase.ready);
    await tester.pump();
    await tester.pump();
    expect(find.byType(SessionTerminalsPage), findsOneWidget);
    expect(find.text('构建终端'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('电脑未声明 terminal.* 时展示不支持原因而不是死页面', (tester) async {
    final connection = FakeRemoteTerminalConnection(
      transport: FakeTerminalTransport(),
      supported: <String>{},
    );
    await tester.pumpWidget(
      hostPage(
        RemoteSessionTerminalPage(
          connection: connection,
          sessionId: 'session-7',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('这台电脑不支持终端'), findsOneWidget);
    expect(find.textContaining('terminal.*'), findsOneWidget);
    expect(find.byType(SessionTerminalsPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('远程终端页复用本地视图：轮询读取、写入、缩放与关闭都按冻结参数发请求', (tester) async {
    final transport = FakeTerminalTransport();
    var revision = 0;
    transport.answers['terminal.list'] = (_) => <Map<String, dynamic>>[
      terminalInfo(),
    ];
    transport.answers['terminal.read'] = (_) =>
        terminalRead(revision: ++revision);
    transport.answers['terminal.write'] = (_) => <String, dynamic>{
      'accepted': true,
    };
    transport.answers['terminal.resize'] = (params) => <String, dynamic>{
      'cols': params['cols'],
      'rows': params['rows'],
    };
    transport.answers['terminal.close'] = (_) => <String, dynamic>{
      'closed': true,
    };
    final connection = FakeRemoteTerminalConnection(transport: transport);
    await tester.pumpWidget(
      hostPage(
        RemoteSessionTerminalPage(
          connection: connection,
          sessionId: 'session-7',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal-terminal-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('terminal-terminal-1')));
    await settleRoute(tester);
    expect(transport.paramsOf('terminal.read').last, <String, dynamic>{
      'sessionId': 'session-7',
      'id': 'terminal-1',
    });

    // 轮询读取：450 ms 一次，直到页面销毁。
    final readsBeforePolling = transport.paramsOf('terminal.read').length;
    await tester.pump(const Duration(milliseconds: 460));
    await tester.pump(const Duration(milliseconds: 460));
    expect(
      transport.paramsOf('terminal.read').length,
      greaterThan(readsBeforePolling),
      reason: '远程终端沿用本地 450 ms 轮询节奏',
    );

    // 视口尺寸与宿主不同时自动 resize，参数与本地完全一致。
    await tester.pump(const Duration(milliseconds: 200));
    final resize = transport.paramsOf('terminal.resize').last;
    expect(resize['sessionId'], 'session-7');
    expect(resize['id'], 'terminal-1');
    expect(resize['cols'], isA<int>());
    expect(resize['rows'], isA<int>());

    // 草稿模式发送：write 参数是页面已确认的文本 + 回车。
    await tester.tap(find.text('实时输入'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'echo hi');
    await tester.tap(find.byTooltip('发送命令'));
    await tester.pump();
    await tester.pump();
    expect(transport.paramsOf('terminal.write').last, <String, dynamic>{
      'sessionId': 'session-7',
      'id': 'terminal-1',
      'data': 'echo hi\r',
    });

    // 关闭终端进程：close 参数与本地一致，成功后回到列表。
    await tester.tap(find.byTooltip('关闭终端进程'));
    await settleRoute(tester);
    expect(transport.paramsOf('terminal.close').last, <String, dynamic>{
      'sessionId': 'session-7',
      'id': 'terminal-1',
    });
    expect(find.byType(SessionTerminalView), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('远程新建终端使用 PC 的 shell 路径，重命名按 name 参数提交', (tester) async {
    final transport = FakeTerminalTransport();
    var name = '旧终端';
    transport.answers['terminal.list'] = (_) => <Map<String, dynamic>>[
      terminalInfo(name: name),
    ];
    transport.answers['terminal.shells'] = (_) => terminalShells();
    transport.answers['terminal.read'] = (_) => terminalRead(name: name);
    transport.answers['terminal.create'] = (_) => <String, dynamic>{
      'state': 'running',
    };
    transport.answers['terminal.rename'] = (params) {
      name = params['name'] as String;
      return terminalInfo(name: name);
    };
    transport.answers['terminal.close'] = (_) => <String, dynamic>{
      'closed': true,
    };
    final connection = FakeRemoteTerminalConnection(transport: transport);
    await tester.pumpWidget(
      hostPage(
        RemoteSessionTerminalPage(
          connection: connection,
          sessionId: 'session-7',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 新建：shellId 是 PC 上的 shell 路径；id 由 App 生成。
    await tester.tap(find.byTooltip('新建终端'));
    await settleRoute(tester);
    final create = transport.paramsOf('terminal.create').single;
    expect(create['sessionId'], 'session-7');
    expect(create['id'], startsWith('mobile-'));
    expect(create['cols'], isA<int>());
    expect(create['rows'], 24);
    expect(create['shellId'], '/bin/bash');
    expect(transport.paramsOf('terminal.shells'), isNotEmpty);

    // 从终端视图返回列表，再重命名。
    await tester.tap(find.byTooltip('关闭终端进程'));
    await settleRoute(tester);
    await tester.tap(find.byTooltip('重命名终端'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '新终端');
    await tester.tap(find.byTooltip('保存名称'));
    await tester.pump();
    await tester.pump();
    expect(transport.paramsOf('terminal.rename').single, <String, dynamic>{
      'sessionId': 'session-7',
      'id': 'terminal-1',
      'name': '新终端',
    });

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('断线重连后终端列表重新读取，连接代际递增', (tester) async {
    final transport = FakeTerminalTransport()
      ..answers['terminal.list'] = (_) => <Map<String, dynamic>>[
        terminalInfo(),
      ];
    final connection = FakeRemoteTerminalConnection(transport: transport);
    await tester.pumpWidget(
      hostPage(
        RemoteSessionTerminalPage(
          connection: connection,
          sessionId: 'session-7',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(transport.paramsOf('terminal.list').length, 1);

    connection.reconnect();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      transport.paramsOf('terminal.list').length,
      greaterThan(1),
      reason: '重新握手后列表页要重读，而不是停在断线前的旧结果',
    );
    expect(find.byKey(const ValueKey('terminal-terminal-1')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('只读拒绝走远端错误信封，页面展示可读原因', (tester) async {
    final transport = FakeTerminalTransport();
    var revision = 0;
    transport.answers['terminal.list'] = (_) => <Map<String, dynamic>>[
      terminalInfo(),
    ];
    transport.answers['terminal.read'] = (_) =>
        terminalRead(revision: ++revision);
    transport.failures['terminal.write'] = const RuntimeTransportFailure(
      code: 'terminal/control-unavailable',
      message: '终端只读。',
      details: <String, dynamic>{
        'code': 'terminal/control-unavailable',
        'message': '终端只读。',
        'details': <String, dynamic>{'reason': 'read-only'},
      },
    );
    final connection = FakeRemoteTerminalConnection(transport: transport);
    await tester.pumpWidget(
      hostPage(
        RemoteSessionTerminalPage(
          connection: connection,
          sessionId: 'session-7',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-terminal-1')));
    await settleRoute(tester);
    await tester.tap(find.text('实时输入'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'rm -rf /');
    await tester.tap(find.byTooltip('发送命令'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('只读'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('远程终端页用稳定目的地标识推入，栈顶识别与目的地约定一致', (tester) async {
    final transport = FakeTerminalTransport()
      ..answers['terminal.list'] = (_) => <Map<String, dynamic>>[
        terminalInfo(),
      ];
    final connection = FakeRemoteTerminalConnection(transport: transport);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open-remote-terminal'),
            onPressed: () => unawaited(
              openDestination<void>(
                context,
                destination: RemoteSessionTerminalPage.routeDestination,
                builder: (_) => RemoteSessionTerminalPage(
                  connection: connection,
                  sessionId: 'session-7',
                ),
              ),
            ),
            child: const Text('打开终端'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-remote-terminal')));
    await settleRoute(tester);
    final page = tester.element(find.byType(RemoteSessionTerminalPage));
    expect(
      ModalRoute.of(page)?.settings.name,
      destinationRouteName(RemoteSessionTerminalPage.routeDestination),
    );
    expect(
      isCurrentDestination(page, RemoteSessionTerminalPage.routeDestination),
      isTrue,
      reason: '再点同一入口时 openDestination 必须能认出栈顶就是本目的地',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
