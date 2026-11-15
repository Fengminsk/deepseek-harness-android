// 远程终端相关测试的假实现：不连宿主、不拨号、不读设备表。
//
// - [FakeTerminalTransport]：记录每一次门面请求，按方法注入应答、失败或错误信封，
//   因此可以逐字段核对 `terminal.*` 的参数；
// - [FakeRemoteTerminalConnection]：实现 `RemoteTerminalConnection`，阶段、方法表
//   与传输都可以直接改，用来驱动能力三态与断线重连；
// - 终端信息/屏幕/Shell 列表的小 fixture，让页面测试不必连真实 Android PTY。

import 'dart:async';

import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_terminal_page.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:flutter/foundation.dart';

/// 记录门面调用并允许注入应答/失败的传输替身。
class FakeTerminalTransport implements RuntimeTransport {
  /// 按调用顺序记录的方法名与参数。
  final List<({String method, Map<String, dynamic> params})> requests =
      <({String method, Map<String, dynamic> params})>[];

  /// 每个方法的应答工厂；没有配置时返回空对象。
  final Map<String, Object? Function(Map<String, dynamic> params)> answers =
      <String, Object? Function(Map<String, dynamic> params)>{};

  /// 每个方法抛出的失败；优先于 [answers]。
  final Map<String, RuntimeTransportFailure> failures =
      <String, RuntimeTransportFailure>{};

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// 全部调用过的方法名。
  List<String> get methods => [for (final request in requests) request.method];

  /// 某个方法收到的全部参数。
  List<Map<String, dynamic>> paramsOf(String method) => [
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
    final failure = failures[method];
    if (failure != null) throw failure;
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
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

/// 远程终端页需要的假连接：阶段、方法表与传输都可以直接改。
class FakeRemoteTerminalConnection extends ChangeNotifier
    implements RemoteTerminalConnection {
  /// 创建假连接。
  ///
  /// [transport] 为 null 表示还没连上；[supported] 缺省是全部终端方法，
  /// [phase] 缺省 ready；[lastError] 用于终止态的原因文案。
  FakeRemoteTerminalConnection({
    this.transport,
    Set<String>? supported,
    this.phase = RemoteConnectionPhase.ready,
    this.lastError,
  }) : supportedMethods =
           supported ??
           Set<String>.of(RemoteTerminalCapability.requiredMethods);

  /// 当前传输；未连上时为 null。
  @override
  RuntimeTransport? transport;

  /// 方法表里存在的方法。
  final Set<String> supportedMethods;

  @override
  RemoteConnectionPhase phase;

  @override
  String? lastError;

  @override
  bool supports(String method) => supportedMethods.contains(method);

  /// 切换阶段并通知监听者（传输另设，调用方负责让两者一致）。
  void setPhase(RemoteConnectionPhase next, {String? lastError}) {
    phase = next;
    this.lastError = lastError;
    notifyListeners();
  }

  /// 模拟一次断线重连：阶段先离开 ready 再回到 ready。
  ///
  /// 不换传输也能代表「同一条 wss 重连并重新握手」；[next] 非空时同时换传输，
  /// 覆盖「重新拨号」的路径。
  void reconnect({RuntimeTransport? next}) {
    phase = RemoteConnectionPhase.reconnecting;
    lastError = '与电脑的连接已断开。';
    notifyListeners();
    phase = RemoteConnectionPhase.handshaking;
    notifyListeners();
    if (next != null) transport = next;
    phase = RemoteConnectionPhase.ready;
    lastError = null;
    notifyListeners();
  }
}

/// 一份 `terminal.list` 的单项。
Map<String, dynamic> terminalInfo({
  String id = 'terminal-1',
  String sessionId = 'session-7',
  String name = '构建终端',
  String cwd = '/workspace',
  String state = 'running',
  int? exitCode,
}) => <String, dynamic>{
  'id': id,
  'sessionId': sessionId,
  'cwd': cwd,
  'name': name,
  'shellId': '/bin/bash',
  'cols': 8,
  'rows': 2,
  'state': state,
  'exitCode': ?exitCode,
};

/// 一份 `terminal.read` 返回：带结构化 `view`，形状与本地 Android 一致。
Map<String, dynamic> terminalRead({
  String id = 'terminal-1',
  String sessionId = 'session-7',
  String name = '构建终端',
  String state = 'running',
  int revision = 1,
  int cols = 8,
  int rows = 2,
  String display = 'hello',
  String? error,
}) => <String, dynamic>{
  ...terminalInfo(id: id, sessionId: sessionId, name: name, state: state),
  'revision': revision,
  'display': display,
  'error': ?error,
  'view': <String, dynamic>{
    'cols': cols,
    'rows': rows,
    'start': 0,
    'cursor': <String, dynamic>{'col': 0, 'row': 0},
    'cursorVisible': true,
    'cursorStyle': 'block',
    'cursorBlink': false,
    'lines': <Map<String, dynamic>>[
      <String, dynamic>{
        'wrapped': false,
        'runs': <Map<String, dynamic>>[
          <String, dynamic>{
            'text': 'bash\$ ',
            'fg': null,
            'bg': null,
            'bold': false,
            'dim': false,
            'inverse': false,
            'underline': false,
            'invisible': false,
            'cursor': false,
          },
        ],
      },
      <String, dynamic>{'wrapped': false, 'runs': <Map<String, dynamic>>[]},
    ],
  },
};

/// 一份 `terminal.shells` 返回：id 是那台电脑上的 shell 路径。
List<Map<String, dynamic>> terminalShells() => <Map<String, dynamic>>[
  <String, dynamic>{'id': '/bin/bash', 'label': 'bash'},
  <String, dynamic>{'id': '/bin/zsh', 'label': 'zsh'},
];
