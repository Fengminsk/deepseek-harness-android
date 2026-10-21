import 'package:dsh_android/approvals.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/read_only_presets.dart';

class _NavigationRuntime extends RuntimeController {
  final calls = <String>[];
  final presets = ReadOnlyPresets();

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    if (!presets.observes(namespace, method)) {
      throw StateError('Unexpected observation: $namespace.$method');
    }
    return presets.watch(args: args, resumeArgs: resumeArgs);
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (presets.handles(method, params)) return presets.reply(params);
    calls.add(method);
    if (method == 'interactions.list') {
      return {'revision': 1, 'requests': interactions};
    }
    throw StateError('Unexpected request: $method');
  }

  void publishNavigation() {
    navigationRequest = {
      'route': 'approval',
      'requestId': 'closed-request',
      'requestVersion': 4,
      'sessionId': 'old-session',
    };
    notifyListeners();
  }

  void readyNow() {
    phase = 'ready';
    notifyListeners();
  }

  @override
  void dispose() {
    presets.dispose();
    super.dispose();
  }
}

Widget _host(RuntimeController runtime) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: ChatPage(runtime: runtime),
);

void main() {
  testWidgets(
    'cold notification waits for runtime and opens without replying',
    (tester) async {
      final runtime = _NavigationRuntime()..publishNavigation();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      expect(find.byType(ApprovalsPage), findsNothing);
      expect(runtime.navigationRequest, isNotNull);

      runtime.readyNow();
      await tester.pumpAndSettle();
      expect(find.byType(ApprovalsPage), findsOneWidget);
      expect(runtime.navigationRequest, isNull);
      expect(find.text('请求已处理、撤回或此通知已失效'), findsOneWidget);
      expect(runtime.calls, ['interactions.list']);
    },
  );

  testWidgets('opening a notification keeps the conversation draft', (
    tester,
  ) async {
    final runtime = _NavigationRuntime()..readyNow();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(_host(runtime));
    await tester.pumpAndSettle();
    final composer = find.widgetWithText(TextField, '交给 Pocket Harness');
    await tester.enterText(composer, '还没发送的内容');
    runtime.publishNavigation();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('还没发送的内容'), findsOneWidget);
    expect(runtime.calls, ['interactions.list']);
    runtime.readyNow();
    await tester.pumpAndSettle();
    expect(find.byType(ApprovalsPage), findsNothing);
  });
}
