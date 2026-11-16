// 远程会话页：假数据源下的渲染、发送、能力降级、失败态与重连快照。
//
// 这些测试不连宿主、不拨号：数据源是 `test/support/remote_conversation_fakes.dart`
// 里的 [FakeRemoteConversationSource]，因此可以在没有 PC 在线的情况下验证页面
// 的数据流。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/chat_plan.dart';
import 'package:dsh_android/pocket_composer.dart';
import 'package:dsh_android/remote_attachments.dart';
import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_conversation_live_source.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_dsh_conversation.dart';
import 'package:dsh_android/remote_dsh_widgets.dart';
import 'package:dsh_android/remote_permissions.dart';
import 'package:dsh_android/remote_session_insights.dart';
import 'package:dsh_android/remote_stats_bar.dart';
import 'package:dsh_android/remote_todo_card.dart';
import 'package:dsh_android/remote_workspace_diff_page.dart';
import 'package:dsh_android/runtime.dart';
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

RemoteConversationWindow _window(List<Map<String, dynamic>> events) =>
    RemoteConversationWindow(
      events: events,
      throughSeq: events.isEmpty ? 0 : events.last['seq'] as int,
      firstSeq: events.isEmpty ? null : events.first['seq'] as int,
    );

RemotePendingInteraction _approvalInteraction({
  String id = 'i-1',
  int version = 1,
}) => RemotePendingInteraction(
  id: id,
  version: version,
  sessionId: 's-1',
  kind: RemoteInteractionKind.approval,
  toolName: 'android_shell',
  summary: 'command: rm -rf build · cwd: C:/work',
  reason: '需要运行命令',
  callId: 'call-1',
);

RemotePendingInteraction _questionInteraction({bool single = false}) =>
    RemotePendingInteraction(
      id: 'i-q',
      version: 2,
      sessionId: 's-1',
      kind: RemoteInteractionKind.question,
      questions: single
          ? const <RemoteQuestion>[
              RemoteQuestion(
                id: 'q1',
                question: '用哪个包管理器？',
                options: <RemoteQuestionOption>[
                  RemoteQuestionOption(label: 'npm'),
                  RemoteQuestionOption(label: 'pnpm', description: '更快'),
                ],
              ),
            ]
          : const <RemoteQuestion>[
              RemoteQuestion(
                id: 'q1',
                question: '用哪个包管理器？',
                options: <RemoteQuestionOption>[
                  RemoteQuestionOption(label: 'npm'),
                  RemoteQuestionOption(label: 'pnpm', description: '更快'),
                ],
              ),
              RemoteQuestion(
                id: 'q2',
                question: '还需要做什么？',
                detail: '可以选择多项',
                multiSelect: true,
                options: <RemoteQuestionOption>[
                  RemoteQuestionOption(label: '格式化'),
                  RemoteQuestionOption(label: '测试'),
                ],
              ),
            ],
    );

/// 计划模式的 `session.projections` 返回。
Map<String, dynamic> _planProjections({
  required bool active,
  required bool pending,
  int asOfSeq = 1,
}) => <String, dynamic>{
  'kind': 'sequenced',
  'asOfSeq': asOfSeq,
  'values': <String, dynamic>{
    'plan': <String, dynamic>{'active': active, 'pending': pending},
  },
};

/// 一个计划审核提问：`intent.kind == 'plan-review'` 时页面渲染专属卡片。
RemotePendingInteraction _planReviewInteraction() =>
    const RemotePendingInteraction(
      id: 'i-plan',
      version: 3,
      sessionId: 's-1',
      kind: RemoteInteractionKind.question,
      questions: <RemoteQuestion>[
        RemoteQuestion(
          id: 'plan-q',
          question: '是否按这份计划执行？',
          detail: '# 迁移到新接口\n\n先改数据源，再改页面。',
          intent: <String, dynamic>{'kind': 'plan-review', 'approve': '批准'},
          options: <RemoteQuestionOption>[
            RemoteQuestionOption(label: '批准'),
            RemoteQuestionOption(label: '继续修改'),
          ],
        ),
      ],
    );

const RemoteModelChoice _flash = RemoteModelChoice(
  provider: 'deepseek-account',
  model: 'deepseek-flash',
);

/// 桌面创建、在只有账号凭据的电脑上不可用的路由：它的 provider 会出现在目录失败列表。
const RemoteModelChoice _official = RemoteModelChoice(
  provider: 'deepseek-official',
  model: 'deepseek-chat',
);

/// 声明了推理强度、当前选「高」的可调路由：输入区推理面板用它验证档位回显。
const RemoteModelChoice _v4ProHigh = RemoteModelChoice(
  provider: 'deepseek-account',
  model: 'deepseek-v4-pro',
  reasoningEffort: 'high',
);

/// 附件草稿的会话页测试用 id（小写 UUID v4，与 `attachment.pick` 生成规则一致）。
const String _attachmentId = '3f0b2f1c-6a1e-4b8e-9c2d-1a2b3c4d5e6f';

/// 模拟 `attachment.pick` 原生通道：返回一条固定选中项。
void _mockAttachmentPicker(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    RuntimeController.channel,
    (call) async => call.method == 'attachment.pick'
        ? jsonEncode(<String, dynamic>{
            'cancelled': false,
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': _attachmentId,
                'name': '季度报告.txt',
                'bytes': 12,
                'mediaType': 'text/plain',
              },
            ],
            'failures': <Object>[],
          })
        : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RuntimeController.channel,
      null,
    ),
  );
}

/// 远程宿主启用了权限预设时的 `runtime.permissions` 应答（桌面形状）。
Map<String, dynamic> _runtimePermissions({bool available = true}) =>
    <String, dynamic>{
      'shell': <String, dynamic>{
        'tool': 'desktop-host',
        'available': false,
        'reason': 'desktop-remote-host',
        'executionIdentity': null,
        'approval': 'unavailable',
        'workspaceConfinement': false,
      },
      'fileTools': <String, dynamic>{'sandboxMode': 'workspace-write'},
      'presets': <String, dynamic>{'available': available},
    };

/// `permissionPresets.catalog` 的真实形状（`PermissionCatalog`）。
Map<String, dynamic> _permissionCatalog() => <String, dynamic>{
  'options': <Map<String, dynamic>>[
    <String, dynamic>{
      'value': 'read-only',
      'name': 'read-only',
      'description': 'Read-only file access.',
    },
    <String, dynamic>{
      'value': 'workspace-write',
      'name': 'workspace-write',
      'description': 'Write inside the workspace.',
    },
    <String, dynamic>{
      'value': 'danger-full-access',
      'name': 'danger-full-access',
      'description': 'Full file access without approval prompts.',
    },
  ],
  'defaultPreset': 'workspace-write',
};

/// 带权限投影的 `session.projections` 返回。
Map<String, dynamic> _permissionProjections(String currentValue) =>
    <String, dynamic>{
      'kind': 'sequenced',
      'asOfSeq': 2,
      'values': <String, dynamic>{
        'permissions': <String, dynamic>{'currentValue': currentValue},
      },
    };

/// 以「电脑启用了权限预设」为前提的会话页数据源：探测、目录与切换都走假应答。
FakeRemoteConversationSource _permissionSource({
  String current = 'workspace-write',
  bool available = true,
  List<RemotePendingInteraction> interactions =
      const <RemotePendingInteraction>[],
}) {
  final source = FakeRemoteConversationSource(
    window: _window(conversationEvents()),
    interactions: interactions,
    supported: <String>{
      remoteConversationReadMethod,
      remoteConversationSendMethod,
      remoteConversationCommandMethod,
      remoteConversationApiCallMethod,
      remoteConversationInteractionsListMethod,
      remoteConversationInteractionsReplyMethod,
      remotePermissionRuntimeMethod,
    },
  );
  source.answers[remotePermissionRuntimeMethod] = (_) =>
      _runtimePermissions(available: available);
  source.answers['api.call'] = (params) {
    if (params['namespace'] == 'permissionPresets' &&
        params['method'] == 'catalog') {
      return _permissionCatalog();
    }
    return <String, dynamic>{};
  };
  source.answers['session.command'] = (params) {
    final value = '${params['line']}'.split(' ').last;
    source.projections = _permissionProjections(value);
    return <String, dynamic>{
      'commandId': 'command-1',
      'result': <String, dynamic>{'kind': 'success', 'text': 'preset $value'},
    };
  };
  source.projections = _permissionProjections(current);
  return source;
}

void main() {
  testWidgets('假数据源的首屏窗口按既有对话内核渲染', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.text('修复登录'), findsOneWidget);
    expect(find.text('客厅的电脑 · Pocket'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    expect(find.textContaining('你好，我在。', findRichText: true), findsWidgets);
    expect(source.starts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入条提交走 session.send 并在受理后清空输入', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  再检查一次构建  ');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('remote-send')),
      findsOneWidget,
      reason: '有草稿时应出现发送按钮',
    );

    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.sent, ['再检查一次构建']);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty, reason: '受理成功后输入框应清空');
    expect(
      find.byKey(const ValueKey('remote-send')),
      findsNothing,
      reason: '清空后发送按钮收起',
    );
  });

  testWidgets('宿主不支持 session.send 时输入区置灰并给出可见原因', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      supported: <String>{remoteConversationReadMethod},
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-conversation-send-unsupported')),
      findsOneWidget,
    );
    expect(find.textContaining('这台电脑不支持发送消息'), findsWidgets);
    expect(
      tester.widget<RemoteComposer>(find.byType(RemoteComposer)).enabled,
      isFalse,
    );
    expect(find.byKey(const ValueKey('remote-send')), findsNothing);
    expect(source.sent, isEmpty);
  });

  testWidgets('失败态展示 lastError，并可重新连接同一台电脑', (tester) async {
    final source = FakeRemoteConversationSource(
      phase: RemoteConnectionPhase.failed,
      lastError: '这台手机已被电脑撤销授权。请在电脑上重新配对。',
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-conversation-failed')),
      findsOneWidget,
    );
    expect(find.textContaining('这台手机已被电脑撤销授权'), findsOneWidget);

    await tester.tap(find.text('重新连接'));
    await tester.pumpAndSettle();
    expect(source.retries, 1);
  });

  testWidgets('重连后按新窗口整体替换，且不重起数据源', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window([fixture.input(0, '第一次提问'), fixture.assistant(1, '回复一')]),
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();
    expect(find.textContaining('回复一', findRichText: true), findsWidgets);

    source.setPhase(RemoteConnectionPhase.reconnecting);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('remote-conversation-connecting')),
      findsOneWidget,
    );

    // 重连就绪后数据源会先重读窗口、再重新订阅；页面因此收到一个整体替换的快照。
    source.window = _window([fixture.assistant(5, '回复二')]);
    source.setPhase(RemoteConnectionPhase.ready);
    source.emit(RemoteConversationSnapshot(source.window!));
    await tester.pumpAndSettle();

    expect(find.textContaining('回复二', findRichText: true), findsWidgets);
    expect(
      find.textContaining('回复一', findRichText: true),
      findsNothing,
      reason: '快照语义是整体替换，不是追加',
    );
    expect(source.starts, 1, reason: '重连由数据源内部重建，页面不重新 start');
    expect(
      find.byKey(const ValueKey('remote-conversation-connecting')),
      findsNothing,
    );
  });

  testWidgets('页面加载、一轮结束与重连后都会刷新会话洞察', (tester) async {
    // 用真实数据源把页面生命周期接到假传输上：洞察由数据源自己决定刷新时机，
    // 页面只负责持有状态，因此这里断言的是「页面驱动下真的发生了重读」。
    final transport = FakeRemoteTransport();
    var projectionReads = 0;
    transport.answers['session.readWindow'] = (_) => <String, dynamic>{
      'events': <Map<String, dynamic>>[
        fixture.header(0),
        fixture.input(1, '你好'),
      ],
      'throughSeq': 1,
      'firstSeq': 0,
      'hasMore': false,
    };
    transport.answers['api.subscribe'] = (params) => <String, dynamic>{
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['interactions.list'] = (_) => <String, dynamic>{
      'revision': 1,
      'requests': <Object?>[],
    };
    transport.answers['api.call'] = (params) {
      if (params['method'] == 'projections') {
        projectionReads++;
        return <String, dynamic>{
          'kind': 'sequenced',
          'asOfSeq': projectionReads,
          'values': <String, dynamic>{
            'sessionStats': <String, dynamic>{'turns': 1, 'steps': 1},
            'tokenUsage': <String, dynamic>{
              'uncachedInputTokens': 10,
              'cacheReadTokens': 90,
              'cacheWriteTokens': 0,
              'outputTokens': 5,
            },
            'contextPressure': <String, dynamic>{
              'pressureTokens': 100,
              'contextWindow': 1000,
            },
          },
        };
      }
      if (params['method'] == 'modelCatalog') {
        return <String, dynamic>{'groups': <Object?>[]};
      }
      return <String, dynamic>{};
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final connection = FakeRemoteConnection(
      transport: transport,
      windowAck: true,
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
        remoteConversationInteractionsListMethod,
        remoteConversationApiCallMethod,
      },
    );
    final source = RemoteConversationLiveSource(
      connection: connection,
      sessionId: 's-1',
      events: events.stream,
    );

    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();
    final afterLoad = projectionReads;
    expect(afterLoad, greaterThanOrEqualTo(1), reason: '首屏要读一次会话洞察');
    expect(tester.takeException(), isNull);

    // 一轮结束：follow 的增量在测试里由 `session.event` 通知代替，数据源据此重读。
    events.add(<String, dynamic>{
      'method': 'session.event',
      'params': <String, dynamic>{
        'sessionId': 's-1',
        'event': fixture.event(2, 'turn/end', <String, dynamic>{'turn': 1}),
      },
    });
    await tester.pumpAndSettle();
    expect(projectionReads, greaterThan(afterLoad), reason: '一轮结束后重读洞察');

    // 重连：阶段回到 ready 时数据源按协议 §7.2 重建，并重读洞察。
    final beforeReconnect = projectionReads;
    connection.setPhase(RemoteConnectionPhase.reconnecting);
    await tester.pump();
    connection.setPhase(RemoteConnectionPhase.ready);
    await tester.pumpAndSettle();
    expect(projectionReads, greaterThan(beforeReconnect), reason: '重连后重读洞察');
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据源推会话洞察更新时页面持有状态且不影响消息区', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      insights: RemoteSessionInsights.fromProjectionValues(<String, dynamic>{
        'todos': <Map<String, dynamic>>[
          <String, dynamic>{'content': '检查构建', 'status': 'in_progress'},
        ],
        'sessionStats': <String, dynamic>{'turns': 2, 'steps': 3},
      }),
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    // 假数据源在 start() 里按数据源契约读了洞察并推给页面；页面把读数交给待办
    // 卡片与统计条渲染，但推送与整体替换不能打扰已有的会话内容。
    expect(source.insightReads, 1);
    expect(find.text('你好'), findsOneWidget);
    expect(find.byKey(RemoteTodoCard.toggleKey), findsOneWidget);
    expect(find.text('轮 2 · 步 3'), findsOneWidget);

    source.emit(const RemoteConversationInsights(RemoteSessionInsights.none));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('你好'), findsOneWidget);
    expect(find.byKey(RemoteTodoCard.toggleKey), findsNothing);
    expect(find.byKey(RemoteStatsBar.barKey), findsNothing);
  });

  testWidgets('会话洞察到位时显示待办卡片与统计条，读数更新后一起刷新', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      insights: RemoteSessionInsights(
        todos: const <RemoteTodoItem>[
          RemoteTodoItem(content: '检查构建', status: RemoteTodoStatus.inProgress),
          RemoteTodoItem(content: '跑测试', status: RemoteTodoStatus.pending),
          RemoteTodoItem(content: '收尾', status: RemoteTodoStatus.completed),
        ],
        stats: const RemoteSessionStats(
          turns: 20,
          steps: 23,
          llmMs: 0,
          toolMs: 0,
          ttftMs: 0,
          ttftSteps: 0,
          decodeMs: 0,
          decodeTokens: 0,
        ),
        usage: const RemoteTokenUsage(
          uncachedInputTokens: 100,
          cacheReadTokens: 900,
          cacheWriteTokens: 0,
          outputTokens: 50,
        ),
        pressure: const RemoteContextPressure(
          projectedTokens: 500,
          contextWindow: 1000,
        ),
      ),
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.byKey(RemoteTodoCard.toggleKey), findsOneWidget);
    expect(find.text('已完成 1 · 进行中 1 · 待处理 1'), findsOneWidget);
    expect(find.byKey(RemoteStatsBar.barKey), findsOneWidget);
    expect(find.byKey(RemoteStatsBar.lineKey), findsOneWidget);
    expect(find.text('轮 20 · 步 23'), findsOneWidget);
    expect(find.text('1.1K tok · 缓存命中 90%'), findsOneWidget);
    expect(find.text('上下文 50%'), findsOneWidget);

    // 展开清单；随后数据源推新的读数，清单保持展开、摘要与统计一起刷新。
    await tester.tap(find.byKey(RemoteTodoCard.toggleKey));
    await tester.pump();
    expect(find.byKey(RemoteTodoCard.listKey), findsOneWidget);
    expect(find.text('检查构建'), findsOneWidget);

    source.emit(
      RemoteConversationInsights(
        RemoteSessionInsights(
          todos: const <RemoteTodoItem>[
            RemoteTodoItem(content: '检查构建', status: RemoteTodoStatus.completed),
            RemoteTodoItem(content: '跑测试', status: RemoteTodoStatus.inProgress),
            RemoteTodoItem(content: '收尾', status: RemoteTodoStatus.completed),
            RemoteTodoItem(content: '发布', status: RemoteTodoStatus.pending),
          ],
          stats: const RemoteSessionStats(
            turns: 21,
            steps: 24,
            llmMs: 0,
            toolMs: 0,
            ttftMs: 0,
            ttftSteps: 0,
            decodeMs: 0,
            decodeTokens: 0,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('已完成 2 · 进行中 1 · 待处理 1'), findsOneWidget);
    expect(find.text('轮 21 · 步 24'), findsOneWidget);
    // 新读数没有 token 与上下文：对应分段消失，而不是留下旧值或 0%。
    expect(find.textContaining('缓存命中'), findsNothing);
    expect(find.textContaining('上下文'), findsNothing);
    expect(
      find.byKey(RemoteTodoCard.listKey),
      findsOneWidget,
      reason: '读数刷新不会收起清单',
    );
    expect(find.text('发布'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有会话洞察读数时不显示待办卡片与统计条', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.byKey(RemoteTodoCard.toggleKey), findsNothing);
    expect(find.byKey(RemoteStatsBar.barKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点按统计条打开会话统计详情弹层', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      insights: RemoteSessionInsights(
        stats: const RemoteSessionStats(
          turns: 2,
          steps: 3,
          llmMs: 4000,
          toolMs: 0,
          ttftMs: 2000,
          ttftSteps: 2,
          decodeMs: 1000,
          decodeTokens: 120,
        ),
        usage: const RemoteTokenUsage(
          uncachedInputTokens: 10,
          cacheReadTokens: 90,
          cacheWriteTokens: 0,
          outputTokens: 5,
        ),
        pressure: const RemoteContextPressure(
          pressureTokens: 100,
          contextWindow: 1000,
        ),
      ),
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(RemoteStatsBar.barKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('remote-stats-sheet')), findsOneWidget);
    expect(find.text('Token 用量'), findsOneWidget);
    expect(find.text('未缓存输入'), findsOneWidget);
    expect(find.text('上下文'), findsOneWidget);
    expect(find.textContaining('不含输出'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭会话统计'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-stats-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('会话目的地标识带 remote-session:<id> 前缀', () {
    expect(
      RemoteDshConversationPage.destinationFor('s-1'),
      'remote-session:s-1',
    );
    expect(
      RemoteDshConversationPage.destinationFor('s-2'),
      isNot(RemoteDshConversationPage.destinationFor('s-1')),
    );
  });

  testWidgets('待处理审批显示工具名与输入摘要，允许一次后卡片消失', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      interactions: [_approvalInteraction()],
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-interaction-i-1')),
      findsOneWidget,
    );
    expect(find.textContaining('需要授权：android_shell'), findsOneWidget);
    expect(find.textContaining('rm -rf build'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-approval-allow-i-1')));
    await tester.pumpAndSettle();

    expect(source.approvalReplies, hasLength(1));
    expect(source.approvalReplies.single.id, 'i-1');
    expect(source.approvalReplies.single.version, 1);
    expect(source.approvalReplies.single.allow, isTrue);
    expect(
      find.byKey(const ValueKey('remote-interaction-i-1')),
      findsNothing,
      reason: '宿主受理后推的快照把卡片移除',
    );
  });

  testWidgets('拒绝按钮回 rejected 语义', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      interactions: [_approvalInteraction()],
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('remote-approval-deny-i-1')));
    await tester.pumpAndSettle();

    expect(source.approvalReplies.single.allow, isFalse);
  });

  testWidgets('答复被拒绝时显示宿主 message 并刷新交互快照', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            interactions: [_approvalInteraction()],
          )
          ..interactionReply = const RemoteInteractionReply(
            accepted: false,
            requestStillPending: true,
            message: '答复正在提交，请等待状态更新',
          );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('remote-approval-allow-i-1')));
    await tester.pumpAndSettle();

    expect(find.text('答复正在提交，请等待状态更新'), findsOneWidget);
    expect(source.interactionRefreshes, 1, reason: '被拒绝后要核对一次快照');
    expect(
      find.byKey(const ValueKey('remote-interaction-i-1')),
      findsOneWidget,
      reason: '请求仍在等待，卡片不消失',
    );
  });

  testWidgets('提问按 multiSelect 渲染，全部回答后提交才可用', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      interactions: [_questionInteraction()],
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    final submit = find.byKey(const ValueKey('remote-question-submit-i-q'));
    expect(submit, findsOneWidget);
    expect(
      tester.widget<PocketButton>(submit).onPressed,
      isNull,
      reason: '还没回答任何一个问题',
    );

    // 单选：选中 pnpm。
    await tester.tap(
      find.byKey(const ValueKey('remote-question-option-i-q-q1-pnpm')),
    );
    await tester.pump();
    expect(
      tester.widget<PocketButton>(submit).onPressed,
      isNull,
      reason: '第二个问题还没回答',
    );

    // 多选：先选一项。
    final secondQuestion = find.byKey(
      const ValueKey('remote-question-option-i-q-q2-测试'),
    );
    await tester.ensureVisible(secondQuestion);
    await tester.pump();
    await tester.tap(secondQuestion);
    await tester.pump();
    expect(tester.widget<PocketButton>(submit).onPressed, isNotNull);

    // 多选可以继续加点第二项。
    final secondOption = find.byKey(
      const ValueKey('remote-question-option-i-q-q2-格式化'),
    );
    await tester.ensureVisible(secondOption);
    await tester.pump();
    await tester.tap(secondOption);
    await tester.pump();
    await tester.ensureVisible(submit);
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    final answer = source.questionAnswers.single;
    expect(answer.id, 'i-q');
    expect(answer.version, 2);
    expect([for (final item in answer.answers) item.id], ['q1', 'q2']);
    expect(answer.answers[0].selected, ['pnpm']);
    expect(answer.answers[1].selected, hasLength(2));
    expect(answer.answers[1].selected, containsAll(<String>['格式化', '测试']));
    expect(answer.answers[0].custom, isNull);
    expect(
      find.byKey(const ValueKey('remote-interaction-i-q')),
      findsNothing,
      reason: '受理后快照移除卡片',
    );
  });

  testWidgets('单选问题填写自定义回答会清空选项，并只提交 custom', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      interactions: [_questionInteraction(single: true)],
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('remote-question-option-i-q-q1-npm')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('remote-question-custom-i-q-q1')),
      'yarn',
    );
    await tester.pump();
    final submit = find.byKey(const ValueKey('remote-question-submit-i-q'));
    expect(tester.widget<PocketButton>(submit).onPressed, isNotNull);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    final answers = source.questionAnswers.single.answers;
    expect(answers.single.selected, isEmpty);
    expect(answers.single.custom, 'yarn');
  });

  testWidgets('输入区显示当前模型，弹层选择模型并应用后回显新模型', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _flash,
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.text('deepseek-account/deepseek-flash'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-model-label')));
    await tester.pumpAndSettle();

    expect(source.catalogFetches, 1);
    expect(find.text('DeepSeek 账号'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('remote-model-deepseek-account-deepseek-flash'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(
        const ValueKey('remote-model-deepseek-account-deepseek-v4-pro'),
      ),
    );
    await tester.pump();
    // 模型声明推理强度时出现档位选择器。
    expect(
      find.byKey(const ValueKey('remote-model-reasoning')),
      findsOneWidget,
    );
    await tester.tap(find.text('高'));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('remote-model-apply')));
    await tester.pumpAndSettle();

    expect(source.selectedModels, hasLength(1));
    expect(
      source.selectedModels.single,
      const RemoteModelChoice(
        provider: 'deepseek-account',
        model: 'deepseek-v4-pro',
        reasoningEffort: 'high',
      ),
    );
    expect(find.text('deepseek-account/deepseek-v4-pro · 高'), findsOneWidget);
  });

  testWidgets('模型目录读取失败时在弹层里给出原因', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            modelChoice: _flash,
          )
          ..modelCatalogFailure = const RuntimeTransportFailure(
            code: 'gateway/unavailable',
            message: '电脑上的 DSH 暂时不可用，请稍后重试。',
          );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('remote-model-label')));
    await tester.pumpAndSettle();

    expect(find.text('电脑上的 DSH 暂时不可用，请稍后重试。'), findsOneWidget);
    expect(
      tester
          .widget<PocketButton>(
            find.byKey(const ValueKey('remote-model-apply')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('凭据类发送失败给出指向模型选择的可操作提示', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            modelChoice: _flash,
          )
          ..sendFailure = const RuntimeTransportFailure(
            code: 'gateway/internal',
            message: 'llm-deepseek: no API key for provider route "deepseek-official"',
          );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '再试一次');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    final hint = find.byKey(
      const ValueKey('remote-conversation-credential-hint'),
    );
    expect(hint, findsOneWidget);
    expect(find.textContaining('凭据'), findsOneWidget);

    final before = source.catalogFetches;
    await tester.tap(find.descendant(of: hint, matching: find.text('选择模型')));
    await tester.pumpAndSettle();
    expect(source.catalogFetches, before + 1, reason: '提示里的动作直接打开模型选择');
  });

  test('凭据类失败标记覆盖宿主两种文案', () {
    expect(
      isRemoteCredentialFailure(
        'llm-deepseek: no API key for provider route "deepseek-official"',
      ),
      isTrue,
    );
    expect(
      isRemoteCredentialFailure('Sign in to DeepSeek to use this model.'),
      isTrue,
    );
    expect(isRemoteCredentialFailure('gateway timeout'), isFalse);
  });

  // -------------------------------------------------- 本次变更 / 归档 / 能力三态

  testWidgets('不支持时「本次变更」「归档会话」置灰并给出原因', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多会话操作'));
    await tester.pumpAndSettle();

    expect(find.text('本次变更'), findsOneWidget);
    expect(find.text('归档会话'), findsOneWidget);
    expect(find.text('这台电脑不支持查看本次变更'), findsOneWidget);
    expect(find.text('这台电脑不支持归档会话'), findsOneWidget);

    // 置灰入口点了不产生任何动作。
    await tester.tap(find.text('本次变更'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteWorkspaceDiffPage), findsNothing);
  });

  testWidgets('未连接时菜单与重命名说明「正在连接电脑」而不是永久不支持', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      phase: RemoteConnectionPhase.reconnecting,
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.byTooltip('正在连接电脑…'), findsOneWidget);

    await tester.tap(find.byTooltip('更多会话操作'));
    await tester.pumpAndSettle();
    expect(find.text('正在连接电脑…'), findsWidgets);
  });

  testWidgets('已连接但宿主没有 api.call 时模型入口显示原因而非死按钮', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
      },
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-model-unavailable')),
      findsOneWidget,
    );
    expect(find.text('这台电脑不支持选择模型'), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-model-label')), findsNothing);
    expect(
      tester.widget<RemoteComposer>(find.byType(RemoteComposer)).onModel,
      isNull,
    );
  });

  testWidgets('归档会话：确认后回写 library.sessionArchive，给出结果并返回首页', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
        remoteConversationArchiveMethod,
      },
    );
    await _pushConversation(tester, source);

    await tester.tap(find.byTooltip('更多会话操作'));
    await tester.pumpAndSettle();
    expect(find.text('这台电脑不支持归档会话'), findsNothing);

    await tester.tap(find.text('归档会话'));
    await tester.pumpAndSettle();
    expect(find.textContaining('归档后「修复登录」会离开项目列表'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-archive-confirm')));
    await tester.pumpAndSettle();

    expect(source.archiveCalls, 1);
    expect(source.archived, isTrue);
    expect(
      find.byType(RemoteDshConversationPage),
      findsNothing,
      reason: '成功后离开会话页',
    );
    expect(find.text('已归档「修复登录」'), findsOneWidget, reason: '结果留在首页可见');
  });

  testWidgets('归档失败时留在页面上并展示宿主原因', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            supported: <String>{
              remoteConversationReadMethod,
              remoteConversationSendMethod,
              remoteConversationArchiveMethod,
            },
          )
          ..archiveFailure = const RuntimeTransportFailure(
            code: 'gateway/unavailable',
            message: '电脑上的 DSH 暂时不可用，请稍后重试。',
          );
    await _pushConversation(tester, source);

    await tester.tap(find.byTooltip('更多会话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('归档会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remote-archive-confirm')));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteDshConversationPage), findsOneWidget);
    expect(find.textContaining('归档失败：电脑上的 DSH 暂时不可用'), findsOneWidget);
  });

  testWidgets('本次变更入口走独立目的地并释放页面数据源', (tester) async {
    final workspaceSource = FakeRemoteWorkspaceChangesSource(
      resolution: RemoteWorkspaceChangesFound(
        seq: 3,
        summary: testWorkspaceChangesSummary(turn: 2),
      ),
    );
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
        remoteWorkspaceChangesSummaryMethod,
        remoteWorkspaceChangesDiffMethod,
      },
      workspaceChanges: workspaceSource,
    );
    final routes = <String?>[];
    await _pushConversation(tester, source, routes: routes);

    await tester.tap(find.byTooltip('更多会话操作'));
    await tester.pumpAndSettle();
    expect(find.text('这台电脑不支持查看本次变更'), findsNothing);

    await tester.tap(find.text('本次变更'));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteWorkspaceDiffPage), findsOneWidget);
    expect(workspaceSource.resolves, 1);
    expect(
      routes,
      contains(destinationRouteName(RemoteWorkspaceDiffPage.routeDestination)),
    );

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(RemoteWorkspaceDiffPage), findsNothing);
    expect(workspaceSource.disposed, isTrue, reason: '页面释放自己持有的数据源');
  });

  // -------------------------------------------------- 模型路由自动兜底

  testWidgets('凭据类失败时自动切到电脑默认模型并重发一次，常驻说明原因', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            modelChoice: _flash,
            defaultModelRoute: const RemoteModelChoice(
              provider: 'deepseek-account',
              model: 'deepseek-v4-pro',
            ),
          )
          ..sendFailures.add(
            const RuntimeTransportFailure(
              code: 'gateway/internal',
              message: 'llm-deepseek: no API key for provider route "deepseek-official"',
            ),
          );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '再试一次');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.sendCalls, 2, reason: '只重发一次');
    expect(
      source.selectedModels.single,
      const RemoteModelChoice(
        provider: 'deepseek-account',
        model: 'deepseek-v4-pro',
      ),
    );
    expect(source.sent, <String>['再试一次']);
    expect(
      find.byKey(const ValueKey('remote-conversation-fallback-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('已自动切换到这台电脑的默认模型'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-model-label')),
      findsOneWidget,
      reason: '输入区同时回显新路由',
    );
    expect(
      find.byKey(const ValueKey('remote-conversation-credential-hint')),
      findsNothing,
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty, reason: '重发成功后清空输入框');
  });

  testWidgets('兜底重发仍失败时同时展示两次失败且不再重试', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            modelChoice: _flash,
            defaultModelRoute: const RemoteModelChoice(
              provider: 'deepseek-account',
              model: 'deepseek-v4-pro',
            ),
          )
          ..sendFailures.addAll(<RuntimeTransportFailure>[
            const RuntimeTransportFailure(
              code: 'gateway/internal',
              message: 'llm-deepseek: no API key for provider route "deepseek-official"',
            ),
            const RuntimeTransportFailure(
              code: 'gateway/timeout',
              message: '电脑上的 DSH 响应超时，请重试。',
            ),
          ]);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '再试一次');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.sendCalls, 2, reason: '最多一次重发，不允许循环');
    expect(source.sent, isEmpty);
    final notice = find.byKey(
      const ValueKey('remote-conversation-fallback-notice'),
    );
    expect(notice, findsOneWidget);
    expect(find.textContaining('no API key'), findsOneWidget);
    expect(find.textContaining('仍然失败'), findsOneWidget);
    expect(find.textContaining('响应超时'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-conversation-credential-hint')),
      findsNothing,
    );
  });

  testWidgets('切换默认模型失败时把切换失败也放进常驻说明', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            modelChoice: _flash,
            defaultModelRoute: const RemoteModelChoice(
              provider: 'deepseek-account',
              model: 'deepseek-v4-pro',
            ),
          )
          ..sendFailures.add(
            const RuntimeTransportFailure(
              code: 'gateway/internal',
              message: 'Sign in to DeepSeek to use this model.',
            ),
          )
          ..selectModelFailure = const RuntimeTransportFailure(
            code: 'gateway/unavailable',
            message: '电脑上的 DSH 暂时不可用，请稍后重试。',
          );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '再试一次');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.sendCalls, 1, reason: '切换失败后不再重发');
    expect(find.textContaining('自动切换到这台电脑的默认模型'), findsOneWidget);
    expect(find.textContaining('电脑上的 DSH 暂时不可用'), findsOneWidget);
  });

  testWidgets('电脑没有不同的默认模型时保留原有的选择模型提示', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            modelChoice: _flash,
          )
          ..sendFailure = const RuntimeTransportFailure(
            code: 'gateway/internal',
            message: 'llm-deepseek: no API key for provider route "deepseek-official"',
          );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '再试一次');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.sendCalls, 1, reason: '没有可切换的默认模型时不重发');
    expect(source.defaultRouteFetches, 1);
    expect(
      find.byKey(const ValueKey('remote-conversation-credential-hint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('remote-conversation-fallback-notice')),
      findsNothing,
    );
    expect(source.sent, isEmpty);
  });

  // -------------------------------------------------- 会话指令

  testWidgets('输入以 / 开头时提示会在电脑上执行，提交走 session.command 并清空草稿', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _flash,
    )..commandResult = const RemoteCommandResult.success(text: '已进入计划模式');
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/plan 进入计划模式');
    await tester.pump();

    expect(
      find.byKey(const ValueKey('remote-command-hint')),
      findsOneWidget,
      reason: '斜杠草稿要说明这一行会在电脑上执行',
    );
    expect(find.textContaining('这条会作为电脑上的命令执行：/plan 进入计划模式'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-send')),
      findsOneWidget,
      reason: '指令也用同一个提交按钮',
    );

    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.commands, ['/plan 进入计划模式']);
    expect(source.commandCalls, 1, reason: '以 / 开头的行必须走 session.command');
    expect(source.sent, isEmpty, reason: '斜杠行不能落到 session.send');
    expect(
      find.byKey(const ValueKey('remote-conversation-command-success')),
      findsOneWidget,
    );
    expect(find.text('已进入计划模式'), findsOneWidget, reason: '成功结果常驻展示');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty, reason: '成功后清空输入框');
    expect(find.byKey(const ValueKey('remote-command-hint')), findsNothing);
  });

  testWidgets('指令失败时结果常驻、草稿保留，可直接重试', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _flash,
    )..commandResult = const RemoteCommandResult.error('这台电脑上还没有目标。');
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), ' /goal 完成登录 ');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.commands, ['/goal 完成登录'], reason: '提交前去掉首尾空白');
    expect(source.sent, isEmpty);
    expect(
      find.byKey(const ValueKey('remote-conversation-command-error')),
      findsOneWidget,
    );
    expect(find.text('这台电脑上还没有目标。'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text.trim(), '/goal 完成登录', reason: '失败保留草稿');

    // 结果条是常驻的：不随 3 秒状态条消失。
    await tester.pump(const Duration(seconds: 5));
    expect(
      find.byKey(const ValueKey('remote-conversation-command-error')),
      findsOneWidget,
    );

    // 用户点「知道了」才收起。
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('remote-conversation-command-error')),
      findsNothing,
    );
  });

  testWidgets('电脑没有识别出指令时说明没有发给模型并保留草稿', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _flash,
    )..commandResult = const RemoteCommandResult.unrecognized();
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/nope');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.commands, ['/nope']);
    expect(source.sent, isEmpty);
    expect(find.textContaining('电脑上没有这条指令：/nope。它没有发给模型。'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '/nope', reason: '未识别时保留草稿');
  });

  testWidgets('指令请求失败时展示原因并保留草稿', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            modelChoice: _flash,
          )
          ..commandFailure = const RuntimeTransportFailure(
            code: 'gateway/unavailable',
            message: '与电脑的连接已断开，正在重连…',
          );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/plan');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.commandCalls, 1);
    expect(source.sent, isEmpty);
    expect(find.text('与电脑的连接已断开，正在重连…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-conversation-command-error')),
      findsOneWidget,
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '/plan', reason: '失败保留草稿');
  });

  testWidgets('宿主不支持会话指令时只给可见说明，不发送任何内容', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _flash,
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
        remoteConversationApiCallMethod,
      },
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/plan');
    await tester.pump();
    expect(find.textContaining('这台电脑不支持执行会话指令，这一行不会发送。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.commandCalls, 0, reason: '不支持时连请求都不发');
    expect(source.sent, isEmpty, reason: '也不能退化成普通消息');
    expect(
      find.byKey(const ValueKey('remote-conversation-command-error')),
      findsOneWidget,
    );
    expect(find.textContaining('这台电脑不支持执行会话指令，这一行不会发送。'), findsWidgets);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '/plan');
  });

  testWidgets('只有斜杠时本地提示补指令名，不发请求也不当消息发送', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _flash,
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/   ');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.commandCalls, 0);
    expect(source.sent, isEmpty);
    expect(find.text('「/」后面还需要指令名，例如 /plan。'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text.trim(), '/');
  });

  testWidgets('执行指令期间显示忙态且不可重复提交，完成后给出结果', (tester) async {
    final hold = Completer<void>();
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            modelChoice: _flash,
          )
          ..commandHold = hold
          ..commandResult = const RemoteCommandResult.success(text: '已压缩');
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/compact');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pump();

    expect(find.text('正在执行电脑上的指令…'), findsOneWidget);
    expect(
      tester.widget<RemoteComposer>(find.byType(RemoteComposer)).enabled,
      isFalse,
      reason: '执行期间输入区不可编辑',
    );
    expect(find.byKey(const ValueKey('remote-send')), findsNothing);

    hold.complete();
    await tester.pumpAndSettle();

    expect(source.commandCalls, 1);
    expect(find.text('正在执行电脑上的指令…'), findsNothing);
    expect(find.text('已压缩'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty);
  });

  testWidgets('普通文本仍然走 session.send，不显示指令提示', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _flash,
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '普通消息');
    await tester.pump();
    expect(find.byKey(const ValueKey('remote-command-hint')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.sent, ['普通消息']);
    expect(source.commands, isEmpty);
    expect(source.commandCalls, 0);
  });

  // -------------------------------------------------- 模型路由发送前提示

  testWidgets('当前路由的服务商在目录里读取失败时，发送前提示并可打开模型选择', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _official,
      failedModelProviders: const <String>{'deepseek-official'},
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    final hint = find.byKey(
      const ValueKey('remote-conversation-model-route-hint'),
    );
    expect(hint, findsOneWidget);
    expect(
      find.textContaining('当前会话绑定的模型在电脑上不可用，发送时会自动改用电脑默认模型'),
      findsOneWidget,
    );

    final before = source.catalogFetches;
    await tester.tap(find.descendant(of: hint, matching: find.text('选择模型')));
    await tester.pumpAndSettle();
    expect(source.catalogFetches, before + 1, reason: '提示里的动作直接打开模型选择弹层');
  });

  testWidgets('目录失败列表不含当前路由的服务商时不显示发送前提示', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _flash,
      failedModelProviders: const <String>{'deepseek-official'},
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-conversation-model-route-hint')),
      findsNothing,
    );
  });

  testWidgets('还没有可推导的路由时不显示发送前提示', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      failedModelProviders: const <String>{'deepseek-official'},
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-conversation-model-route-hint')),
      findsNothing,
    );
  });

  testWidgets('路由换到可用的服务商后发送前提示消失', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _official,
      failedModelProviders: const <String>{'deepseek-official'},
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('remote-conversation-model-route-hint')),
      findsOneWidget,
    );

    source.modelChoice = _flash;
    source.emit(const RemoteConversationModel(_flash));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-conversation-model-route-hint')),
      findsNothing,
      reason: '新路由的服务商不在失败列表里',
    );
  });

  testWidgets('一次成功发送后不再显示发送前提示', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _official,
      failedModelProviders: const <String>{'deepseek-official'},
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('remote-conversation-model-route-hint')),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.sent, ['你好']);
    expect(
      find.byKey(const ValueKey('remote-conversation-model-route-hint')),
      findsNothing,
      reason: '发送成功说明这条路由实际可用，提示不再出现',
    );
  });

  testWidgets('「+」→「文件」选附件后 rail 展示，只有附件也能发送并在受理后回收', (tester) async {
    final surface = FakeAttachmentSurface();
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    )..attachmentSurface = surface;
    _mockAttachmentPicker(tester);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加与指令'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件  file'));
    await tester.pumpAndSettle();

    expect(surface.prepares, 1);
    expect(find.text('季度报告.txt'), findsOneWidget);
    expect(find.textContaining('已就绪'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-send')),
      findsOneWidget,
      reason: '只有附件、没有文字时也要能发送（与本地 main.dart 一致）',
    );

    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.sent, ['']);
    expect(source.sentAttachmentIds.single, <String>[_attachmentId]);
    expect(surface.releases, 1, reason: '受理后才回收草稿');
    expect(find.text('季度报告.txt'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('附件准备失败时发送给出说明且不提交，rail 可直接重试', (tester) async {
    final surface = FakeAttachmentSurface();
    surface.prepareFailures.add(
      const RemoteAttachmentFailure(
        'attachment-file/unsupported',
        '这台手机上的 App 版本不支持上传附件。',
      ),
    );
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    )..attachmentSurface = surface;
    _mockAttachmentPicker(tester);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加与指令'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件  file'));
    await tester.pumpAndSettle();

    expect(find.textContaining('上传失败'), findsOneWidget);
    expect(find.text('这台手机上的 App 版本不支持上传附件。'), findsOneWidget);
    expect(find.text('重试上传'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(find.text('附件尚未准备完成，请重试或移除失败项。'), findsOneWidget);
    expect(source.sendCalls, 0, reason: '附件未就绪时整条消息不发送');

    await tester.tap(find.text('重试上传'));
    await tester.pumpAndSettle();
    expect(surface.prepares, 2);
    expect(find.textContaining('已就绪'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();
    expect(source.sentAttachmentIds.single, <String>[_attachmentId]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据源没有附件调用面时「文件」项置灰且不弹选择器', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    );
    _mockAttachmentPicker(tester);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加与指令'));
    await tester.pumpAndSettle();
    expect(find.text('添加与指令'), findsOneWidget, reason: '弹层标题');
    expect(find.text('文件  file'), findsOneWidget);
    expect(find.text('这台电脑不支持上传附件'), findsOneWidget, reason: '置灰项写原因，不是静默消失');

    await tester.tap(find.text('文件  file'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('添加与指令'), findsOneWidget, reason: '置灰项不回调，弹层保持打开');
    expect(tester.takeException(), isNull);
  });

  testWidgets('「+」里的 goal 行置灰写原因，点击不执行也不插入草稿', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    );
    source.answers['api.call'] = (params) => <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'goal',
        'definitionId': '@deepseek-ai/dsh-command-goal',
        'description': '设置或查看长期任务目标',
        'input': <String, dynamic>{'hint': '<text>'},
      },
      <String, dynamic>{
        'name': 'compact',
        'definitionId': '@deepseek-ai/dsh-command-compact',
        'description': '压缩以上对话内容',
      },
      <String, dynamic>{
        'name': 'feedback',
        'definitionId': '@deepseek-ai/dsh-command-feedback',
        'description': '发送关于当前会话的反馈',
        'input': <String, dynamic>{'hint': '<text>'},
      },
    ];
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加与指令'));
    await tester.pumpAndSettle();
    expect(find.text('目标  goal'), findsOneWidget);
    expect(find.text('远程会话暂不支持设置长期目标'), findsOneWidget);

    await tester.tap(find.text('目标  goal'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('添加与指令'), findsOneWidget, reason: '置灰行不回调，弹层保持打开');
    expect(source.commands, isEmpty, reason: 'goal 行不执行任何宿主指令');
    expect(
      tester
          .widget<TextField>(find.byType(TextField, skipOffstage: false).first)
          .controller!
          .text,
      isEmpty,
      reason: 'goal 行也不把 /goal 插进草稿',
    );

    // 同一份目录里其它宿主指令仍然可用：不需要输入的直接执行。
    await tester.tap(find.text('压缩  compact'));
    await tester.pumpAndSettle();
    expect(source.commands, <String>['/compact']);

    // 需要输入的指令插入草稿等待补参数（goal 置灰不改变这条路径）。
    await tester.tap(find.byTooltip('添加与指令'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('反馈  feedback'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '/feedback ',
    );
    expect(source.commands, <String>['/compact'], reason: '插入草稿不等于执行');
    expect(tester.takeException(), isNull);
  });

  testWidgets('计划待生效时计划条显示「将在下一步生效」', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    )..projections = _planProjections(active: false, pending: true);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.text('计划模式'), findsOneWidget);
    expect(find.text('将在下一步生效'), findsOneWidget);
    expect(find.byTooltip('退出计划模式'), findsOneWidget);
  });

  testWidgets('未连接时不显示计划条，也不显示状态确认失败', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      phase: RemoteConnectionPhase.connecting,
    )..projections = _planProjections(active: true, pending: false);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.text('计划模式'), findsNothing);
    expect(
      find.byKey(const ValueKey('remote-conversation-plan-status')),
      findsNothing,
    );
    expect(source.projectionReads, 0, reason: '未连接不发投影请求');
  });

  testWidgets('投影显示计划模式时出现计划条，退出按钮写 /plan off 且保留草稿', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    )..projections = _planProjections(active: true, pending: false);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.text('计划模式'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '计划外的草稿');
    await tester.pump();

    await tester.tap(find.byTooltip('退出计划模式'));
    await tester.pumpAndSettle();

    expect(source.planCommands, <bool>[false]);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '计划外的草稿',
      reason: '计划模式写失败/未确认不影响输入草稿',
    );
    expect(source.commands, isEmpty, reason: '计划开关由数据源的计划写入口承担');
    expect(tester.takeException(), isNull);
  });

  testWidgets('计划状态写失败时保留说明与草稿，不重放', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    )..projections = _planProjections(active: true, pending: false);
    source.planFailure = const RuntimeTransportFailure(
      code: 'gateway/unavailable',
      message: '连接已断开，请重试。',
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '保留这段草稿');
    await tester.pump();
    await tester.tap(find.byTooltip('退出计划模式'));
    await tester.pumpAndSettle();

    expect(find.textContaining('操作未确认'), findsOneWidget);
    expect(find.textContaining('连接已断开，请重试。'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '保留这段草稿',
    );
    expect(source.planCommands, <bool>[false], reason: '未确认的写不重放');
  });

  testWidgets('session.projections 读失败显示可重试说明，重试后恢复计划条', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    );
    source.projectionsFailure = const RuntimeTransportFailure(
      code: 'gateway/unavailable',
      message: '连接中断',
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-conversation-plan-status')),
      findsOneWidget,
    );
    expect(find.textContaining('无法确认计划模式状态'), findsOneWidget);

    source.projectionsFailure = null;
    source.projections = _planProjections(active: true, pending: false);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-conversation-plan-status')),
      findsNothing,
    );
    expect(find.text('计划模式'), findsOneWidget);
  });

  testWidgets('控制流基线快照建立计划状态，不显示状态确认失败', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-conversation-plan-status')),
      findsNothing,
    );

    // 宿主 `session.control` 基线里的会话块是 `{asOfSeq, values}`，没有
    // `kind`（`SessionProjectionBaseline` 与 `session.projections` 的
    // `{kind:'sequenced', …}` 是同一份快照）。真机上把缺 `kind` 当成读失败
    // 会弹常驻「无法确认计划模式状态」横幅，这里守住它不再出现。
    source.emitControl(<String, dynamic>{
      'type': 'item',
      'value': <String, dynamic>{
        'type': 'baseline',
        'value': <String, dynamic>{
          'projections': <String, dynamic>{
            source.sessionId: <String, dynamic>{
              'asOfSeq': 3,
              'values': <String, dynamic>{
                'plan': <String, dynamic>{'active': true, 'pending': false},
              },
            },
          },
        },
      },
    });
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-conversation-plan-status')),
      findsNothing,
    );
    expect(find.text('计划模式'), findsOneWidget);
    expect(find.byTooltip('退出计划模式'), findsOneWidget);
  });

  testWidgets('计划审核卡片批准计划，回 intent.approve 选项', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      interactions: [_planReviewInteraction()],
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.text('计划审核'), findsOneWidget);
    expect(find.text('迁移到新接口'), findsOneWidget, reason: '预览标题来自计划首行');
    expect(find.textContaining('先改数据源'), findsOneWidget, reason: '预览摘要');

    await tester.tap(find.byKey(const ValueKey('remote-plan-approve-i-plan')));
    await tester.pumpAndSettle();

    final answer = source.questionAnswers.single;
    expect(answer.id, 'i-plan');
    expect(answer.version, 3);
    expect(answer.answers.single.id, 'plan-q');
    expect(answer.answers.single.selected, <String>['批准']);
    expect(
      find.byKey(const ValueKey('remote-interaction-i-plan')),
      findsNothing,
    );
    expect(
      source.projectionReads,
      greaterThanOrEqualTo(2),
      reason: '批准计划后主动重读一次计划投影',
    );
  });

  testWidgets('计划审核「请求修改」走 interactions.dismiss，不发送答案', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      interactions: [_planReviewInteraction()],
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('remote-plan-dismiss-i-plan')));
    await tester.pumpAndSettle();

    expect(source.dismissedInteractions.single, (id: 'i-plan', version: 3));
    expect(source.questionAnswers, isEmpty, reason: '请求修改不发送答案');
    expect(
      find.byKey(const ValueKey('remote-interaction-i-plan')),
      findsOneWidget,
      reason: '计划仍在等待决定',
    );
  });

  testWidgets('计划原文可推入既有计划阅读页', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      interactions: [_planReviewInteraction()],
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('remote-plan-open-i-plan')));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPlanDocumentPage), findsOneWidget);
    expect(find.textContaining('先改数据源，再改页面。'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('盾牌与回显显示真实当前预设，切换后写 /permission 并重读投影', (tester) async {
    final source = _permissionSource();
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-permission-label')),
      findsOneWidget,
    );
    expect(find.text('权限预设：工作区内修改'), findsOneWidget);
    expect(find.byTooltip('权限预设：工作区内修改'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-permission-label')));
    await tester.pumpAndSettle();

    expect(find.text('仅可查看'), findsOneWidget);
    expect(find.text('工作区内修改'), findsWidgets);
    expect(find.text('完全权限'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget, reason: '当前项打勾');

    await tester.tap(find.text('仅可查看'));
    await tester.pumpAndSettle();

    final command = source.requests.singleWhere(
      (request) => request.method == 'session.command',
    );
    expect(command.params, <String, dynamic>{
      'sessionId': 's-1',
      'line': '/permission read-only',
      'attachmentIds': <String>[],
    });
    expect(
      find.byType(RemotePermissionSheet),
      findsNothing,
      reason: '成功后退回会话页',
    );
    expect(find.text('权限预设：仅可查看'), findsOneWidget, reason: '写回后重读投影');
  });

  testWidgets('完全权限在会话页弹层里先确认再写 /permission', (tester) async {
    final source = _permissionSource();
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('remote-permission-label')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完全权限'));
    await tester.pumpAndSettle();

    expect(find.text('确认启用完全权限？'), findsOneWidget);
    expect(
      source.requests.where((request) => request.method == 'session.command'),
      isEmpty,
      reason: '只点选项不提交',
    );

    await tester.tap(find.text('我已了解风险，并愿意继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();

    expect(
      source.requests
          .singleWhere((request) => request.method == 'session.command')
          .params['line'],
      '/permission danger-full-access',
    );
    expect(find.text('权限预设：完全权限'), findsOneWidget);
  });

  testWidgets('电脑未启用权限预设时盾牌置灰并写明原因', (tester) async {
    final source = _permissionSource(available: false);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-permission-unavailable')),
      findsOneWidget,
    );
    expect(find.text('这台电脑未启用权限预设'), findsOneWidget);
    expect(find.byTooltip('权限预设：这台电脑未启用权限预设'), findsOneWidget);

    await tester.tap(find.byTooltip('权限预设：这台电脑未启用权限预设'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(RemotePermissionSheet), findsNothing);
    expect(
      source.requests.where((request) => request.method == 'api.call'),
      isEmpty,
      reason: '未启用时不读目录',
    );
  });

  testWidgets('未连接时盾牌说明「正在连接电脑…」且不显示回显行', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      phase: RemoteConnectionPhase.connecting,
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.byTooltip('权限预设：正在连接电脑…'), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-permission-label')), findsNothing);
    expect(
      find.byKey(const ValueKey('remote-permission-unavailable')),
      findsNothing,
    );
    expect(source.requests, isEmpty);
  });

  testWidgets('目录读取失败在弹层内报错，重试后恢复', (tester) async {
    final source = _permissionSource();
    var failing = true;
    source.answers['api.call'] = (params) {
      if (failing) throw StateError('目录不可用');
      return _permissionCatalog();
    };
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('remote-permission-label')));
    await tester.pumpAndSettle();
    expect(find.text('无法读取权限预设'), findsOneWidget);

    failing = false;
    await tester.tap(find.text('重新读取'));
    await tester.pumpAndSettle();

    expect(find.text('无法读取权限预设'), findsNothing);
    expect(find.text('仅可查看'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-permission-label')),
      findsOneWidget,
    );
  });

  testWidgets('权限预设与一次性审批卡片共存，预设只影响新请求', (tester) async {
    final source = _permissionSource(interactions: [_approvalInteraction()]);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-permission-label')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('remote-interaction-i-1')),
      findsOneWidget,
      reason: '预设入口不影响已挂起的审批卡片',
    );
    expect(find.textContaining('需要授权：android_shell'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-permission-label')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅可查看'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-interaction-i-1')),
      findsOneWidget,
      reason: '切换预设不会自动通过已挂起的请求',
    );
    expect(source.approvalReplies, isEmpty);
  });

  // -------------------------------------------------- 输入区三态（悬浮输入卡）

  testWidgets('输入区默认缩小态，聚焦展开，失焦后由草稿决定是否收起', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _v4ProHigh,
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    // 缩小态：一行悬浮卡，占位文案、加号与盾牌都在，没有工具条与发送圆钮。
    expect(find.text('在 客厅的电脑 上工作'), findsOneWidget);
    expect(find.byTooltip('添加与指令'), findsOneWidget);
    expect(find.byTooltip('推理强度'), findsNothing);
    expect(find.byKey(const ValueKey('remote-send')), findsNothing);
    final collapsed = tester.getSize(find.byKey(PocketComposer.cardKey)).height;

    // 点输入框：卡片展开成「输入区 + 工具条一行」。
    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('推理强度'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(PocketComposer.cardKey)).height,
      greaterThan(collapsed),
    );

    // 有草稿时失焦保持展开：用户还能看见自己写的内容。
    await tester.enterText(find.byKey(PocketComposer.inputKey), '写了一半的草稿');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.byTooltip('推理强度'), findsOneWidget, reason: '有草稿时保持展开');

    // 纯浏览（草稿清空且失焦）才缩小回一行。
    await tester.enterText(find.byKey(PocketComposer.inputKey), '');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.byTooltip('推理强度'), findsNothing, reason: '纯浏览时回到缩小态');
  });

  testWidgets('点推理按钮进入强度面板：模型与档位来自目录，切档走 selectModel', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _v4ProHigh,
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();

    expect(source.catalogFetches, 1, reason: '面板的档位与默认值来自模型目录，第一次打开读一次');
    expect(find.byKey(PocketComposer.modelsKey), findsOneWidget);
    expect(find.text('DeepSeek V4 Pro'), findsOneWidget, reason: '当前模型显示名');
    expect(find.text('高'), findsOneWidget, reason: '当前强度回显');
    expect(find.byKey(PocketComposer.stopKeyFor('low')), findsOneWidget);
    expect(find.byKey(PocketComposer.stopKeyFor('high')), findsOneWidget);

    await tester.tap(find.byKey(PocketComposer.stopKeyFor('low')));
    await tester.pumpAndSettle();

    expect(source.selectedModels, <RemoteModelChoice>[
      const RemoteModelChoice(
        provider: 'deepseek-account',
        model: 'deepseek-v4-pro',
        reasoningEffort: 'low',
      ),
    ]);
    expect(find.textContaining('推理强度已改为「低」'), findsOneWidget);
    expect(find.text('低'), findsWidgets, reason: '写回后回显当前强度');

    // 再次点推理按钮收起面板，输入区回来。
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();
    expect(find.byKey(PocketComposer.modelsKey), findsNothing);
    expect(find.byKey(PocketComposer.inputKey), findsOneWidget);

    // 面板第一行的模型名打开既有模型选择弹层，原有模型入口不丢。
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PocketComposer.modelsKey));
    await tester.pumpAndSettle();
    expect(find.text('选择会话模型'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭模型选择'));
    await tester.pumpAndSettle();

    // 点聊天区也收起面板，回到输入态（参照图「点别处」）。
    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();
    expect(find.byKey(PocketComposer.modelsKey), findsOneWidget);
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('remote-transcript'))).center,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(PocketComposer.modelsKey), findsNothing);
    expect(find.byKey(PocketComposer.inputKey), findsOneWidget);
  });

  testWidgets('推理面板读取目录失败时在面板里给原因并可重试', (tester) async {
    final source =
        FakeRemoteConversationSource(
            window: _window(conversationEvents()),
            modelChoice: _v4ProHigh,
          )
          ..modelCatalogFailure = const RuntimeTransportFailure(
            code: 'gateway/unavailable',
            message: '电脑上的 DSH 暂时不可用，请稍后重试。',
          );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();

    expect(find.textContaining('电脑上的 DSH 暂时不可用'), findsOneWidget);
    expect(find.byKey(PocketComposer.reasoningRetryKey), findsOneWidget);

    source.modelCatalogFailure = null;
    await tester.tap(find.byKey(PocketComposer.reasoningRetryKey));
    await tester.pumpAndSettle();

    expect(find.byKey(PocketComposer.stopKeyFor('low')), findsOneWidget);
    expect(find.textContaining('电脑上的 DSH 暂时不可用'), findsNothing);
  });

  testWidgets('展开态保留既有入口：加号与权限预设都在，发送仍走 session.send', (tester) async {
    final source = _permissionSource();
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('添加与指令'), findsOneWidget);
    expect(find.byTooltip('权限预设：工作区内修改'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-permission-label')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('remote-send')), findsNothing);

    await tester.enterText(find.byKey(PocketComposer.inputKey), ' 发送这条消息 ');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(source.sent, <String>['发送这条消息'], reason: '发送仍走既有 session.send');
    expect(
      find.byKey(const ValueKey('remote-send')),
      findsNothing,
      reason: '受理后草稿清空，发送圆钮收起',
    );
  });

  testWidgets('展开态下附件 rail 是输入卡上方的插槽，发送带上附件', (tester) async {
    final surface = FakeAttachmentSurface();
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
    )..attachmentSurface = surface;
    _mockAttachmentPicker(tester);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加与指令'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件  file'));
    await tester.pumpAndSettle();

    expect(find.text('季度报告.txt'), findsOneWidget);
    final rail = tester.getRect(find.text('季度报告.txt'));
    final card = tester.getRect(find.byKey(PocketComposer.cardKey));
    expect(
      rail.bottom,
      lessThanOrEqualTo(card.top),
      reason: '附件 rail 渲染在卡片上方的插槽里',
    );
    expect(find.byKey(const ValueKey('remote-send')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();
    expect(source.sentAttachmentIds.single, <String>[_attachmentId]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('键盘收起后纯浏览回到缩小态，有草稿时保持展开', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _v4ProHigh,
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('推理强度'), findsOneWidget);

    // 模拟键盘弹起：纯浏览（无草稿）时收起键盘应回到缩小态。
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pumpAndSettle();
    expect(find.byTooltip('推理强度'), findsOneWidget, reason: '键盘弹起时保持展开');

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byTooltip('推理强度'), findsNothing, reason: '键盘收起且无草稿回到缩小态');

    // 有草稿时键盘收起仍保持展开。
    await tester.enterText(find.byKey(PocketComposer.inputKey), '写了一半');
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byTooltip('推理强度'), findsOneWidget, reason: '有草稿时保持展开');
  });

  testWidgets('聚焦后键盘尚未弹起的 metrics 抖动不会把输入卡缩回', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _v4ProHigh,
    );
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('推理强度'), findsOneWidget);

    // 真机上的现象：聚焦后、键盘真正弹起前，Android 还会派发一次「键盘仍不可
    // 见」的 metrics（例如窗口尺寸抖动）。这里用尺寸变化触发同样的回调，而
    // viewInsets 保持 0：输入卡不得因此缩回并解焦。
    tester.view.physicalSize = const Size(2400, 1802);
    await tester.pump();
    tester.view.physicalSize = const Size(2400, 1800);
    await tester.pumpAndSettle();

    expect(
      tester.widget<RemoteComposer>(find.byType(RemoteComposer)).mode,
      PocketComposerMode.composing,
      reason: '键盘还没起来时的 metrics 抖动不得缩回输入卡',
    );
    expect(find.byTooltip('推理强度'), findsOneWidget);
    expect(find.byKey(PocketComposer.inputKey), findsOneWidget);
  });

  testWidgets('缩小态点卡片空白处也能聚焦展开并进入输入', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _v4ProHigh,
    );
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();
    expect(find.byTooltip('推理强度'), findsNothing);

    // 卡片底部内边距不属于输入框：点它也应聚焦输入框并展开（真机上「点输入区
    // 有时没反应」的兜底入口）。
    final card = tester.getRect(find.byKey(PocketComposer.cardKey));
    await tester.tapAt(Offset(card.center.dx, card.bottom - 4));
    await tester.pumpAndSettle();

    expect(
      tester.widget<RemoteComposer>(find.byType(RemoteComposer)).mode,
      PocketComposerMode.composing,
    );
    expect(find.byTooltip('推理强度'), findsOneWidget);
  });

  testWidgets('推理面板不依赖键盘 insets：键盘收起/再弹起仍显示滑杆，点聊天区退出', (tester) async {
    final source = FakeRemoteConversationSource(
      window: _window(conversationEvents()),
      modelChoice: _v4ProHigh,
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();
    expect(find.byKey(PocketComposer.modelsKey), findsOneWidget);
    expect(find.byType(ReasoningEffortSlider), findsOneWidget);

    // 用户按返回键收起键盘：面板保持可见、滑杆仍在，不被踢回浏览态。
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(
      tester.widget<RemoteComposer>(find.byType(RemoteComposer)).mode,
      PocketComposerMode.picker,
      reason: '推理面板不因键盘收起而退出',
    );
    expect(find.byKey(PocketComposer.modelsKey), findsOneWidget);
    expect(find.byType(ReasoningEffortSlider), findsOneWidget);

    // 面板开着时键盘再弹起（0→>0 的又一次变化）同样不打断面板。
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pumpAndSettle();
    expect(
      tester.widget<RemoteComposer>(find.byType(RemoteComposer)).mode,
      PocketComposerMode.picker,
    );
    expect(find.byType(ReasoningEffortSlider), findsOneWidget);

    // 点聊天区退出：键盘已收起且无草稿，回到缩小态。
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('remote-transcript'))).center,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(PocketComposer.modelsKey), findsNothing);
    expect(
      tester.widget<RemoteComposer>(find.byType(RemoteComposer)).mode,
      PocketComposerMode.browse,
    );
  });
}

/// 把会话页推到一个首页之上，用来验证「归档成功后返回上一页」与目的地路由名。
Future<void> _pushConversation(
  WidgetTester tester,
  RemoteConversationSource source, {
  List<String?>? routes,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: pocketTheme(Brightness.light),
      navigatorObservers: <NavigatorObserver>[
        if (routes != null) _RouteLog(routes),
      ],
      home: const Scaffold(body: Center(child: Text('远程首页'))),
    ),
  );
  await tester.pumpAndSettle();
  unawaited(
    navigator.currentState!.push<void>(
      PocketRoute<void>(
        builder: (_) => RemoteDshConversationPage(
          source: source,
          deviceName: '客厅的电脑',
          projectName: 'Pocket',
          title: '修复登录',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 记录每次推入的路由名。
class _RouteLog extends NavigatorObserver {
  _RouteLog(this.names);

  final List<String?> names;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}
