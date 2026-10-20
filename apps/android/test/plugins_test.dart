import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/plugins.dart';
import 'package:dsh_android/plugins_data.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';

Json bundle() => {
  'name': '@example/bundle',
  'version': '1.0.0',
  'availability': 'profile',
  'installed': true,
  'enabled': false,
  'removable': true,
  'optional': false,
  'official': false,
  'rows': [
    {'rowId': 'tool', 'moduleName': '@example/tool', 'entryId': 'include:tool'},
  ],
  'overrides': [],
};
Json entry({bool protected = false}) => {
  'entryId': 'include:tool',
  'moduleName': '@example/tool',
  'enabled': false,
  'fiberPhase': null,
  if (protected) 'readOnlyReason': 'management-required',
};

class PluginsRuntime extends RuntimeController {
  final eventsController = StreamController<Json>.broadcast();
  @override
  Stream<Json> get remoteEvents => eventsController.stream;
  bool managed = true;
  List<Json> bundles = [bundle()], entries = [entry()];
  final calls = <Json>[];
  Completer<Json>? installing;
  bool failInstall = false;
  Json outcome = {
    'changed': true,
    'application': 'applied',
    'stage': 'install',
    'target': '@example/new',
    'bundle': '@example/new',
  };
  String cancelStatus = 'too-late';
  Json? recovered;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add({'method': method, 'params': cloneConfiguration(params)});
    if (method != 'api.call') throw StateError('Unexpected method');
    if (params['namespace'] == 'pluginInventory') {
      return {
        'managementAvailable': managed,
        'entries': entries,
        'agentPresets': [],
      };
    }
    switch (params['method']) {
      case 'listPlugins':
        return entries;
      case 'listBundles':
        return bundles;
      case 'inspect':
        return {
          'status': 'accepted',
          'kind': 'registry',
          'name': '@example/new',
          'version': '1.0.0',
          'bundle': true,
          'registry': null,
        };
      case 'setPluginEnabled':
      case 'setBundleEnabled':
        return {
          'changed': true,
          'application': 'restart-required',
          'restartReason': 'no-hmr',
        };
      case 'removeBundle':
        bundles = [];
        return {'changed': true, 'application': 'applied'};
      case 'installBundle':
        if (failInstall) {
          throw PlatformException(
            code: 'transport',
            message: 'lost acknowledgement',
          );
        }
        return installing?.future ?? outcome;
      case 'cancelInstall':
        return {'status': cancelStatus};
      case 'waitForInstall':
        return recovered;
    }
    throw StateError('Unexpected API $params');
  }

  @override
  void dispose() {
    unawaited(eventsController.close());
    super.dispose();
  }
}

List<Json> methods(PluginsRuntime runtime, String method) =>
    runtime.calls.where((call) => call['params']['method'] == method).toList();

Future<PluginsController> ready(PluginsRuntime runtime) async {
  final controller = PluginsController(runtime);
  addTearDown(controller.dispose);
  addTearDown(runtime.dispose);
  await controller.load();
  return controller;
}

Future<void> checked(PluginsController controller) async {
  controller.editSpec('@example/new');
  await controller.inspect();
}

Future<void> mount(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(theme: pocketTheme(Brightness.light), home: child),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'inventory management availability gates mutations and management reads',
    () async {
      final runtime = PluginsRuntime()..managed = false;
      final controller = await ready(runtime);
      expect(controller.entries, hasLength(1));
      expect(methods(runtime, 'listBundles'), isEmpty);
      await controller.change('include:tool', 'setPluginEnabled', {
        'id': 'include:tool',
        'enabled': true,
      });
      expect(methods(runtime, 'setPluginEnabled'), isEmpty);
    },
  );

  test(
    'changed true with restart-required does not claim live enablement',
    () async {
      final runtime = PluginsRuntime();
      final controller = await ready(runtime);
      await controller.change('include:tool', 'setPluginEnabled', {
        'id': 'include:tool',
        'enabled': true,
      });
      expect(controller.actionMessage, contains('重启'));
      expect(controller.entries.single['enabled'], isFalse);
      expect(
        pluginChangeSummary({'changed': true, 'application': 'overridden'}),
        contains('覆盖'),
      );
    },
  );

  test('inspection is invalidated by a changed source and install defaults to disabled', () async {
    final runtime = PluginsRuntime();
    final controller = await ready(runtime);
    await checked(controller);
    controller.editSpec('@example/other');
    await controller.install();
    expect(methods(runtime, 'installBundle'), isEmpty);
    await controller.inspect();
    await controller.install();
    await controller.load();
    final args =
        methods(runtime, 'installBundle').single['params']['args'] as Json;
    expect(args['spec'], '@example/other');
    expect(args['options']['enabled'], isFalse);
    expect(
      args['options']['requestId'],
      matches(
        RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ),
      ),
    );
    await controller.install();
    expect(methods(runtime, 'installBundle'), hasLength(1));
  });

  test('leaving a page never cancels an in-flight install and late cancellation is not success', () async {
    final runtime = PluginsRuntime()..installing = Completer<Json>();
    final controller = await ready(runtime);
    controller.attach();
    await checked(controller);
    final run = controller.install();
    controller.detach();
    expect(methods(runtime, 'cancelInstall'), isEmpty);
    final id = controller.requestId;
    await controller.cancel();
    expect(controller.installPhase, 'applying');
    expect(controller.requestId, id);
    expect(controller.installError, contains('无法取消'));
    runtime.installing!.complete(runtime.outcome);
    await run;
    await controller.load();
    expect(controller.installPhase, 'done');
  });

  test('catalog targets save exact registry versions and manual edits reset that choice', () async {
    final runtime = PluginsRuntime();
    final controller = await ready(runtime);
    controller.editSpec('@example/official@1.2.3', exact: true);
    await controller.inspect();
    await controller.install();
    expect(
      methods(
        runtime,
        'installBundle',
      ).single['params']['args']['options']['saveExact'],
      isTrue,
    );
    controller.editSpec('@example/custom');
    await controller.inspect();
    await controller.install();
    expect(
      methods(
        runtime,
        'installBundle',
      ).last['params']['args']['options'].containsKey('saveExact'),
      isFalse,
    );
  });

  test('not-running cancellation plus absent recovery result remains explicitly unknown', () async {
    final runtime = PluginsRuntime()
      ..failInstall = true
      ..cancelStatus = 'not-running';
    final controller = await ready(runtime);
    await checked(controller);
    await controller.install();
    final id = controller.requestId;
    expect(controller.installPhase, 'unconfirmed');
    await controller.cancel();
    expect(controller.installPhase, 'unconfirmed');
    await controller.recover();
    await controller.load();
    expect(controller.installPhase, 'unknown');
    expect(controller.installError, contains('不能证明'));
    expect(methods(runtime, 'waitForInstall').single['params']['args'], {
      'requestId': id,
    });
    expect(methods(runtime, 'installBundle'), hasLength(1));
  });

  test('lost acknowledgement recovers the same request without starting another install', () async {
    final runtime = PluginsRuntime()..failInstall = true;
    runtime.recovered = runtime.outcome;
    final controller = await ready(runtime);
    await checked(controller);
    await controller.install();
    await controller.recover();
    await controller.load();
    expect(controller.installPhase, 'done');
    expect(methods(runtime, 'installBundle'), hasLength(1));
  });

  test('script approval only forwards explicitly selected names that the core reported pending', () async {
    final runtime = PluginsRuntime()
      ..outcome = {
        'changed': false,
        'application': 'failed',
        'pendingBuilds': ['needs-build', 'optional-build'],
        'packageResult': {'kind': 'build-blocked'},
      };
    final controller = await ready(runtime);
    await checked(controller);
    await controller.install();
    await controller.install(approvedBuilds: ['unreported']);
    expect(methods(runtime, 'installBundle'), hasLength(1));
    await controller.install(approvedBuilds: ['needs-build']);
    await controller.load();
    expect(
      methods(
        runtime,
        'installBundle',
      ).last['params']['args']['options']['approvedBuilds'],
      ['needs-build'],
    );
  });

  test('install progress belongs to the current request and log retention is bounded', () async {
    final runtime = PluginsRuntime()..installing = Completer<Json>();
    final controller = await ready(runtime);
    await checked(controller);
    final run = controller.install();
    controller.receive({
      'event': 'plugin-manager/install-state',
      'args': [
        {'requestId': 'foreign', 'phase': 'applying'},
      ],
    });
    expect(controller.installPhase, 'installing');
    controller.receive({
      'event': 'plugin-manager/install-state',
      'args': [
        {'requestId': controller.requestId, 'phase': 'applying'},
      ],
    });
    expect(controller.installPhase, 'applying');
    controller.receive({
      'event': 'plugin-manager/install-log',
      'args': [
        {'requestId': controller.requestId, 'text': 'a' * 70000},
      ],
    });
    expect(controller.logTruncated, isTrue);
    expect((controller.logs.single['text'] as String).length, 60000);
    runtime.installing!.complete(runtime.outcome);
    await run;
    await controller.load();
  });

  testWidgets('protected entries are visible without a working toggle', (
    tester,
  ) async {
    final runtime = PluginsRuntime()..entries = [entry(protected: true)];
    final controller = await ready(runtime);
    await mount(
      tester,
      PocketScaffold(
        title: const Text('Test'),
        body: PluginEntryRow(
          controller: controller,
          entry: runtime.entries.single,
        ),
      ),
    );
    final switchRow = tester.widget<PocketSwitchRow>(
      find.byType(PocketSwitchRow),
    );
    expect(switchRow.onChanged, isNull);
    expect(find.textContaining('management-required'), findsOneWidget);
  });

  testWidgets('uninstall requires the concrete package confirmation', (
    tester,
  ) async {
    final runtime = PluginsRuntime();
    final controller = await ready(runtime);
    await mount(
      tester,
      PluginBundlePage(controller: controller, name: '@example/bundle'),
    );
    await tap(tester, '卸载插件包');
    expect(methods(runtime, 'removeBundle'), isEmpty);
    await tap(tester, '确认卸载');
    expect(methods(runtime, 'removeBundle').single['params']['args'], {
      'name': '@example/bundle',
    });
    expect(find.text('此插件包已不在最新目录中。'), findsOneWidget);
  });

  testWidgets(
    'inspecting a source does not install until the reviewed confirmation is tapped',
    (tester) async {
      final runtime = PluginsRuntime();
      final controller = await ready(runtime);
      await mount(tester, PluginInstallPage(controller: controller));
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == '包名、Git 地址或设备本地路径',
        ),
        '@example/new',
      );
      await tap(tester, '核对安装来源');
      expect(methods(runtime, 'installBundle'), isEmpty);
      await tap(tester, '确认安装');
      expect(methods(runtime, 'installBundle'), hasLength(1));
      expect(find.text('变更已应用。'), findsOneWidget);
    },
  );
}
