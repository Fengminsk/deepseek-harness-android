// 模型路由发送前提示（`p5-remaining-design.md` §5.3 的 C2 用例）。
//
// 与 `remote_conversation_page_test.dart` 的分工：那边用假数据源直接注入不可用
// 服务商集合；这里挂真实 `RemoteConversationLiveSource` 与假传输，证明目录里的
// `routableProviders` 对照确实能让「静默缺席」的服务商在发送前就出现提示。
//
// 页面没有为这个提示改过：提示条、`_routeConfirmed` 与集合 `contains` 语义都是
// 既有行为，本文件只从数据源侧驱动。

import 'dart:async';

import 'package:dsh_android/remote_conversation_live_source.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_dsh_conversation.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/remote_conversation_fakes.dart';

/// 发送前提示条的 key（页面 `_modelRouteNotice`）。
const ValueKey<String> _hintKey = ValueKey(
  'remote-conversation-model-route-hint',
);

/// 桌面创建、在只有账号凭据的电脑上不可用的路由。
const RemoteModelChoice _official = RemoteModelChoice(
  provider: 'deepseek-official',
  model: 'deepseek-chat',
);

/// 这台电脑上真正可路由的路由。
const RemoteModelChoice _flash = RemoteModelChoice(
  provider: 'deepseek-account',
  model: 'deepseek-flash',
);

Widget _host(RemoteConversationSource source) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: RemoteDshConversationPage(
    source: source,
    deviceName: '客厅的电脑',
    projectName: 'Pocket',
    title: '修复登录',
  ),
);

Map<String, dynamic> _windowPayload(List<Map<String, dynamic>> events) => {
  'events': events,
  'throughSeq': events.last['seq'] as int,
  'firstSeq': events.first['seq'] as int,
  'hasMore': false,
};

/// 窗口里的一条模型选择事件：把会话路由固定成 [provider]/[model]。
Map<String, dynamic> _modelSelectionEvent(
  int seq, {
  required String provider,
  required String model,
}) => {
  'seq': seq,
  'time': seq * 1000,
  'type': 'model/selection',
  'data': {'provider': provider, 'model': model},
};

/// 模型目录：只有账号服务商可路由，`failures` 为空。
///
/// 「桌面创建、路由为 `deepseek-official`、宿主只带账号凭据」正是这种形状：
/// 没有 API Key 的服务商返回空模型列表，既不成组也不报错。
Map<String, dynamic> _catalogPayload() => {
  'default': {'provider': 'deepseek-account', 'model': 'deepseek-flash'},
  'routableProviders': <String>['deepseek-account'],
  'groups': [
    {
      'id': 'deepseek-account',
      'name': 'DeepSeek 账号',
      'models': [
        {'id': 'deepseek-flash', 'name': 'DeepSeek Flash'},
      ],
    },
  ],
  'failures': <Object?>[],
};

/// 用真实数据源驱动会话页：路由固定为 [route]，目录固定为 [_catalogPayload]。
({RemoteConversationLiveSource source, FakeRemoteTransport transport})
_openSource(
  StreamController<Map<String, dynamic>> events, {
  required RemoteModelChoice route,
}) {
  final transport = FakeRemoteTransport();
  transport.answers['session.readWindow'] = (_) => _windowPayload([
    _modelSelectionEvent(0, provider: route.provider, model: route.model),
  ]);
  transport.answers['api.subscribe'] = (params) => {
    'streamId': params['streamId'],
    'generation': 'generation-${params['streamId']}',
  };
  transport.answers['interactions.list'] = (_) => <String, dynamic>{
    'revision': 0,
    'requests': <Object?>[],
  };
  transport.answers['api.call'] = (params) => switch (params['method']) {
    'modelCatalog' => _catalogPayload(),
    // 受理成功即用请求里的选择（数据源解析不到 selected 时原样采用）。
    'selectModel' => <String, dynamic>{},
    _ => <String, dynamic>{},
  };
  final connection = FakeRemoteConnection(
    transport: transport,
    supported: <String>{
      remoteConversationReadMethod,
      remoteConversationSendMethod,
      remoteConversationApiCallMethod,
      remoteConversationInteractionsListMethod,
    },
  );
  final source = RemoteConversationLiveSource(
    connection: connection,
    sessionId: 's-1',
    events: events.stream,
  );
  return (source: source, transport: transport);
}

/// 建一个空的事件流；测试不注入增量，只保留连接层的入站通道。
StreamController<Map<String, dynamic>> _events() {
  final controller = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  addTearDown(controller.close);
  return controller;
}

void main() {
  testWidgets('安静缺席的服务商在发送前显示提示', (tester) async {
    final events = _events();
    final (:source, transport: _) = _openSource(events, route: _official);
    addTearDown(source.dispose);

    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();

    expect(find.byKey(_hintKey), findsOneWidget);
    expect(
      find.textContaining('当前会话绑定的模型在电脑上不可用，发送时会自动改用电脑默认模型'),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(_hintKey), matching: find.text('选择模型')),
      findsOneWidget,
    );
  });

  testWidgets('切到可用路由后提示消失，且复用同一份目录', (tester) async {
    final events = _events();
    final (:source, :transport) = _openSource(events, route: _official);
    addTearDown(source.dispose);

    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();
    expect(find.byKey(_hintKey), findsOneWidget);

    await source.selectModel(_flash);
    await tester.pumpAndSettle();

    expect(
      find.byKey(_hintKey),
      findsNothing,
      reason: '新路由的服务商在 routableProviders 里',
    );
    expect(
      transport
          .paramsOf('api.call')
          .where((params) => params['method'] == 'modelCatalog'),
      hasLength(1),
      reason: '同周期内复用预读的目录，不为判定再读一次',
    );
  });

  testWidgets('同一路由成功发送后不再显示提示', (tester) async {
    final events = _events();
    final (:source, :transport) = _openSource(events, route: _official);
    addTearDown(source.dispose);

    await tester.pumpWidget(_host(source));
    await tester.pumpAndSettle();
    expect(find.byKey(_hintKey), findsOneWidget);

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote-send')));
    await tester.pumpAndSettle();

    expect(
      transport.paramsOf(remoteConversationSendMethod).single['text'],
      '你好',
    );
    expect(find.byKey(_hintKey), findsNothing, reason: '发送成功说明这条路由实际可用，提示不再出现');
  });
}
