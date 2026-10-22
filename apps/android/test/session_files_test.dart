import 'dart:async';

import 'package:dsh_android/file_browser_chrome.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_files.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json listing(List<Json> entries, {String path = '', bool truncated = false}) =>
    {'path': path, 'entries': entries, 'truncated': truncated};
Json entry(String name, {String type = 'file', int? size}) => {
  'name': name,
  'type': type,
  'size': ?size,
};

class FileRuntime extends RuntimeController {
  FileRuntime() {
    phase = 'ready';
  }
  int connection = 1;
  @override
  int get connectionGeneration => connection;
  List<Json> metadata = [
    {'sessionId': 'cold', 'cwd': '/original/project', 'agentAvailable': false},
    {'sessionId': 'second', 'cwd': '/another/project', 'agentAvailable': false},
  ];
  final calls = <Json>[];
  final watched = <Json>[];
  final streams = <StreamController<Json>>[];
  int cancelled = 0;
  Future<dynamic> Function(Json)? read;
  Future<dynamic> Function()? readMetadata;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    expectSync(method, 'api.call', reason: 'Browsing must not resume an Agent');
    calls.add(Map.of(params));
    if (params['namespace'] == 'session' && params['method'] == 'list') {
      expectSync(params['args'], {'_request': <String, dynamic>{}});
      return readMetadata == null ? {'items': metadata} : await readMetadata!();
    }
    expectSync(params['namespace'], 'workspaceFiles');
    expectSync(params['method'], 'list');
    expectSync(
      (params['args'] as Json).keys,
      unorderedEquals(['workspaceFileScopeId', 'path']),
    );
    return read == null ? listing([]) : await read!(params['args'] as Json);
  }

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    expectSync(namespace, 'workspaceFiles');
    expectSync(method, 'changes');
    watched.add(Map.of(args));
    final stream = StreamController<Json>.broadcast(
      sync: true,
      onCancel: () => cancelled++,
    );
    streams.add(stream);
    return stream.stream;
  }

  void emit(Json value, {int? stream}) => streams[stream ?? streams.length - 1]
      .add({'type': 'item', 'value': value});

  void connectionChanged(String next) {
    phase = next;
    connection++;
    notifyListeners();
  }

  List<Json> get reads =>
      calls.where((call) => call['namespace'] == 'workspaceFiles').toList();

  @override
  void dispose() {
    for (final stream in streams) {
      unawaited(stream.close());
    }
    super.dispose();
  }
}

Future<void> mount(
  WidgetTester tester,
  FileRuntime runtime, {
  String sessionId = 'cold',
  OpenSessionDocument? open,
}) async {
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
      home: SessionFilesPage(
        runtime: runtime,
        sessionId: sessionId,
        onOpenDocument: open ?? (_, _, _) async {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'cold Session uses original cwd, exact wire scope and natural directory-first order',
    (tester) async {
      final runtime = FileRuntime()
        ..read = (_) async => listing([
          entry('file10.txt'),
          entry('file2.txt'),
          entry('.env'),
          entry('Dir10', type: 'directory'),
          entry('dir2', type: 'directory'),
          entry('socket', type: 'other'),
        ], truncated: true);
      final model = SessionFilesController(runtime, 'cold')..start();
      await tester.pump();
      expect(
        model.error,
        isNull,
        reason: '${runtime.calls} / ${runtime.watched}',
      );
      expect(model.root, '/original/project');
      expect(model.entries.map((row) => row['name']), [
        'dir2',
        'Dir10',
        '.env',
        'file2.txt',
        'file10.txt',
        'socket',
      ]);
      expect(runtime.watched.single, {
        'workspaceFileScopeId': 'cold',
        'path': '/original/project',
      });
      expect(runtime.reads.single['args'], runtime.watched.single);
      expect(model.truncated, true);
      expect(runtime.calls.length, 2);
      model.dispose();
      expect(runtime.cancelled, 1);
      runtime.dispose();
    },
  );

  testWidgets(
    'missing cwd does not substitute a private or process directory',
    (tester) async {
      final runtime = FileRuntime()
        ..metadata = [
          {'sessionId': 'cold'},
        ];
      final model = SessionFilesController(runtime, 'cold')..start();
      await tester.pump();
      expect(model.noWorkspace, true);
      expect(model.root, null);
      expect(runtime.reads, isEmpty);
      expect(runtime.watched, isEmpty);
      model.dispose();
      runtime.dispose();
    },
  );

  testWidgets('deleted Session is refused without creating one', (
    tester,
  ) async {
    final runtime = FileRuntime()..metadata = [];
    final model = SessionFilesController(runtime, 'cold')..start();
    await tester.pump();
    expect(model.error, contains('会话已不存在'));
    expect(runtime.calls.length, 1);
    expect(runtime.watched, isEmpty);
    model.dispose();
    runtime.dispose();
  });

  testWidgets(
    'directory changes retire old observations and ignore late listings',
    (tester) async {
      final delayed = Completer<dynamic>();
      final runtime = FileRuntime()
        ..read = (args) async => args['path'] == '/original/project/child'
            ? delayed.future
            : listing([entry('root.txt')]);
      final model = SessionFilesController(runtime, 'cold')..start();
      await tester.pump();
      model.navigate('child');
      await tester.pump();
      model.navigate('');
      await tester.pump();
      delayed.complete(listing([entry('late.txt')], path: 'child'));
      runtime.emit({
        'kind': 'change',
        'change': {'absolutePath': '/original/project/child', 'version': 'old'},
      }, stream: 1);
      await tester.pump();
      expect(model.path, '');
      expect(model.entries.single['name'], 'root.txt');
      expect(runtime.reads.length, 3);
      expect(runtime.cancelled, 2);
      model.dispose();
      runtime.dispose();
    },
  );

  testWidgets(
    'watch readiness closes the initial read gap and coalesces invalidations',
    (tester) async {
      final delayed = Completer<dynamic>();
      final runtime = FileRuntime();
      var count = 0;
      runtime.read = (_) async =>
          ++count == 1 ? delayed.future : listing([entry('new.txt')]);
      final model = SessionFilesController(runtime, 'cold')..start();
      await tester.pump();
      runtime.emit({'kind': 'ready'});
      for (var i = 0; i < 5; i++) {
        runtime.emit({
          'kind': 'change',
          'change': {'absolutePath': '/original/project', 'version': 'same'},
        });
      }
      expect(count, 1);
      delayed.complete(listing([entry('old.txt')]));
      await tester.pump();
      expect(count, 2);
      expect(model.entries.single['name'], 'new.txt');
      runtime.emit({
        'kind': 'change',
        'change': {'absolutePath': '/original/project', 'version': 'same'},
      });
      await tester.pump();
      expect(
        count,
        3,
        reason: 'A repeated directory version still invalidates child metadata',
      );
      model.dispose();
      runtime.dispose();
    },
  );

  testWidgets(
    'watch unsupported keeps a readable snapshot and exposes manual refresh',
    (tester) async {
      final runtime = FileRuntime()
        ..read = (_) async => listing([entry('known.txt')]);
      final model = SessionFilesController(runtime, 'cold')..start();
      await tester.pump();
      runtime.streams.last.addError(
        PlatformException(code: 'workspace-file/watch-unsupported'),
      );
      await tester.pump();
      expect(model.current, true);
      expect(model.watchNotice, contains('手动刷新'));
      await model.refresh();
      expect(runtime.reads.length, 2);
      model.dispose();
      runtime.dispose();
    },
  );

  testWidgets('paused automatic updates retain dirty state until resumed', (
    tester,
  ) async {
    final runtime = FileRuntime();
    final model = SessionFilesController(runtime, 'cold')..start();
    await tester.pump();
    model.setAutomatic(false);
    runtime.emit({
      'kind': 'change',
      'change': {'absolutePath': '/original/project', 'absent': true},
    });
    await tester.pump();
    expect(runtime.reads.length, 1);
    model.setAutomatic(true);
    await tester.pump();
    expect(runtime.reads.length, 2);
    model.dispose();
    runtime.dispose();
  });

  testWidgets(
    'connection change invalidates reads and rereads authoritative Session cwd',
    (tester) async {
      final delayed = Completer<dynamic>();
      final runtime = FileRuntime()..read = (_) => delayed.future;
      final model = SessionFilesController(runtime, 'cold')..start();
      await tester.pump();
      runtime.connectionChanged('disconnected');
      expect(model.canOpen, false);
      delayed.complete(listing([entry('stale.txt')]));
      await tester.pump();
      expect(model.entries, isEmpty);
      runtime.metadata = [
        {'sessionId': 'cold', 'cwd': '/updated/project'},
      ];
      runtime.read = (_) async => listing([entry('fresh.txt')]);
      runtime.connectionChanged('ready');
      await tester.pump();
      expect(model.root, '/updated/project');
      expect(runtime.watched.last['path'], '/updated/project');
      expect(model.entries.single['name'], 'fresh.txt');
      model.dispose();
      runtime.dispose();
    },
  );

  testWidgets('stream reconnect cannot accept a pre-disconnect read', (
    tester,
  ) async {
    final delayed = Completer<dynamic>();
    final runtime = FileRuntime()..read = (_) => delayed.future;
    final model = SessionFilesController(runtime, 'cold')..start();
    await tester.pump();
    runtime.streams.last.add({'type': 'disconnected'});
    delayed.complete(listing([entry('stale.txt')]));
    await tester.pump();
    expect(model.current, false);
    expect(model.entries, isEmpty);
    runtime.read = (_) async => listing([entry('fresh.txt')]);
    runtime.emit({'kind': 'ready'});
    await tester.pump();
    expect(model.entries.single['name'], 'fresh.txt');
    model.dispose();
    runtime.dispose();
  });

  testWidgets(
    'same page navigation restores parent scroll and opens every file through Session identity',
    (tester) async {
      final opened = <(String, String)>[];
      final runtime = FileRuntime()
        ..read = (args) async => args['path'] == '/original/project'
            ? listing(
                List.generate(35, (i) => entry('Folder $i', type: 'directory')),
              )
            : listing([entry('report.pdf', size: 4000)]);
      await mount(
        tester,
        runtime,
        open: (_, session, path) async => opened.add((session, path)),
      );
      final scroll = tester
          .widget<FileBrowserChrome>(find.byType(FileBrowserChrome))
          .controller;
      scroll.jumpTo(1050);
      await tester.pumpAndSettle();
      final row = find.byType(FileBrowserEntry).hitTestable().last;
      final name = tester.widget<FileBrowserEntry>(row).name;
      final offset = scroll.offset;
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(SessionFilesPage), findsOneWidget);
      expect(find.text('/original/project'), findsOneWidget);
      await tester.tap(find.text('report.pdf'));
      await tester.pumpAndSettle();
      expect(opened, [('cold', '$name/report.pdf')]);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(offset, 1));
      expect(find.byType(SessionFilesPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
      runtime.dispose();
    },
  );

  testWidgets(
    'Session switch on the same widget cannot receive an old Session listing',
    (tester) async {
      final delayed = Completer<dynamic>();
      final runtime = FileRuntime()
        ..read = (args) async => args['workspaceFileScopeId'] == 'cold'
            ? delayed.future
            : listing([entry('second.txt')]);
      await mount(tester, runtime);
      await mount(tester, runtime, sessionId: 'second');
      delayed.complete(listing([entry('old-session.txt')]));
      await tester.pumpAndSettle();
      expect(find.text('second.txt'), findsOneWidget);
      expect(find.text('old-session.txt'), findsNothing);
      expect(find.text('/another/project'), findsOneWidget);
      expect(runtime.cancelled, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
    },
  );

  testWidgets('truncated listing and unsupported entries remain explicit', (
    tester,
  ) async {
    final runtime = FileRuntime()
      ..read = (_) async =>
          listing([entry('socket', type: 'other')], truncated: true);
    await mount(tester, runtime);
    expect(find.text('目录项目超过服务的读取上限，当前列表不完整。'), findsOneWidget);
    expect(find.text('此类型无法打开'), findsOneWidget);
    expect(
      tester.widget<FileBrowserEntry>(find.byType(FileBrowserEntry)).onTap,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
