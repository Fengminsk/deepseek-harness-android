import 'dart:async';

import 'package:dsh_android/flclash/popup.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_document.dart';
import 'package:dsh_android/session_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_sidebar_test.dart' show SidebarHarness;
import 'library_test.dart' show LibraryRuntime, settle;

class SessionSidebarRuntime extends LibraryRuntime {
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method != 'api.call') return super.call(method, params);
    calls.add((method, Map.of(params)));
    if (params['namespace'] == 'session' && params['method'] == 'list') {
      return {'items': catalog['sessions']};
    }
    if (params['namespace'] == 'workspaceFiles' && params['method'] == 'list') {
      return {
        'path': '',
        'entries': [
          {'name': 'report.pdf', 'type': 'file', 'size': 1200},
        ],
        'truncated': false,
      };
    }
    throw StateError('Unexpected file operation: $params');
  }

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) => namespace == 'workspaceFiles'
      ? const Stream.empty()
      : super.watchApi(namespace, method, args: args, resumeArgs: resumeArgs);
}

void main() {
  testWidgets(
    'current chat file entry opens original Session reader without importing a file',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final runtime = SessionSidebarRuntime();
      final harness = SidebarHarness(runtime);
      await tester.pumpWidget(harness.host());
      await harness.open(tester);
      await tester.tap(find.byKey(const ValueKey('sidebar-more')));
      await settle(tester);
      expect(find.text('会话文件'), findsOneWidget);
      expect(find.byType(CommonPopupMenu), findsNothing);
      expect(find.text('我的文件'), findsOneWidget);
      await tester.tap(find.text('会话文件'));
      await settle(tester);
      expect(find.byType(SessionFilesPage), findsOneWidget);
      expect(find.text('/private/work'), findsOneWidget);
      expect(
        runtime.calls
            .where((call) => call.$1 == 'api.call')
            .map((call) => call.$2['method']),
        ['list', 'list'],
      );
      await tester.tap(find.text('report.pdf'));
      await settle(tester);
      final document = tester.widget<SessionDocumentPage>(
        find.byType(SessionDocumentPage),
      );
      expect(document.sessionId, 's2');
      expect(document.path, 'report.pdf');
      expect(
        runtime.calls.any((call) => call.$1.startsWith('attachments.')),
        false,
      );
      expect(runtime.calls.any((call) => call.$1 == 'session.ensure'), false);
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.linux}),
  );

  testWidgets('uncreated draft does not offer a fabricated Session workspace', (
    tester,
  ) async {
    final runtime = SessionSidebarRuntime();
    runtime.catalog['sessions'] = <Json>[];
    final harness = SidebarHarness(runtime);
    await tester.pumpWidget(harness.host());
    await harness.open(tester);
    await tester.tap(find.byKey(const ValueKey('sidebar-more')));
    await settle(tester);
    expect(find.text('会话文件'), findsNothing);
    expect(find.text('我的文件'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
