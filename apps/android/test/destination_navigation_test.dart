import 'dart:async';

import 'package:dsh_android/chat_sidebar.dart';
import 'package:dsh_android/remote_dsh_page.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'library_test.dart' show LibraryRuntime;

/// 目的地导航的回归测试：同一个目的地不能在栈上叠第二层。
///
/// 缺陷现场：侧栏进入「远程 DSH」后该项高亮，再点一次却又压入一层同样的页面；
/// 那层页面同样挂出侧栏，于是可以无限套娃。修复把「目的地标识」写进路由名，
/// 由 [openDestination] 在推入前判断是否已经站在该目的地上。

/// 探针首页：按钮用固定标识推入一层。
class _ProbeHome extends StatelessWidget {
  /// 探针使用的一次性目的地标识。
  static const destination = 'probe-destination';

  const _ProbeHome({required this.opened});

  /// 每次点击计数，用来确认入口确实被点到过。
  final ValueNotifier<int> opened;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const ValueKey('probe-open'),
        onPressed: () {
          opened.value += 1;
          unawaited(
            openDestination<void>(
              context,
              destination: destination,
              dragBack: false,
              builder: (_) => _ProbePage(opened: opened),
            ),
          );
        },
        child: const Text('进入探针'),
      ),
    ),
  );
}

/// 探针目的地：用同一标识再进一次，验证第二次不推入。
class _ProbePage extends StatelessWidget {
  const _ProbePage({required this.opened});

  final ValueNotifier<int> opened;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const ValueKey('probe-page'),
    body: Center(
      child: TextButton(
        key: const ValueKey('probe-reopen'),
        onPressed: () => unawaited(
          openDestination<void>(
            context,
            destination: _ProbeHome.destination,
            dragBack: false,
            builder: (_) => _ProbePage(opened: opened),
          ),
        ),
        child: const Text('再进一次'),
      ),
    ),
  );
}

/// 记录每次推入的路由名；不渲染页面内容，因此不会触发目的地的网络读取。
class _RouteLog extends NavigatorObserver {
  /// 按推入顺序记录的路由名。
  final List<String?> names = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}

void main() {
  testWidgets('openDestination 不把同一目的地叠第二层', (tester) async {
    final opened = ValueNotifier<int>(0);
    addTearDown(opened.dispose);
    await tester.pumpWidget(MaterialApp(home: _ProbeHome(opened: opened)));

    await tester.tap(find.byKey(const ValueKey('probe-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('probe-page')), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.byKey(const ValueKey('probe-page'))))
          ?.settings
          .name,
      destinationRouteName(_ProbeHome.destination),
      reason: '目的地标识必须写进路由名，否则栈顶判断失明',
    );

    // 页面里再点同一项：既不新增路由，也不再叠一层同样的页面。
    await tester.tap(find.byKey(const ValueKey('probe-reopen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('probe-page')), findsOneWidget);

    // 返回一次就回到首页——若真的叠了两层，这里仍会停在探针页。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('probe-open')), findsOneWidget);
  });

  testWidgets('侧栏的远程 DSH 入口带 remote-dsh 目的地标识', (tester) async {
    final runtime = LibraryRuntime();
    addTearDown(runtime.dispose);
    final scaffold = GlobalKey<ScaffoldState>();
    final log = _RouteLog();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: <NavigatorObserver>[log],
        theme: pocketTheme(Brightness.light),
        home: Scaffold(
          key: scaffold,
          body: const Text('聊天主页'),
          drawer: ChatSidebar(
            runtime: runtime,
            currentSessionId: 's2',
            onClose: () => scaffold.currentState?.closeDrawer(),
            onNewChat: () {},
            onSelectSession: (_) {},
            onOpenTasks: () {},
            onOpenAutomations: () {},
          ),
        ),
      ),
    );
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();

    // 只点到推入那一刻：不 pump，目的地页面不构建，测试也就不依赖它的网络读取。
    await tester.tap(find.byKey(const ValueKey('sidebar-remote-dsh')));
    expect(
      log.names,
      contains(destinationRouteName('remote-dsh')),
      reason: '侧栏入口必须用 remote-dsh 作为目的地标识，'
          '否则在远程页里再点一次仍会压入第二层',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('远程 DSH 页面自己的入口沿用同一个标识', (tester) async {
    // 页面把 remote-dsh 交给侧栏做高亮；标识必须与推入时一致。
    expect(RemoteDshPage.routeDestination, 'remote-dsh');
    expect(
      destinationRouteName(RemoteDshPage.routeDestination),
      destinationRouteName('remote-dsh'),
    );
  });
}
