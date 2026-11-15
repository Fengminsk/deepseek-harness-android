// 远程会话页的「…」菜单终端入口：三态置灰与推入远程终端页。
//
// 这些测试不连宿主、不拨号：会话页用 `test/support/remote_conversation_fakes.dart`
// 的假数据源，终端连接面用 `test/support/remote_terminal_fakes.dart` 的假连接与
// 假传输，因此可以在没有 PC 在线的情况下验证入口、目的地标识与推入行为。

import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_dsh_conversation.dart';
import 'package:dsh_android/remote_dsh_page.dart';
import 'package:dsh_android/remote_terminal_page.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_test.dart' show LibraryRuntime;
import 'support/remote_conversation_fakes.dart';
import 'support/remote_terminal_fakes.dart';

/// 记录每次推入的路由名，用来核对终端页的目的地标识。
class _RouteLog extends NavigatorObserver {
  _RouteLog(this.names);

  /// 按推入顺序记录的路由名。
  final List<String?> names;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}

/// 会话页首屏窗口：一组最小的真实事件，页面因此停在正常会话而不是读取态。
RemoteConversationWindow _window() {
  final events = conversationEvents();
  return RemoteConversationWindow(
    events: events,
    throughSeq: events.last['seq'] as int,
    firstSeq: events.first['seq'] as int,
  );
}

/// 用 Pocket 主题把会话页挂成首页，与真实 App 的视觉/路由环境一致。
Widget _conversationHost(
  RemoteConversationSource source, {
  RemoteTerminalConnection? terminalConnection,
  List<String?>? routes,
}) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  navigatorObservers: <NavigatorObserver>[
    if (routes != null) _RouteLog(routes),
  ],
  home: RemoteDshConversationPage(
    source: source,
    deviceName: '客厅的电脑',
    projectName: 'Pocket',
    title: '修复登录',
    terminalConnection: terminalConnection,
  ),
);

/// 终端页写进路由名的稳定目的地标识。
final String _terminalRoute = destinationRouteName(
  RemoteSessionTerminalPage.routeDestination,
);

/// 打开「…」菜单；菜单项的三态与原因都在这里渲染。
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多会话操作'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('终端入口可用时推入远程终端页，目的地标识稳定且复用同一条连接', (tester) async {
    final transport = FakeTerminalTransport()
      ..answers['terminal.list'] = (_) => <Map<String, dynamic>>[];
    final connection = FakeRemoteTerminalConnection(transport: transport);
    addTearDown(connection.dispose);
    final routes = <String?>[];
    await tester.pumpWidget(
      _conversationHost(
        FakeRemoteConversationSource(window: _window()),
        terminalConnection: connection,
        routes: routes,
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester);
    expect(find.text('终端'), findsOneWidget);
    expect(find.byIcon(Icons.terminal_rounded), findsOneWidget);
    expect(find.text('这台电脑不支持终端'), findsNothing);
    expect(find.text('正在连接电脑…'), findsNothing);

    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();

    expect(routes, contains(_terminalRoute), reason: '终端页必须用页面自己的稳定标识作为路由名');
    final page = tester.widget<RemoteSessionTerminalPage>(
      find.byType(RemoteSessionTerminalPage),
    );
    expect(page.sessionId, 's-1');
    expect(page.connection, same(connection), reason: '终端页复用首页持有的连接');
    expect(
      transport.paramsOf('terminal.list').single['sessionId'],
      's-1',
      reason: '终端页的请求带当前会话标识',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('还没连上时终端入口置灰并说明正在连接，点击不推页', (tester) async {
    final connection = FakeRemoteTerminalConnection(
      phase: RemoteConnectionPhase.reconnecting,
    );
    addTearDown(connection.dispose);
    final routes = <String?>[];
    await tester.pumpWidget(
      _conversationHost(
        FakeRemoteConversationSource(window: _window()),
        terminalConnection: connection,
        routes: routes,
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester);
    expect(find.text('终端'), findsOneWidget);
    expect(find.text('正在连接电脑…'), findsOneWidget);

    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteSessionTerminalPage), findsNothing);
    expect(routes, isNot(contains(_terminalRoute)));
  });

  testWidgets('电脑没有声明终端方法时入口置灰并说明不支持，点击不推页', (tester) async {
    final connection = FakeRemoteTerminalConnection(
      transport: FakeTerminalTransport(),
      supported: <String>{},
    );
    addTearDown(connection.dispose);
    final routes = <String?>[];
    await tester.pumpWidget(
      _conversationHost(
        FakeRemoteConversationSource(window: _window()),
        terminalConnection: connection,
        routes: routes,
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester);
    expect(find.text('终端'), findsOneWidget);
    expect(find.text('这台电脑不支持终端'), findsOneWidget);

    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteSessionTerminalPage), findsNothing);
    expect(routes, isNot(contains(_terminalRoute)));
  });

  testWidgets('没有传入连接面时按这台电脑不支持终端置灰，点击不推页', (tester) async {
    final routes = <String?>[];
    await tester.pumpWidget(
      _conversationHost(
        FakeRemoteConversationSource(window: _window()),
        routes: routes,
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester);
    expect(find.text('终端'), findsOneWidget);
    expect(find.text('这台电脑不支持终端'), findsOneWidget);

    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteSessionTerminalPage), findsNothing);
    expect(routes, isNot(contains(_terminalRoute)));
  });

  testWidgets('远程首页打开会话时把首页持有的连接交给终端入口', (tester) async {
    final runtime = LibraryRuntime();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: RemoteDshPage(
          runtime: runtime,
          source: const FakeRemoteDshSource(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('remote-session-s-1')));
    await tester.pumpAndSettle();

    final page = tester.widget<RemoteDshConversationPage>(
      find.byType(RemoteDshConversationPage),
    );
    final connection = page.terminalConnection;
    expect(connection, isA<RemoteControllerTerminalConnection>());
    // 首页自建的连接控制器还没连上：入口处于 pending，而不是永久不支持。
    expect(
      RemoteTerminalCapability.of(connection!),
      RemoteTerminalCapability.pending,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
