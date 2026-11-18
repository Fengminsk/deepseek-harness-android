// 真实会话数据源（`RemoteConversationLiveSource`）的门面调用与重连语义。
//
// 传输是假的：本文件只断言发出去的参数与顺序（`session.readWindow` /
// `session.send` / `api.subscribe` / `api.unsubscribe`），以及注入的 `api.stream`
// 与 `session.*` 通知如何变成页面更新。不连宿主、不拨号。

import 'dart:async';

import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_conversation_live_source.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_projection_test.dart' as fixture;
import 'support/remote_conversation_fakes.dart';

Map<String, dynamic> _windowPayload(List<Map<String, dynamic>> events) => {
  'events': events,
  'throughSeq': events.last['seq'] as int,
  'firstSeq': events.first['seq'] as int,
  'hasMore': false,
};

Map<String, dynamic> _item(
  String streamId,
  String generation,
  int sequence,
  Object? value,
) => {
  'method': 'api.stream',
  'params': {
    'streamId': streamId,
    'generation': generation,
    'sequence': sequence,
    'type': 'item',
    'value': value,
  },
};

Map<String, dynamic> _modelSelectionEvent(
  int seq, {
  required String provider,
  required String model,
  String? effort,
}) => {
  'seq': seq,
  'time': seq * 1000,
  'type': 'model/selection',
  'data': {'provider': provider, 'model': model, 'reasoningEffort': ?effort},
};

Map<String, dynamic> _approvalRequest({
  String id = 'i-1',
  int version = 1,
  String sessionId = 's-1',
}) => {
  'id': id,
  'version': version,
  'sessionId': sessionId,
  'kind': 'approval',
  'toolName': 'android_shell',
  'callId': 'call-1',
  'reason': '需要运行命令',
  'toolCall': {
    'turn': 1,
    'step': 1,
    'callId': 'call-1',
    'name': 'android_shell',
    'arguments': '{"command":"rm -rf build","cwd":"C:/work"}',
  },
};

Map<String, dynamic> _questionRequest({
  String id = 'i-q',
  int version = 2,
  String sessionId = 's-1',
}) => {
  'id': id,
  'version': version,
  'sessionId': sessionId,
  'kind': 'question',
  'questions': [
    {
      'id': 'q1',
      'question': '用哪个包管理器？',
      'multiSelect': false,
      'options': [
        {'label': 'npm'},
        {'label': 'pnpm', 'description': '更快'},
      ],
    },
    {
      'id': 'q2',
      'question': '还需要做什么？',
      'detail': '可以选择多项',
      'multiSelect': true,
      'options': [
        {'label': '格式化'},
        {'label': '测试'},
      ],
    },
  ],
};

Map<String, dynamic> _interactionsPayload({
  int revision = 1,
  required List<Map<String, dynamic>> requests,
  String? error,
}) => {'revision': revision, 'requests': requests, 'error': ?error};

Map<String, dynamic> _catalogPayload() => {
  'default': {'provider': 'deepseek-account', 'model': 'deepseek-flash'},
  'groups': [
    {
      'id': 'deepseek-account',
      'name': 'DeepSeek 账号',
      'models': [
        {'id': 'deepseek-flash', 'name': 'DeepSeek Flash'},
        {
          'id': 'deepseek-v4-pro',
          'name': 'DeepSeek V4 Pro',
          'reasoning': {
            'efforts': [
              {'id': 'low', 'name': '低'},
              {'id': 'high', 'name': '高'},
            ],
            'defaultEffort': 'high',
          },
        },
      ],
    },
  ],
  'failures': [
    {'name': 'openai', 'message': '缺少 API Key'},
  ],
};

/// 构造一个可以应答交互与模型目录的假连接。
FakeRemoteConnection _interactionConnection(FakeRemoteTransport transport) =>
    FakeRemoteConnection(
      transport: transport,
      windowAck: true,
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
        remoteConversationRenameMethod,
        remoteConversationInteractionsListMethod,
        remoteConversationInteractionsReplyMethod,
        remoteConversationApiCallMethod,
      },
    );

/// 绑定一个真实数据源并收集它推给页面的更新。
({RemoteConversationLiveSource source, List<RemoteConversationUpdate> updates})
_attachSource(
  FakeRemoteTransport transport,
  StreamController<Map<String, dynamic>> events,
) {
  final source = RemoteConversationLiveSource(
    connection: _interactionConnection(transport),
    sessionId: 's-1',
    events: events.stream,
  );
  final updates = <RemoteConversationUpdate>[];
  final subscription = source.updates.listen(updates.add);
  addTearDown(() async {
    await subscription.cancel();
    source.dispose();
  });
  return (source: source, updates: updates);
}

void main() {
  test('增量读与加载更早使用 afterSeq/beforeSeq 和小页参数', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (params) => {
      'events': [fixture.input((params['afterSeq'] as int?) ?? 20, '增量')],
      'throughSeq': 30,
      'firstSeq': (params['afterSeq'] as int?) ?? 20,
      'hasMore': true,
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final harness = _attachSource(transport, events);
    addTearDown(events.close);

    final newer = await harness.source.readNewer(20);
    expect(newer?.throughSeq, 30);
    expect(newer?.hasMore, isTrue);
    await harness.source.readOlder(beforeSeq: 20, throughSeq: 30);

    final requests = transport.paramsOf('session.readWindow');
    expect(requests[0], {
      'sessionId': 's-1',
      'afterSeq': 20,
      'maxEvents': RemoteConversationSource.firstPageMaxEvents,
      'maxBytes': RemoteConversationSource.firstPageMaxBytes,
    });
    expect(requests[1], {
      'sessionId': 's-1',
      'throughSeq': 30,
      'beforeSeq': 20,
      'maxEvents': RemoteConversationSource.firstPageMaxEvents,
      'maxBytes': RemoteConversationSource.firstPageMaxBytes,
    });
  });
  test('首屏读窗口、follow 订阅、发消息带窗口里的模型路由', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0), fixture.input(1, '你好')]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final connection = FakeRemoteConnection(
      transport: transport,
      windowAck: true,
    );
    final source = RemoteConversationLiveSource(
      connection: connection,
      sessionId: 's-1',
      events: events.stream,
    );
    final updates = <RemoteConversationUpdate>[];
    final subscription = source.updates.listen(updates.add);
    addTearDown(() async {
      await subscription.cancel();
      await events.close();
    });

    await source.start();
    await pumpEventQueue();

    expect(transport.paramsOf('session.readWindow').first, {
      'sessionId': 's-1',
      'maxEvents': RemoteConversationSource.firstPageMaxEvents,
      'maxBytes': RemoteConversationSource.firstPageMaxBytes,
    });
    final subscribe = transport.paramsOf('api.subscribe').single;
    expect(subscribe['namespace'], remoteConversationFollowNamespace);
    expect(subscribe['method'], remoteConversationFollowMethod);
    // 门面签名是 follow(request)，缺了这层包装网关会以「args 字段不匹配」拒绝。
    expect(subscribe['args'], {
      'request': {
        'address': {'kind': 'session', 'sessionId': 's-1'},
        'activate': true,
      },
    });
    final streamId = subscribe['streamId'] as String;
    final generation = 'generation-$streamId';
    expect(
      updates.whereType<RemoteConversationSnapshot>().first.window.events,
      hasLength(2),
    );

    // follow 的第一帧是完整快照：整体替换窗口。
    events.add(
      _item(streamId, generation, 1, {
        'type': 'snapshot',
        'cursor': 2,
        'records': [
          {'type': 'event', 'event': fixture.header(0)},
          {'type': 'event', 'event': fixture.input(1, '你好')},
          {'type': 'event', 'event': fixture.assistant(2, '你好，我在。')},
        ],
        'hasMore': false,
      }),
    );
    await pumpEventQueue();
    expect(
      updates.whereType<RemoteConversationSnapshot>().last.window.events,
      hasLength(3),
    );

    // 之后的帧是增量。
    events.add(
      _item(streamId, generation, 2, {
        'type': 'event',
        'event': fixture.input(3, '再问一句'),
      }),
    );
    await pumpEventQueue();
    final appended = updates.whereType<RemoteConversationEvents>().single;
    expect(appended.events.single['seq'], 3);

    // 双方都声明 window-ack 时回执用累计 upTo（协议 §6.2/§6.4）。
    final acked = transport.paramsOf('api.ack');
    expect(acked, isNotEmpty, reason: '收到流帧后必须回执');
    expect(acked.last['upTo'], isA<int>());
    expect(acked.last.containsKey('sequence'), isFalse);

    // 正在生成的回复走宿主本来就推送的 session.live，形态与本地一致。
    events.add({
      'method': 'session.live',
      'params': {
        'sessionId': 's-1',
        'value': {
          'attemptId': 'attempt-1',
          'turn': 2,
          'step': 1,
          'content': [
            {'type': 'text', 'text': '正在回复'},
          ],
        },
      },
    });
    await pumpEventQueue();
    expect(
      updates.whereType<RemoteConversationLive>().single.value?['attemptId'],
      'attempt-1',
    );

    // 发送参数：provider / model 来自窗口里的 request/header 投影。
    await source.send('继续');
    final sent = transport.paramsOf('session.send').single;
    expect(sent['sessionId'], 's-1');
    expect(sent['text'], '继续');
    expect(sent['provider'], 'fixture');
    expect(sent['model'], 'fixture');
    expect(sent['selectModel'], false);
    expect(sent['requestId'], isA<String>());
    expect((sent['requestId'] as String).startsWith('app-'), isTrue);

    source.dispose();
    await pumpEventQueue();
  });

  test('重连先重读窗口、显式退订旧流再用新 streamId 重订阅', () async {
    final transport = FakeRemoteTransport();
    var reads = 0;
    transport.answers['session.readWindow'] = (_) {
      reads++;
      return _windowPayload([
        fixture.header(0),
        fixture.input(1, '断线前'),
        if (reads > 1) fixture.input(2, '断线后'),
      ]);
    };
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final connection = FakeRemoteConnection(
      transport: transport,
      windowAck: true,
    );
    final source = RemoteConversationLiveSource(
      connection: connection,
      sessionId: 's-1',
      events: events.stream,
    );
    final updates = <RemoteConversationUpdate>[];
    final subscription = source.updates.listen(updates.add);
    addTearDown(() async {
      await subscription.cancel();
      await events.close();
    });

    await source.start();
    await pumpEventQueue();
    final firstStreamId =
        transport.paramsOf('api.subscribe').single['streamId'] as String;

    // 断线：阶段先离开 ready，数据源让流观察进入断开态。
    connection.setPhase(RemoteConnectionPhase.reconnecting);
    await pumpEventQueue();
    expect(connection.phase, RemoteConnectionPhase.reconnecting);

    // 重新 ready：按协议 §7.2 先重读窗口，再重新订阅。
    connection.setPhase(RemoteConnectionPhase.ready);
    await pumpEventQueue();
    await pumpEventQueue();

    final methods = transport.methods;
    expect(reads, 2, reason: '重连必须重读窗口');
    expect(
      methods.lastIndexOf('session.readWindow'),
      lessThan(methods.lastIndexOf('api.subscribe')),
      reason: '先重读窗口、再重新订阅',
    );
    final unsubscribes = transport.paramsOf('api.unsubscribe');
    expect(
      unsubscribes.map((params) => params['streamId']),
      contains(firstStreamId),
      reason: '旧流必须显式 api.unsubscribe，不能留下孤儿流',
    );
    final resubscribe = transport.paramsOf('api.subscribe').last;
    expect(
      resubscribe['streamId'],
      isNot(firstStreamId),
      reason: '每次订阅尝试都必须是新的 streamId（协议 §6.1）',
    );

    // 页面看到的是整体替换后的窗口。
    final rebuilt = updates
        .whereType<RemoteConversationSnapshot>()
        .last
        .window
        .events;
    expect(rebuilt.last['seq'], 2);
    expect(rebuilt.any((event) => event['seq'] == 1), isTrue);

    final subscribedBeforeDispose = transport.paramsOf('api.subscribe').length;
    source.dispose();
    await pumpEventQueue();
    expect(
      transport.paramsOf('api.unsubscribe').map((params) => params['streamId']),
      contains(resubscribe['streamId']),
      reason: '页面关闭时也要显式退订当前流',
    );

    // 页面关闭后连接即使再回到 ready，也不得重新订阅：否则宿主又多一条孤儿流。
    connection.setPhase(RemoteConnectionPhase.reconnecting);
    connection.setPhase(RemoteConnectionPhase.ready);
    await pumpEventQueue();
    expect(
      transport.paramsOf('api.subscribe'),
      hasLength(subscribedBeforeDispose),
      reason: '页面关闭后不得重新订阅',
    );
  });

  test('follow 不可用时仍用 session.event 通知增量', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0), fixture.input(1, '你好')]);
    transport.answers['api.subscribe'] = (_) =>
        throw const RuntimeTransportFailure(
          code: 'unsupported-method',
          message: '当前连接的电脑不支持「api.subscribe」。',
        );
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final connection = FakeRemoteConnection(
      transport: transport,
      windowAck: true,
    );
    final source = RemoteConversationLiveSource(
      connection: connection,
      sessionId: 's-1',
      events: events.stream,
    );
    final updates = <RemoteConversationUpdate>[];
    final subscription = source.updates.listen(updates.add);
    addTearDown(() async {
      await subscription.cancel();
      await events.close();
    });

    await source.start();
    await pumpEventQueue();

    events.add({
      'method': 'session.event',
      'params': {'sessionId': 's-1', 'event': fixture.assistant(2, '来自通知的回复')},
    });
    await pumpEventQueue();

    expect(updates.whereType<RemoteConversationFailure>(), isEmpty);
    final appended = updates.whereType<RemoteConversationEvents>().single;
    expect(appended.events.single['type'], 'assistant/message');

    // 重复通知不会变成第二条更新（页面与数据源都按 seq 去重）。
    events.add({
      'method': 'session.event',
      'params': {'sessionId': 's-1', 'event': fixture.assistant(2, '来自通知的回复')},
    });
    await pumpEventQueue();
    expect(updates.whereType<RemoteConversationEvents>(), hasLength(1));

    source.dispose();
    await pumpEventQueue();
  });

  test(
    '首屏读 interactions.list 并按会话过滤，interactions.changed 整体替换、旧 revision 丢弃',
    () async {
      final transport = FakeRemoteTransport();
      transport.answers['session.readWindow'] = (_) =>
          _windowPayload([fixture.header(0)]);
      transport.answers['api.subscribe'] = (params) => {
        'streamId': params['streamId'],
        'generation': 'generation-${params['streamId']}',
      };
      var interactionsListCalls = 0;
      transport.answers['interactions.list'] = (_) {
        interactionsListCalls++;
        return _interactionsPayload(
          revision: 3,
          requests: [
            _approvalRequest(),
            _approvalRequest(id: 'i-2', sessionId: 's-2'),
            _questionRequest(),
          ],
        );
      };
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      addTearDown(events.close);
      final (:source, :updates) = _attachSource(transport, events);

      await source.start();
      await pumpEventQueue();

      expect(interactionsListCalls, 1, reason: '首屏必须读一次待处理交互');
      final snapshot = updates
          .whereType<RemoteConversationInteractions>()
          .single;
      expect(snapshot.requests, hasLength(2), reason: '只保留当前会话的请求');
      final approval = snapshot.requests.first;
      expect(approval.id, 'i-1');
      expect(approval.version, 1);
      expect(approval.kind, RemoteInteractionKind.approval);
      expect(approval.toolName, 'android_shell');
      expect(approval.reason, '需要运行命令');
      // 一行摘要来自 toolCall.arguments 里的前几个参数。
      expect(approval.summary, contains('command: rm -rf build'));
      expect(approval.summary, contains('cwd: C:/work'));

      // 提问类投影出每个问题、选项说明与 multiSelect。
      final question = snapshot.requests.last;
      expect(question.kind, RemoteInteractionKind.question);
      expect([for (final item in question.questions) item.id], ['q1', 'q2']);
      expect(question.questions[0].multiSelect, isFalse);
      expect(question.questions[0].options[1].label, 'pnpm');
      expect(question.questions[0].options[1].description, '更快');
      expect(question.questions[1].multiSelect, isTrue);
      expect(question.questions[1].detail, '可以选择多项');

      // 通知形态与 interactions.list 的 result 同形：整体替换。
      events.add({
        'method': 'interactions.changed',
        'params': _interactionsPayload(
          revision: 4,
          requests: <Map<String, dynamic>>[],
        ),
      });
      await pumpEventQueue();
      expect(
        updates.whereType<RemoteConversationInteractions>().last.requests,
        isEmpty,
        reason: '请求消失后必须推空快照，页面据此清掉卡片',
      );

      // 迟到的旧 revision 不能把已经消失的请求带回来。
      events.add({
        'method': 'interactions.changed',
        'params': _interactionsPayload(
          revision: 2,
          requests: [_approvalRequest()],
        ),
      });
      await pumpEventQueue();
      expect(
        updates.whereType<RemoteConversationInteractions>().last.requests,
        isEmpty,
      );

      // 另一会话的交互变化不该推一条本会话的空更新。
      final emitted = updates
          .whereType<RemoteConversationInteractions>()
          .length;
      events.add({
        'method': 'interactions.changed',
        'params': _interactionsPayload(
          revision: 5,
          requests: [_approvalRequest(id: 'i-3', sessionId: 's-2')],
        ),
      });
      await pumpEventQueue();
      expect(
        updates.whereType<RemoteConversationInteractions>(),
        hasLength(emitted),
        reason: '本会话待处理项没变时不重复推快照',
      );
    },
  );

  test('审批与提问答复的线上参数', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0)]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['interactions.list'] = (_) =>
        _interactionsPayload(revision: 1, requests: [_approvalRequest()]);
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final (:source, :updates) = _attachSource(transport, events);
    await source.start();
    await pumpEventQueue();

    transport.answers['interactions.reply'] = (_) => <String, dynamic>{
      'accepted': true,
      'requestStillPending': false,
    };
    final allowed = await source.replyApproval('i-1', 7, allow: true);
    expect(allowed.accepted, isTrue);
    expect(allowed.requestStillPending, isFalse);
    expect(transport.paramsOf('interactions.reply').last, {
      'id': 'i-1',
      'version': 7,
      'response': 'allowed-once',
    });

    await source.replyApproval('i-1', 7, allow: false);
    expect(
      transport.paramsOf('interactions.reply').last['response'],
      'rejected',
    );

    // 宿主明确拒绝时把 message 与「仍在等待」原样交给页面。
    transport.answers['interactions.reply'] = (_) => <String, dynamic>{
      'accepted': false,
      'requestStillPending': true,
      'message': '答复正在提交，请等待状态更新',
    };
    final rejected = await source.replyApproval('i-1', 7, allow: true);
    expect(rejected.accepted, isFalse);
    expect(rejected.requestStillPending, isTrue);
    expect(rejected.message, '答复正在提交，请等待状态更新');

    await source.answerQuestion('i-q', 2, const [
      RemoteQuestionAnswer(id: 'q1', selected: ['pnpm']),
      RemoteQuestionAnswer(id: 'q2', selected: ['格式化', '测试']),
      RemoteQuestionAnswer(id: 'q3', custom: '  自定义  '),
    ]);
    final questionReply = transport.paramsOf('interactions.reply').last;
    expect(questionReply['id'], 'i-q');
    expect(questionReply['version'], 2);
    expect(questionReply['response'], {
      'answers': [
        {
          'id': 'q1',
          'selected': ['pnpm'],
        },
        {
          'id': 'q2',
          'selected': ['格式化', '测试'],
        },
        {'id': 'q3', 'selected': <String>[], 'custom': '自定义'},
      ],
    });
    // 本测试只关心请求参数；未被使用的局部变量在这里显式忽略。
    expect(updates, isNotEmpty);
  });

  test('重连后按协议 §7.2 重读窗口与待处理交互', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0)]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    var interactionsListCalls = 0;
    transport.answers['interactions.list'] = (_) {
      interactionsListCalls++;
      return _interactionsPayload(
        revision: interactionsListCalls,
        requests: [_approvalRequest()],
      );
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final (:source, :updates) = _attachSource(transport, events);

    await source.start();
    await pumpEventQueue();
    expect(interactionsListCalls, 1);

    // 断线再 ready：先重读窗口，再重读待处理交互。
    final connection = source.connection as FakeRemoteConnection;
    connection.setPhase(RemoteConnectionPhase.reconnecting);
    await pumpEventQueue();
    connection.setPhase(RemoteConnectionPhase.ready);
    await pumpEventQueue();
    await pumpEventQueue();

    expect(interactionsListCalls, 2, reason: '重连后必须重读 interactions.list');
    final methods = transport.methods;
    expect(
      methods.lastIndexOf('session.readWindow'),
      lessThan(methods.lastIndexOf('interactions.list')),
      reason: '先重读窗口、再重读交互',
    );
    expect(
      updates
          .whereType<RemoteConversationInteractions>()
          .last
          .requests
          .single
          .id,
      'i-1',
    );
  });

  test('模型目录读取、切换参数与切换后的发送路由', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0), fixture.input(1, '你好')]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['interactions.list'] = (_) =>
        _interactionsPayload(revision: 0, requests: <Map<String, dynamic>>[]);
    transport.answers['api.call'] = (params) => switch (params['method']) {
      'modelCatalog' => _catalogPayload(),
      'selectModel' => <String, dynamic>{
        'selected': {
          'provider': 'deepseek-account',
          'model': 'deepseek-flash',
          'reasoningEffort': 'low',
        },
      },
      _ => <String, dynamic>{},
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final (:source, :updates) = _attachSource(transport, events);
    await source.start();
    await pumpEventQueue();

    // 窗口里的 request/header 就是当前模型。
    expect(
      updates.whereType<RemoteConversationModel>().last.choice,
      const RemoteModelChoice(provider: 'fixture', model: 'fixture'),
    );

    // 模型选择事件进窗口后，投影给出新的待生效选择。
    final streamId = transport.paramsOf('api.subscribe').single['streamId'];
    events.add(
      _item(streamId, 'generation-$streamId', 1, {
        'type': 'snapshot',
        'cursor': 1,
        'records': [
          {
            'type': 'event',
            'event': _modelSelectionEvent(
              0,
              provider: 'deepseek-account',
              model: 'deepseek-v4-pro',
            ),
          },
        ],
        'hasMore': false,
      }),
    );
    await pumpEventQueue();
    expect(
      updates.whereType<RemoteConversationModel>().last.choice?.model,
      'deepseek-v4-pro',
    );

    final catalog = await source.fetchModelCatalog();
    expect(transport.paramsOf('api.call').first, {
      'namespace': 'session',
      'method': 'modelCatalog',
      'args': <String, dynamic>{},
    });
    expect(catalog.defaultChoice?.model, 'deepseek-flash');
    expect(catalog.groups.single.id, 'deepseek-account');
    expect(catalog.groups.single.name, 'DeepSeek 账号');
    expect(
      [for (final model in catalog.groups.single.models) model.id],
      ['deepseek-flash', 'deepseek-v4-pro'],
    );
    final reasoning = catalog.groups.single.models.last.reasoning;
    expect(
      [for (final effort in reasoning!.efforts) effort.id],
      ['low', 'high'],
    );
    expect(reasoning.defaultEffort, 'high');
    expect(catalog.failures.single, contains('缺少 API Key'));
    expect(catalog.routableProviders, <String>{
      'deepseek-account',
    }, reason: '旧宿主目录没有 routableProviders：用非空分组的 id 兜底');

    await source.selectModel(
      const RemoteModelChoice(
        provider: 'deepseek-account',
        model: 'deepseek-flash',
        reasoningEffort: 'low',
      ),
    );
    final selectCall = transport.paramsOf('api.call').last;
    expect(selectCall['method'], 'selectModel');
    expect(selectCall['args'], {
      'request': {
        'sessionId': 's-1',
        'provider': 'deepseek-account',
        'model': 'deepseek-flash',
        'reasoningEffort': 'low',
      },
    });
    expect(
      updates.whereType<RemoteConversationModel>().last.choice,
      const RemoteModelChoice(
        provider: 'deepseek-account',
        model: 'deepseek-flash',
        reasoningEffort: 'low',
      ),
    );

    // 受理结果立刻用于下一次发送，不用等模型选择事件进窗口。
    await source.send('换模型后');
    final sent = transport.paramsOf('session.send').single;
    expect(sent['provider'], 'deepseek-account');
    expect(sent['model'], 'deepseek-flash');
    expect(sent['reasoningEffort'], 'low');
    expect(sent['selectModel'], false);
  });

  // ------------------------------------------------------------ 归档与模型兜底

  test('归档会话走 library.sessionArchive 的 archived:true', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0)]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final (:source, :updates) = _attachSource(transport, events);
    await source.start();
    await pumpEventQueue();

    await source.archive();
    expect(transport.paramsOf('library.sessionArchive').single, {
      'sessionId': 's-1',
      'archived': true,
    });
    expect(updates, isNotEmpty);
  });

  test('默认模型路由从 settings.describe 的 agent-default-model 读取', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0)]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['settings.describe'] = (_) => <Object?>[
      <String, dynamic>{
        'ns': 'agent-default-model',
        'value': <String, dynamic>{
          'provider': 'deepseek-account',
          'model': 'deepseek-flash',
        },
      },
    ];
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final (:source, :updates) = _attachSource(transport, events);
    await source.start();
    await pumpEventQueue();

    expect(
      await source.fetchDefaultModelRoute(),
      const RemoteModelChoice(
        provider: 'deepseek-account',
        model: 'deepseek-flash',
      ),
    );

    // 设置里没有默认模型时返回 null：页面保留「选择模型」提示，不自动切换。
    transport.answers['settings.describe'] = (_) => <Object?>[
      <String, dynamic>{'ns': 'agent-default-model'},
    ];
    expect(await source.fetchDefaultModelRoute(), isNull);

    // 宿主不支持 settings.describe 时同样返回 null，不把失败升级成第二条错误。
    transport.answers['settings.describe'] = (_) =>
        throw const RuntimeTransportFailure(
          code: 'unsupported-method',
          message: '这台电脑不支持「settings.describe」。',
        );
    expect(await source.fetchDefaultModelRoute(), isNull);
    expect(updates, isNotEmpty);
  });

  // ------------------------------------------------------------ 本次变更

  FakeRemoteConnection workspaceConnection(FakeRemoteTransport transport) =>
      FakeRemoteConnection(
        transport: transport,
        supported: <String>{
          remoteConversationReadMethod,
          remoteWorkspaceChangesSummaryMethod,
          remoteWorkspaceChangesDiffMethod,
          remoteWorkspaceChangesCancelMethod,
        },
      );

  Map<String, dynamic> changesEvent(int seq, {int turn = 1}) =>
      <String, dynamic>{
        'seq': seq,
        'time': seq * 1000,
        'type': 'workspace/changes',
        'data': <String, dynamic>{'turn': turn},
      };

  Map<String, dynamic> turnEvent(int seq, String type, {int turn = 1}) =>
      <String, dynamic>{
        'seq': seq,
        'time': seq * 1000,
        'type': type,
        'data': <String, dynamic>{'turn': turn},
      };

  Map<String, dynamic> summaryPayload({int turn = 1}) => <String, dynamic>{
    'turn': turn,
    'files': <Map<String, dynamic>>[
      <String, dynamic>{
        'path': 'lib/a.dart',
        'display': 'lib/a.dart',
        'added': 2,
        'deleted': 1,
      },
    ],
    'total': 1,
    'added': 2,
    'deleted': 1,
  };

  Map<String, dynamic> diffPayload() => <String, dynamic>{
    'kind': 'text',
    'path': 'lib/a.dart',
    'display': 'lib/a.dart',
    'before': true,
    'after': true,
    'coarse': false,
    'hunks': <Map<String, dynamic>>[
      <String, dynamic>{
        'oldStart': 1,
        'oldLines': 1,
        'newStart': 1,
        'newLines': 2,
        'lines': <String>['-old', '+new'],
      },
    ],
  };

  Map<String, dynamic> unavailableEnvelope() => <String, dynamic>{
    'ok': false,
    'error': <String, dynamic>{
      'code': 'workspace-changes/unavailable',
      'message': 'This change snapshot is no longer available.',
      'details': <String, dynamic>{'status': 404},
    },
  };

  test('UUID v4 标识符符合线上格式且不重复', () {
    final pattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
      r'[0-9a-f]{12}$',
    );
    final values = <String>{
      for (var index = 0; index < 64; index++) remoteUuidV4(),
    };
    expect(values, hasLength(64));
    expect(values.every(pattern.hasMatch), isTrue);
  });

  test('本次变更：用窗口里最后一条 workspace/changes 事件的 seq 读摘要', () async {
    final transport = FakeRemoteTransport();
    transport.answers['workspaceChanges.summary'] = (_) => <String, dynamic>{
      'ok': true,
      'value': summaryPayload(turn: 2),
    };
    final workspace = RemoteWorkspaceChangesLiveSource(
      link: workspaceConnection(transport),
      session: 's-1',
      events: () => <Map<String, dynamic>>[
        changesEvent(3, turn: 1),
        changesEvent(5, turn: 2),
        turnEvent(6, 'turn/end', turn: 2),
      ],
      latest: () => 9,
    );
    addTearDown(workspace.dispose);

    final resolution = await workspace.resolveSnapshot();
    expect(resolution, isA<RemoteWorkspaceChangesFound>());
    final found = resolution as RemoteWorkspaceChangesFound;
    expect(found.seq, 5, reason: '取最后一条 workspace/changes 事件的序号');
    expect(found.summary.turn, 2);
    expect(found.summary.files.single.path, 'lib/a.dart');

    final params = transport.paramsOf('workspaceChanges.summary').single;
    expect(params['sessionId'], 's-1');
    expect(params['seq'], 5);
    expect(params['owner'], startsWith('remote-'));
    expect((params['owner'] as String).length, lessThanOrEqualTo(200));
    expect(
      params['requestId'],
      matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab]')),
    );
    expect(
      transport.paramsOf('workspaceChanges.summary'),
      hasLength(1),
      reason: '命中 announcement 序号后不再扫描其它序号',
    );
  });

  test('本次变更：会话页缓存停在发送前时，以重新读取的窗口为准', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) => _windowPayload([
      turnEvent(1, 'turn/start'),
      changesEvent(12, turn: 3),
      turnEvent(13, 'turn/end', turn: 3),
    ]);
    transport.answers['workspaceChanges.summary'] = (_) => <String, dynamic>{
      'ok': true,
      'value': summaryPayload(turn: 3),
    };
    final workspace = RemoteWorkspaceChangesLiveSource(
      link: workspaceConnection(transport),
      session: 's-1',
      // 会话页在发消息前就读过窗口：缓存里还没有本轮的 workspace/changes。
      events: () => <Map<String, dynamic>>[turnEvent(1, 'turn/start')],
      latest: () => 10,
    );
    addTearDown(workspace.dispose);

    final resolution = await workspace.resolveSnapshot();
    expect(resolution, isA<RemoteWorkspaceChangesFound>());
    expect((resolution as RemoteWorkspaceChangesFound).seq, 12);
    expect(
      transport.paramsOf('workspaceChanges.summary').single['seq'],
      12,
      reason: '重新读取窗口后命中本轮的 announcement 序号',
    );
  });

  test('本次变更：announcement 序号不可用时按正常降级，不再乱扫', () async {
    final transport = FakeRemoteTransport();
    transport.answers['workspaceChanges.summary'] = (_) =>
        unavailableEnvelope();
    final workspace = RemoteWorkspaceChangesLiveSource(
      link: workspaceConnection(transport),
      session: 's-1',
      events: () => <Map<String, dynamic>>[
        changesEvent(3),
        turnEvent(6, 'turn/end'),
      ],
      latest: () => 9,
    );
    addTearDown(workspace.dispose);

    final resolution = await workspace.resolveSnapshot();
    expect(resolution, isA<RemoteWorkspaceChangesUnavailable>());
    final unavailable = resolution as RemoteWorkspaceChangesUnavailable;
    expect(unavailable.announced, isTrue);
    expect(unavailable.scanned, 1, reason: '只读 announcement 序号一次');
    expect(unavailable.limit, 1);
    expect(unavailable.startSeq, 9);
    expect(transport.paramsOf('workspaceChanges.summary'), hasLength(1));
  });

  test('本次变更：本轮未结束时回「结束后可查看」，不发任何读取', () async {
    final transport = FakeRemoteTransport();
    final workspace = RemoteWorkspaceChangesLiveSource(
      link: workspaceConnection(transport),
      session: 's-1',
      events: () => <Map<String, dynamic>>[
        turnEvent(1, 'turn/start'),
        turnEvent(2, 'assistant/message'),
      ],
      latest: () => 2,
    );
    addTearDown(workspace.dispose);

    expect(
      await workspace.resolveSnapshot(),
      isA<RemoteWorkspaceChangesPendingTurn>(),
    );
    expect(transport.paramsOf('workspaceChanges.summary'), isEmpty);
  });

  test('本次变更：没有 announcement 事件时最多向下兜底扫描 5 步', () async {
    final transport = FakeRemoteTransport();
    transport.answers['workspaceChanges.summary'] = (_) =>
        unavailableEnvelope();
    final workspace = RemoteWorkspaceChangesLiveSource(
      link: workspaceConnection(transport),
      session: 's-1',
      events: () => <Map<String, dynamic>>[turnEvent(3, 'turn/end')],
      latest: () => 20,
    );
    addTearDown(workspace.dispose);

    final resolution = await workspace.resolveSnapshot();
    expect(resolution, isA<RemoteWorkspaceChangesUnavailable>());
    final unavailable = resolution as RemoteWorkspaceChangesUnavailable;
    expect(unavailable.announced, isFalse);
    expect(unavailable.scanned, remoteWorkspaceChangesFallbackScanSteps);
    expect(unavailable.limit, remoteWorkspaceChangesFallbackScanSteps);
    expect(
      [
        for (final params in transport.paramsOf('workspaceChanges.summary'))
          params['seq'],
      ],
      <int>[20, 19, 18, 17, 16],
      reason: '兜底只向前找 5 步，不允许变成连续几十次请求',
    );
  });

  test('本次变更：兜底扫描命中时带进度回调并返回快照', () async {
    final transport = FakeRemoteTransport();
    transport.answers['workspaceChanges.summary'] = (params) =>
        params['seq'] == 18
        ? <String, dynamic>{'ok': true, 'value': summaryPayload(turn: 4)}
        : unavailableEnvelope();
    final workspace = RemoteWorkspaceChangesLiveSource(
      link: workspaceConnection(transport),
      session: 's-1',
      events: () => <Map<String, dynamic>>[turnEvent(3, 'turn/end')],
      latest: () => 20,
    );
    addTearDown(workspace.dispose);

    final progress = <RemoteWorkspaceScanProgress>[];
    final resolution = await workspace.resolveSnapshot(
      onProgress: progress.add,
    );
    expect(resolution, isA<RemoteWorkspaceChangesFound>());
    expect((resolution as RemoteWorkspaceChangesFound).seq, 18);
    expect([for (final step in progress) step.attempt], <int>[1, 2, 3]);
    expect([for (final step in progress) step.seq], <int>[20, 19, 18]);
    expect(progress.first.limit, remoteWorkspaceChangesFallbackScanSteps);
  });

  test('本次变更：差异读取带 seq/index，畸形应答给出可读失败', () async {
    final transport = FakeRemoteTransport();
    transport.answers['workspaceChanges.diff'] = (_) => <String, dynamic>{
      'ok': true,
      'value': diffPayload(),
    };
    final workspace = RemoteWorkspaceChangesLiveSource(
      link: workspaceConnection(transport),
      session: 's-1',
      events: () => const <Map<String, dynamic>>[],
      latest: () => 5,
    );
    addTearDown(workspace.dispose);

    final diff = await workspace.loadDiff(5, 1);
    expect(diff.path, 'lib/a.dart');
    expect(diff.hunks.single.lines, <String>['-old', '+new']);
    final params = transport.paramsOf('workspaceChanges.diff').single;
    expect(params['sessionId'], 's-1');
    expect(params['seq'], 5);
    expect(params['index'], 1);
    expect(params['owner'], startsWith('remote-'));

    transport.answers['workspaceChanges.diff'] = (_) => <String, dynamic>{
      'ok': true,
      'value': <String, dynamic>{'kind': 'unknown'},
    };
    await expectLater(
      workspace.loadDiff(5, 0),
      throwsA(
        isA<RuntimeTransportFailure>().having(
          (failure) => failure.message,
          'message',
          '电脑返回的文件差异格式不正确。',
        ),
      ),
    );

    // 快照不存在时把 404 映射成可直接展示的中文降级说明。
    transport.answers['workspaceChanges.diff'] = (_) => unavailableEnvelope();
    await expectLater(
      workspace.loadDiff(5, 0),
      throwsA(
        isA<RuntimeTransportFailure>().having(
          (failure) => failure.message,
          'message',
          '这轮改动的内容已不可用。',
        ),
      ),
    );
  });

  test('本次变更：页面关闭时取消在途读取并忽略迟到结果', () async {
    final gate = Completer<Object?>();
    final transport = FakeRemoteTransport();
    transport.answers['workspaceChanges.summary'] = (_) => gate.future;
    final workspace = RemoteWorkspaceChangesLiveSource(
      link: workspaceConnection(transport),
      session: 's-1',
      events: () => <Map<String, dynamic>>[changesEvent(5)],
      latest: () => 8,
    );
    final pending = workspace.resolveSnapshot();
    await pumpEventQueue();
    final summary = transport.paramsOf('workspaceChanges.summary').single;

    workspace.dispose();
    await pumpEventQueue();

    final cancel = transport.paramsOf('workspaceChanges.cancel').single;
    expect(cancel['owner'], summary['owner']);
    expect(cancel['requestId'], summary['requestId']);

    gate.complete(<String, dynamic>{'ok': true, 'value': summaryPayload()});
    final resolution = await pending;
    expect(resolution, isA<RemoteWorkspaceChangesFailure>());
    expect((resolution as RemoteWorkspaceChangesFailure).message, '读取已取消。');
  });

  test('本次变更：会话数据源按方法表决定是否提供变更入口', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0), changesEvent(2)]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['workspaceChanges.summary'] = (_) => <String, dynamic>{
      'ok': true,
      'value': summaryPayload(),
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);

    // 宿主没有声明变更方法时，入口为 null（页面据此置灰）。
    final without = FakeRemoteConnection(
      transport: transport,
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
      },
    );
    final plain = RemoteConversationLiveSource(
      connection: without,
      sessionId: 's-1',
      events: events.stream,
    );
    addTearDown(plain.dispose);
    expect(plain.createWorkspaceChangesSource(), isNull);

    // 声明之后返回的数据源使用会话窗口里的 announcement 序号。
    final connected = FakeRemoteConnection(
      transport: transport,
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
        remoteWorkspaceChangesSummaryMethod,
        remoteWorkspaceChangesDiffMethod,
      },
    );
    final source = RemoteConversationLiveSource(
      connection: connected,
      sessionId: 's-1',
      events: events.stream,
    );
    addTearDown(source.dispose);
    await source.start();
    await pumpEventQueue();
    final workspace = source.createWorkspaceChangesSource();
    expect(workspace, isNotNull);
    final resolution = await workspace!.resolveSnapshot();
    expect(resolution, isA<RemoteWorkspaceChangesFound>());
    expect((resolution as RemoteWorkspaceChangesFound).seq, 2);
    workspace.dispose();
  });

  // ------------------------------------------------------------ 会话指令

  FakeRemoteConnection commandConnection(FakeRemoteTransport transport) =>
      FakeRemoteConnection(
        transport: transport,
        supported: <String>{
          remoteConversationReadMethod,
          remoteConversationSendMethod,
          remoteConversationCommandMethod,
        },
      );

  test('会话指令走 session.command 的线上参数与结果投影', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0)]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['session.command'] = (_) => <String, dynamic>{
      'commandId': 'cmd-1',
      'result': <String, dynamic>{'kind': 'success', 'text': '已进入计划模式'},
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final source = RemoteConversationLiveSource(
      connection: commandConnection(transport),
      sessionId: 's-1',
      events: events.stream,
    );
    addTearDown(source.dispose);
    await source.start();
    await pumpEventQueue();

    final success = await source.submitCommand('/plan 进入计划模式');
    expect(transport.paramsOf('session.command').single, {
      'sessionId': 's-1',
      'line': '/plan 进入计划模式',
      'attachmentIds': <String>[],
    });
    expect(success.kind, RemoteCommandKind.success);
    expect(success.text, '已进入计划模式');
    expect(success.commandId, 'cmd-1');
    expect(success.succeeded, isTrue);

    // 门面返回 null：没有识别出指令，什么都没执行。
    transport.answers['session.command'] = (_) => null;
    final unrecognized = await source.submitCommand('/nope');
    expect(unrecognized.kind, RemoteCommandKind.unrecognized);
    expect(unrecognized.text, isNull);
    expect(unrecognized.displayText, isNot(isEmpty));

    // 处理器明确失败时原样带上宿主文案。
    transport.answers['session.command'] = (_) => <String, dynamic>{
      'commandId': 'cmd-2',
      'result': <String, dynamic>{'kind': 'error', 'text': '还没有设置目标。'},
    };
    final failed = await source.submitCommand('/goal pause');
    expect(failed.kind, RemoteCommandKind.error);
    expect(failed.displayText, '还没有设置目标。');

    // 只回结果、不带执行信封的宿主同样可用。
    transport.answers['session.command'] = (_) => <String, dynamic>{
      'kind': 'success',
    };
    final bare = await source.submitCommand('/compact');
    expect(bare.kind, RemoteCommandKind.success);
    expect(bare.displayText, '指令已执行。');

    // 认不出的返回值按不完整应答处理，页面保留草稿并报错。
    transport.answers['session.command'] = (_) => <String, dynamic>{
      'commandId': 'cmd-3',
    };
    await expectLater(
      source.submitCommand('/plan'),
      throwsA(
        isA<RuntimeTransportFailure>().having(
          (failure) => failure.message,
          'message',
          '电脑返回的指令结果格式不正确。',
        ),
      ),
    );
  });

  // ------------------------------------------------------------ 模型路由预读

  Map<String, dynamic> routeCatalogPayload() => <String, dynamic>{
    'default': {'provider': 'deepseek-account', 'model': 'deepseek-flash'},
    'groups': <Object?>[
      {
        'id': 'deepseek-account',
        'name': 'DeepSeek 账号',
        'models': <Object?>[
          {'id': 'deepseek-flash', 'name': 'DeepSeek Flash'},
        ],
      },
    ],
    'failures': <Object?>[
      {
        'id': 'deepseek-official',
        'name': 'DeepSeek API',
        'message': '缺少 API Key',
      },
    ],
  };

  test('目录预读：打开与重连各读一次，同周期内路由变化复用缓存', () async {
    var catalogCalls = 0;
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) => _windowPayload([
      _modelSelectionEvent(
        0,
        provider: 'deepseek-official',
        model: 'deepseek-chat',
      ),
    ]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['api.call'] = (params) {
      if (params['method'] == 'modelCatalog') {
        catalogCalls++;
        return routeCatalogPayload();
      }
      if (params['method'] == 'selectModel') {
        return <String, dynamic>{
          'selected': {
            'provider': 'deepseek-official',
            'model': 'deepseek-chat',
          },
        };
      }
      return <String, dynamic>{};
    };
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final connection = FakeRemoteConnection(
      transport: transport,
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
        remoteConversationApiCallMethod,
      },
    );
    final source = RemoteConversationLiveSource(
      connection: connection,
      sessionId: 's-1',
      events: events.stream,
    );
    addTearDown(source.dispose);
    final updates = <RemoteConversationUpdate>[];
    addTearDown(source.updates.listen(updates.add).cancel);
    await source.start();
    await pumpEventQueue();

    expect(catalogCalls, 1, reason: '打开时预读一次目录');
    expect(
      updates
          .whereType<RemoteConversationModelAvailability>()
          .last
          .unavailableProviders,
      <String>{'deepseek-official'},
    );

    // 发送不读目录：预读只服务发送前提示。
    await source.send('你好');
    expect(catalogCalls, 1);

    // 电脑上换了路由：复用同周期的目录，不重新读。
    final subscribe = transport.paramsOf('api.subscribe').single;
    final streamId = subscribe['streamId'] as String;
    events.add(
      _item(streamId, 'generation-$streamId', 1, {
        'type': 'snapshot',
        'cursor': 1,
        'records': [
          {
            'type': 'event',
            'event': _modelSelectionEvent(
              0,
              provider: 'deepseek-account',
              model: 'deepseek-flash',
            ),
          },
        ],
        'hasMore': false,
      }),
    );
    await pumpEventQueue();
    expect(catalogCalls, 1, reason: '同一条连接内复用目录');
    expect(
      updates.whereType<RemoteConversationModel>().last.choice,
      const RemoteModelChoice(
        provider: 'deepseek-account',
        model: 'deepseek-flash',
      ),
      reason: '窗口快照把路由换成可用服务商；页面据此隐藏发送前提示',
    );
    expect(
      updates
          .whereType<RemoteConversationModelAvailability>()
          .last
          .unavailableProviders,
      <String>{'deepseek-official'},
      reason: '失败列表原样保留；可路由的 deepseek-account 不在不可用集合里',
    );

    // 会话内切换模型：用同一份目录重新判定，不重新读。
    await source.selectModel(
      const RemoteModelChoice(
        provider: 'deepseek-official',
        model: 'deepseek-chat',
      ),
    );
    expect(catalogCalls, 1);
    expect(
      updates.whereType<RemoteConversationModel>().last.choice,
      const RemoteModelChoice(
        provider: 'deepseek-official',
        model: 'deepseek-chat',
      ),
    );

    // 重连：先重读窗口，再重新预读一次目录。
    connection.setPhase(RemoteConnectionPhase.reconnecting);
    await pumpEventQueue();
    connection.setPhase(RemoteConnectionPhase.ready);
    await pumpEventQueue();
    await pumpEventQueue();
    expect(catalogCalls, 2, reason: '重连后重新预读一次目录');
  });

  test('目录读取失败不变成页面错误，发送照常', () async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) =>
        _windowPayload([fixture.header(0)]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['api.call'] = (_) => throw const RuntimeTransportFailure(
      code: 'gateway/internal',
      message: '目录暂时不可用。',
    );
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final connection = FakeRemoteConnection(
      transport: transport,
      supported: <String>{
        remoteConversationReadMethod,
        remoteConversationSendMethod,
        remoteConversationApiCallMethod,
      },
    );
    final source = RemoteConversationLiveSource(
      connection: connection,
      sessionId: 's-1',
      events: events.stream,
    );
    addTearDown(source.dispose);
    final updates = <RemoteConversationUpdate>[];
    addTearDown(source.updates.listen(updates.add).cancel);
    await source.start();
    await pumpEventQueue();

    expect(updates.whereType<RemoteConversationFailure>(), isEmpty);
    expect(
      updates
          .whereType<RemoteConversationModelAvailability>()
          .last
          .unavailableProviders,
      isEmpty,
      reason: '读不到目录时无法判定，页面不提示',
    );

    await source.send('仍然能发');
    expect(transport.paramsOf('session.send').single['text'], '仍然能发');
    // 首屏的 api.call 有两次：一次目录预读、一次会话洞察投影。两次都失败，
    // 但都只读一次，不重试也不变成页面错误（上面已断言没有失败更新）。
    final apiCalls = transport.paramsOf('api.call');
    expect(
      apiCalls.where((params) => params['method'] == 'modelCatalog'),
      hasLength(1),
      reason: '失败的目录读取只读一次',
    );
    expect(
      apiCalls.where((params) => params['method'] == 'projections'),
      hasLength(1),
      reason: '洞察投影只读一次，失败也不重试',
    );
  });

  // ------------------------------------------------ 模型路由可用性的第二路信号

  /// 目录里的一个分组：模型由调用方给，空列表表示这个服务商没有可用模型。
  Map<String, dynamic> modelGroup(
    String id, {
    List<Map<String, dynamic>> models = const <Map<String, dynamic>>[],
  }) => {'id': id, 'name': id, 'models': models};

  /// 会话模型目录的线形状。[routableProviders] 为 null 时不带该字段，模拟旧宿主。
  Map<String, dynamic> availabilityCatalog({
    List<Map<String, dynamic>> groups = const <Map<String, dynamic>>[],
    List<Map<String, dynamic>> failures = const <Map<String, dynamic>>[],
    List<String>? routableProviders,
  }) => {
    'default': {'provider': 'deepseek-account', 'model': 'deepseek-flash'},
    'routableProviders': ?routableProviders,
    'groups': groups,
    'failures': failures,
  };

  /// 把路由固定成 [provider]/[model] 打开一个真实数据源，目录由 [catalog] 应答。
  Future<
    ({
      RemoteConversationLiveSource source,
      List<RemoteConversationUpdate> updates,
    })
  >
  openAvailabilitySource({
    required Map<String, dynamic> catalog,
    String provider = 'deepseek-official',
    String model = 'deepseek-chat',
  }) async {
    final transport = FakeRemoteTransport();
    transport.answers['session.readWindow'] = (_) => _windowPayload([
      _modelSelectionEvent(0, provider: provider, model: model),
    ]);
    transport.answers['api.subscribe'] = (params) => {
      'streamId': params['streamId'],
      'generation': 'generation-${params['streamId']}',
    };
    transport.answers['interactions.list'] = (_) =>
        _interactionsPayload(revision: 0, requests: <Map<String, dynamic>>[]);
    transport.answers['api.call'] = (params) =>
        params['method'] == 'modelCatalog' ? catalog : <String, dynamic>{};
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    addTearDown(events.close);
    final attached = _attachSource(transport, events);
    await attached.source.start();
    await pumpEventQueue();
    return attached;
  }

  /// 最后一次可用性判定推给页面的服务商集合。
  Set<String> unavailableOf(List<RemoteConversationUpdate> updates) => updates
      .whereType<RemoteConversationModelAvailability>()
      .last
      .unavailableProviders;

  test('服务商静默缺席（不在 routableProviders、failures 为空）时判为不可用', () async {
    final attached = await openAvailabilitySource(
      catalog: availabilityCatalog(
        groups: [
          modelGroup(
            'deepseek-account',
            models: [
              {'id': 'deepseek-flash', 'name': 'DeepSeek Flash'},
            ],
          ),
        ],
        routableProviders: <String>['deepseek-account'],
      ),
    );

    expect(unavailableOf(attached.updates), <String>{
      'deepseek-official',
    }, reason: '无凭据的服务商既不在 failures、也不在任何分组里，页面据此显示发送前提示');
  });

  test('服务商在 failures 里时仍判为不可用（既有行为不回归）', () async {
    final attached = await openAvailabilitySource(
      catalog: availabilityCatalog(
        groups: [
          modelGroup(
            'deepseek-account',
            models: [
              {'id': 'deepseek-flash', 'name': 'DeepSeek Flash'},
            ],
          ),
        ],
        failures: [
          {
            'id': 'deepseek-official',
            'name': 'DeepSeek API',
            'message': '缺少 API Key',
          },
        ],
        routableProviders: <String>['deepseek-account'],
      ),
    );

    expect(unavailableOf(attached.updates), <String>{'deepseek-official'});
  });

  test('服务商在 routableProviders 里时不判为不可用', () async {
    final attached = await openAvailabilitySource(
      provider: 'deepseek-account',
      model: 'deepseek-flash',
      catalog: availabilityCatalog(
        groups: [
          modelGroup(
            'deepseek-account',
            models: [
              {'id': 'deepseek-flash', 'name': 'DeepSeek Flash'},
            ],
          ),
        ],
        routableProviders: <String>['deepseek-account'],
      ),
    );

    expect(unavailableOf(attached.updates), isEmpty);
  });

  test('旧宿主没有 routableProviders 时按非空分组兜底：可路由的服务商不误报', () async {
    final catalog = availabilityCatalog(
      groups: [
        modelGroup(
          'deepseek-account',
          models: [
            {'id': 'deepseek-flash', 'name': 'DeepSeek Flash'},
          ],
        ),
        // 旧宿主若把没有模型的分组也列出来，它同样不是可路由的服务商。
        modelGroup('deepseek-empty'),
      ],
    );

    final routable = await openAvailabilitySource(
      provider: 'deepseek-account',
      model: 'deepseek-flash',
      catalog: catalog,
    );
    expect(unavailableOf(routable.updates), isEmpty);

    final silent = await openAvailabilitySource(
      provider: 'deepseek-empty',
      model: 'deepseek-empty',
      catalog: catalog,
    );
    expect(unavailableOf(silent.updates), <String>{
      'deepseek-empty',
    }, reason: '空分组没有可用模型，不能兜底成可路由');
  });
}
