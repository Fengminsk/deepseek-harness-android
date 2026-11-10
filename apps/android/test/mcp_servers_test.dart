import 'dart:async';

import 'package:dsh_android/mcp_servers.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }

  final streams = <StreamController<Json>>[];
  final calls = <(String, Json)>[];
  dynamic probeResult = {'ok': true};

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    if ((namespace, method) != ('mcpManager', 'watch')) {
      throw StateError('Unexpected fixture stream $namespace.$method');
    }
    final stream = StreamController<Json>();
    streams.add(stream);
    return stream.stream;
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, Map.of(params)));
    if (method != 'api.call') throw StateError('Unexpected $method');
    return switch (params['method']) {
      'probe' => probeResult,
      'restart' => null,
      _ => throw StateError('Unexpected api ${params['method']}'),
    };
  }
}

Map<String, dynamic> _server(
  String name, {
  String state = 'connected',
  int? toolCount = 3,
  bool configured = true,
  String? lastError,
  int? attempt,
  int? maxAttempts,
}) => {
  'name': name,
  'configured': configured,
  'status': {
    'state': state,
    'toolCount': ?toolCount,
    'lastError': ?lastError,
    'attempt': ?attempt,
    'maxAttempts': ?maxAttempts,
  },
};

Future<void> _open(WidgetTester tester, _Runtime runtime) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: McpServersPage(runtime: runtime),
    ),
  );
  await tester.pump();
}

Future<void> _emit(WidgetTester tester, _Runtime runtime, List<Json> rows) async {
  runtime.streams.last.add({'type': 'item', 'value': rows});
  await tester.pumpAndSettle();
}

void main() {
  test('watch frames decode server rows and reject malformed ones', () {
    final rows = mcpServersFrom([
      _server('filesystem', toolCount: 4),
      _server('browser', state: 'disabled', toolCount: null),
      _server('retired', configured: false, state: 'closed', toolCount: null),
    ]);
    expect(rows, hasLength(3));
    expect(rows[0].name, 'filesystem');
    expect(rows[0].toolCount, 4);
    expect(rows[1].state, 'disabled');
    expect(rows[2].addressable, isFalse);
    expect(() => mcpServersFrom({'not': 'a list'}), throwsFormatException);
    expect(
      () => mcpServersFrom([
        {'name': 'x', 'configured': true, 'status': 'bad'},
      ]),
      throwsFormatException,
    );
  });

  test('status labels cover every manager state', () {
    expect(mcpStatusLabel(const McpServerRow(name: 'a', configured: true, state: 'connected', toolCount: 2)), '已连接 · 2 个工具');
    expect(mcpStatusLabel(const McpServerRow(name: 'a', configured: true, state: 'connecting', attempt: 2)), '正在连接（第 2 次）');
    expect(mcpStatusLabel(const McpServerRow(name: 'a', configured: true, state: 'reconnecting', attempt: 1, maxAttempts: 5)), '正在重连（1/5）');
    expect(mcpStatusLabel(const McpServerRow(name: 'a', configured: true, state: 'waiting-credentials')), '等待凭据');
    expect(mcpStatusLabel(const McpServerRow(name: 'a', configured: true, state: 'disabled')), '已停用');
    expect(mcpStatusLabel(const McpServerRow(name: 'a', configured: true, state: 'failed', lastError: 'boom')), '失败：boom');
  });

  test('summary counts connected servers and names the empty case', () {
    expect(mcpSummary(const []), '未配置 MCP 服务器');
    expect(
      mcpSummary(const [
        McpServerRow(name: 'a', configured: true, state: 'connected'),
        McpServerRow(name: 'b', configured: true, state: 'disabled'),
      ]),
      '2 个服务器 · 1 个已连接',
    );
  });

  testWidgets('live rows render with status and expose restart and probe', (tester) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    expect(find.text('正在读取 MCP 服务器'), findsOneWidget);
    await _emit(tester, runtime, const []);
    expect(find.text('未配置 MCP 服务器'), findsOneWidget);
    await _emit(tester, runtime, [
      _server('filesystem', toolCount: 4),
      _server('browser', state: 'failed', lastError: 'refused', toolCount: null),
    ]);
    expect(find.text('filesystem'), findsOneWidget);
    expect(find.text('已连接 · 4 个工具'), findsOneWidget);
    expect(find.text('失败：refused'), findsOneWidget);

    await tester.tap(find.byTooltip('重启服务器').first);
    await tester.pumpAndSettle();
    final restart = runtime.calls.last;
    expect(restart.$1, 'api.call');
    expect(restart.$2['namespace'], 'mcpManager');
    expect(restart.$2['method'], 'restart');
    expect(restart.$2['args'], {'name': 'filesystem'});

    await tester.tap(find.byTooltip('探测连接').first);
    await tester.pumpAndSettle();
    expect(find.text('探测 filesystem'), findsOneWidget);
    expect(find.textContaining('连接成功'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('a failed probe reports its stage instead of claiming success', (tester) async {
    final runtime = _Runtime()
      ..probeResult = {'ok': false, 'stage': 'connect', 'message': 'ECONNREFUSED'};
    await _open(tester, runtime);
    await _emit(tester, runtime, [_server('browser')]);
    await tester.tap(find.byTooltip('探测连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('探测失败（connect）'), findsOneWidget);
    expect(find.textContaining('ECONNREFUSED'), findsOneWidget);
  });

  testWidgets('the config entry links to the owning settings form', (tester) async {
    final runtime = _Runtime()..forms = [
      {'ns': 'mcp-manager', 'value': {}},
    ];
    await _open(tester, runtime);
    expect(find.text('编辑服务器配置'), findsOneWidget);
    final withoutForm = _Runtime();
    await _open(tester, withoutForm);
    expect(find.textContaining('没有可编辑的 mcp-manager 配置'), findsOneWidget);
  });
}
