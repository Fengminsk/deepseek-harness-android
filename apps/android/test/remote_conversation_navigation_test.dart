// 会话入口的导航回归：点会话必须走 `openDestination`，并把稳定标识
// `remote-session:<sessionId>` 写进路由名（AGENTS.md：全屏目的地不得叠层）。

import 'package:dsh_android/remote_dsh_conversation.dart';
import 'package:dsh_android/remote_dsh_page.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_test.dart' show LibraryRuntime;
import 'support/remote_conversation_fakes.dart';

/// 记录每次推入的路由名。
class _RouteLog extends NavigatorObserver {
  final List<String?> names = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}

void main() {
  testWidgets('打开会话走 openDestination 且带 remote-session:<id> 标识', (
    tester,
  ) async {
    final runtime = LibraryRuntime();
    addTearDown(runtime.dispose);
    final log = _RouteLog();
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        navigatorObservers: <NavigatorObserver>[log],
        home: RemoteDshPage(
          runtime: runtime,
          source: const FakeRemoteDshSource(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('remote-session-s-1'));
    expect(row, findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(
      log.names,
      contains(destinationRouteName('remote-session:s-1')),
      reason: '会话入口必须用页面自己给出的目的地标识',
    );
    expect(find.byType(RemoteDshConversationPage), findsOneWidget);

    // 返回首页后再点同一会话：仍然只有一层目的地，标识不变。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(RemoteDshConversationPage), findsNothing);

    await tester.tap(find.byKey(const ValueKey('remote-session-s-1')));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteDshConversationPage), findsOneWidget);
    expect(
      log.names.where(
        (name) => name == destinationRouteName('remote-session:s-1'),
      ),
      hasLength(2),
      reason: '每次从首页进入都是一次新的推入，不会叠加两层',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
