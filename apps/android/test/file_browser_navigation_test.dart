import 'dart:async';

import 'package:dsh_android/file_browser_chrome.dart';
import 'package:dsh_android/files.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:dsh_android/workspace_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class BrowserRuntime extends RuntimeController {
  BrowserRuntime(this.handle) {
    phase = 'ready';
  }
  final Future<dynamic> Function(String, Json) handle;
  final calls = <(String, Json)>[];
  @override
  Future<dynamic> call(String method, [Json params = const {}]) {
    calls.add((method, Map.of(params)));
    return handle(method, params);
  }
}

Future<void> mount(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      builder: (_, child) => MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

ScrollController browserScroll(WidgetTester tester) =>
    tester.widget<FileBrowserChrome>(find.byType(FileBrowserChrome)).controller;

Json listing(String path, List<Json> rows, {int offset = 0, int? next}) => {
  'root': '/private/workspace',
  'path': path,
  'version': 'v1',
  'offset': offset,
  'entries': rows,
  'nextOffset': next,
  'truncated': false,
};

void main() {
  testWidgets(
    'SAF folders stay on one route and a late child listing cannot replace its parent',
    (tester) async {
      final pending = Completer<List<Json>>();
      final runtime = BrowserRuntime((method, args) async {
        if (method == 'documents.roots') {
          return [
            {'id': 'grant', 'name': 'Documents', 'directory': true},
          ];
        }
        if (method == 'documents.list' && args['path'] == '') {
          return [
            {'name': 'Nested', 'directory': true},
          ];
        }
        if (method == 'documents.list' && args['path'] == 'Nested') {
          return pending.future;
        }
        throw StateError('Unexpected $method $args');
      });
      addTearDown(runtime.dispose);
      await mount(tester, FilesPage(runtime: runtime));
      await tap(tester, find.text('Documents'));
      await tap(tester, find.text('Nested'));
      expect(find.byType(FilesPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(runtime.calls.last.$2, {'root': 'grant', 'path': ''});
      pending.complete([
        {'name': 'late.txt', 'directory': false},
      ]);
      await tester.pumpAndSettle();
      expect(find.text('late.txt'), findsNothing);
      expect(find.text('Nested'), findsOneWidget);
      await tap(tester, find.byTooltip('返回上级'));
      expect(runtime.calls.last.$1, 'documents.roots');
      expect(find.byType(FilesPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'SAF return restores the parent scroll location after revalidation',
    (tester) async {
      final runtime = BrowserRuntime((method, args) async {
        if (method == 'documents.roots') {
          return [
            {'id': 'grant', 'name': 'Documents', 'directory': true},
          ];
        }
        if (args['path'] == '') {
          return List.generate(
            30,
            (index) => {'name': 'Folder $index', 'directory': true},
          );
        }
        return <Json>[];
      });
      addTearDown(runtime.dispose);
      await mount(tester, FilesPage(runtime: runtime));
      await tap(tester, find.text('Documents'));
      browserScroll(tester).jumpTo(1100);
      await tester.pumpAndSettle();
      final target = find.byType(FileBrowserEntry).hitTestable().first;
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      final offset = browserScroll(tester).offset;
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(find.text('此目录为空。'), findsOneWidget);
      await tap(tester, find.byTooltip('返回上级'));
      expect(browserScroll(tester).offset, closeTo(offset, 1));
      expect(find.byType(FilesPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'private directory return reloads enough versioned pages to restore its scroll position',
    (tester) async {
      final runtime = BrowserRuntime((method, args) async {
        if (method != 'workspace.files.list') throw StateError(method);
        final path = args['path'] as String;
        final offset = args['offset'] as int;
        if (path.isNotEmpty) return listing(path, []);
        return listing(
          '',
          List.generate(
            15,
            (index) => {
              'name': 'Folder ${offset + index}',
              'path': 'Folder ${offset + index}',
              'kind': 'directory',
            },
          ),
          offset: offset,
          next: offset == 0 ? 15 : null,
        );
      });
      addTearDown(runtime.dispose);
      await mount(tester, WorkspaceFilesPage(runtime: runtime));
      browserScroll(tester)
          .jumpTo(browserScroll(tester).position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tap(tester, find.text('更多目录项目'));
      browserScroll(tester).jumpTo(1200);
      await tester.pumpAndSettle();
      final target = find.byKey(const ValueKey('workspace-entry-Folder 18'));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      final offset = browserScroll(tester).offset;
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceFilesPage), findsOneWidget);
      await tap(tester, find.byTooltip('返回上级'));
      expect(runtime.calls.last.$2, {
        'path': '',
        'offset': 15,
        'version': 'v1',
      });
      expect(browserScroll(tester).offset, closeTo(offset, 1));
      expect(find.byType(WorkspaceFilesPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('workspace breadcrumbs supersede an unfinished directory read', (
    tester,
  ) async {
    final pending = Completer<Json>();
    final runtime = BrowserRuntime((method, args) async {
      if (args['path'] == 'Folder') return pending.future;
      return listing('', [
        {'name': 'Folder', 'path': 'Folder', 'kind': 'directory'},
      ]);
    });
    addTearDown(runtime.dispose);
    await mount(tester, WorkspaceFilesPage(runtime: runtime));
    await tap(tester, find.text('Folder'));
    await tap(tester, find.text('App 私有文件'));
    pending.complete(
      listing('Folder', [
        {'name': 'late.txt', 'path': 'Folder/late.txt', 'kind': 'file'},
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('late.txt'), findsNothing);
    expect(find.text('Folder'), findsOneWidget);
    expect(find.byType(WorkspaceFilesPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('add menu opens next to the floating add control', (
    tester,
  ) async {
    final runtime = BrowserRuntime((_, _) async => <Json>[]);
    addTearDown(runtime.dispose);
    await mount(tester, FilesPage(runtime: runtime));
    final anchor = tester.getRect(find.byTooltip('添加文件位置'));
    await tap(tester, find.byTooltip('添加文件位置'));
    final firstAction = tester.getRect(find.text('选择文件'));
    expect(firstAction.top, lessThan(anchor.bottom + 160));
    expect(firstAction.top, greaterThan(anchor.top));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
