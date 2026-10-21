import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
  PluginsRuntime() {
    phase = 'ready';
  }
  int epoch = 0;
  @override
  int get connectionGeneration => epoch;
  void connection({required bool ready}) {
    epoch++;
    phase = ready ? 'ready' : 'disconnected';
    notifyListeners();
  }

  final eventsController = StreamController<Json>.broadcast();
  @override
  Stream<Json> get remoteEvents => eventsController.stream;
  bool managed = true;
  List<Json> bundles = [bundle()], entries = [entry()];
  final calls = <Json>[];
  Completer<Json>? installing;
  Completer<Json>? changing;
  Completer<Json>? inventoryRead;
  bool failRead = false;
  bool failChange = false;
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
      if (failRead) throw StateError('read unavailable');
      return inventoryRead?.future ?? snapshot();
    }
    switch (params['method']) {
      case 'listPlugins':
        return entries.map(cloneConfiguration).toList();
      case 'listBundles':
        return bundles.map(cloneConfiguration).toList();
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
        if (failChange) throw StateError('lost acknowledgement');
        return changing?.future ??
            {
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

  Json snapshot() => cloneConfiguration({
    'managementAvailable': managed,
    'entries': entries,
    'agentPresets': [],
  });

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

Future<void> mount(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(800, 1500),
}) async {
  tester.view.physicalSize = size;
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
    'toggle notifies only its target and stays locked through readback',
    () async {
      final runtime = PluginsRuntime()..changing = Completer<Json>();
      final controller = await ready(runtime);
      final original = controller.entries.single;
      var pageNotifications = 0, targetNotifications = 0;
      controller.addListener(() => pageNotifications++);
      controller
          .actionFor('include:tool')
          .addListener(() => targetNotifications++);
      final run = controller.change('include:tool', 'setPluginEnabled', {
        'id': 'include:tool',
        'enabled': true,
      });
      expect(pageNotifications, 0);
      expect(targetNotifications, 1);
      expect(controller.canChange('include:tool'), isFalse);
      expect(controller.canChange('include:other'), isTrue);
      expect(identical(controller.entries.single, original), isTrue);
      expect(original['enabled'], isFalse);
      await controller.change('include:tool', 'setPluginEnabled', {
        'id': 'include:tool',
        'enabled': true,
      });
      controller.receive({'event': 'plugin-manager/changed'});
      expect(methods(runtime, 'list'), hasLength(1));
      runtime.inventoryRead = Completer<Json>();
      runtime.changing!.complete({'changed': true, 'application': 'applied'});
      await Future<void>.delayed(Duration.zero);
      expect(controller.actionFor('include:tool').verifying, isTrue);
      expect(controller.canChange('include:tool'), isFalse);
      await controller.change('include:tool', 'setPluginEnabled', {
        'id': 'include:tool',
        'enabled': true,
      });
      runtime.entries = [
        {...entry(), 'enabled': true},
      ];
      runtime.inventoryRead!.complete(runtime.snapshot());
      await run;
      expect(controller.entries.single['enabled'], isTrue);
      expect(controller.canChange('include:tool'), isTrue);
      expect(methods(runtime, 'setPluginEnabled'), hasLength(1));
      expect(methods(runtime, 'list'), hasLength(2));
      expect(methods(runtime, 'listBundles'), hasLength(2));
      expect(methods(runtime, 'listPlugins'), hasLength(2));
      expect(methods(runtime, 'setPluginEnabled').single['params']['args'], {
        'id': 'include:tool',
        'enabled': true,
      });
    },
  );

  test(
    'concurrent reads are single flight and unchanged rows retain identity',
    () async {
      final runtime = PluginsRuntime();
      final controller = await ready(runtime);
      final oldEntries = controller.entries, oldBundles = controller.bundles;
      runtime.inventoryRead = Completer<Json>();
      final first = controller.load(), second = controller.load();
      expect(identical(first, second), isTrue);
      runtime.inventoryRead!.complete(runtime.snapshot());
      await first;
      expect(identical(controller.entries, oldEntries), isTrue);
      expect(identical(controller.bundles, oldBundles), isTrue);
      expect(methods(runtime, 'list'), hasLength(2));
    },
  );

  test(
    'changed bursts discard an old read and coalesce into one fresh read',
    () async {
      final runtime = PluginsRuntime();
      final controller = await ready(runtime);
      final oldSnapshot = runtime.snapshot();
      final delayed = runtime.inventoryRead = Completer<Json>();
      final reading = controller.load();
      controller.receive({'event': 'plugin-manager/changed'});
      controller.receive({'event': 'plugin-market/changed'});
      runtime.entries = [
        {...entry(), 'enabled': true},
      ];
      runtime.inventoryRead = null;
      delayed.complete(oldSnapshot);
      await reading;
      expect(controller.entries.single['enabled'], isTrue);
      expect(methods(runtime, 'list'), hasLength(3));
      // The stale snapshot never causes the two expensive management reads.
      expect(methods(runtime, 'listBundles'), hasLength(2));
      expect(methods(runtime, 'listPlugins'), hasLength(2));
    },
  );

  test('a refresh requested by the completion listener is not lost', () async {
    final runtime = PluginsRuntime();
    final controller = await ready(runtime);
    var requested = false;
    Future<void>? followup;
    controller.addListener(() {
      if (!controller.loading && !requested) {
        requested = true;
        followup = controller.load(invalidate: true);
      }
    });
    await controller.load();
    await followup;
    expect(methods(runtime, 'list'), hasLength(3));
    expect(controller.fresh, isTrue);
  });

  test(
    'failed readback keeps the list and blocks retry until a successful read',
    () async {
      final runtime = PluginsRuntime();
      final controller = await ready(runtime);
      final before = controller.entries;
      runtime.failRead = true;
      await controller.change('include:tool', 'setPluginEnabled', {
        'id': 'include:tool',
        'enabled': true,
      });
      expect(identical(controller.entries, before), isTrue);
      expect(controller.actionFor('include:tool').awaitingRefresh, isTrue);
      expect(controller.canChange('include:tool'), isFalse);
      await controller.change('include:tool', 'setPluginEnabled', {
        'id': 'include:tool',
        'enabled': true,
      });
      runtime.failRead = false;
      await controller.load();
      expect(controller.canChange('include:tool'), isTrue);
      expect(controller.actionFor('include:tool').message, contains('重启'));
      expect(methods(runtime, 'setPluginEnabled'), hasLength(1));
    },
  );

  test('unknown write is never replayed or described as a successful acknowledgement', () async {
    final runtime = PluginsRuntime()..failChange = true;
    final controller = await ready(runtime);
    runtime.entries = [
      {...entry(), 'enabled': true},
    ];
    await controller.change('include:tool', 'setPluginEnabled', {
      'id': 'include:tool',
      'enabled': true,
    });
    final action = controller.actionFor('include:tool');
    expect(action.unknown, isTrue);
    expect(action.result, isNull);
    expect(action.message, contains('结果未确认'));
    expect(controller.entries.single['enabled'], isTrue);
    expect(controller.canChange('include:tool'), isTrue);
    expect(methods(runtime, 'setPluginEnabled'), hasLength(1));
  });

  test(
    'old service write receipt cannot claim success on a new connection',
    () async {
      final runtime = PluginsRuntime()..changing = Completer<Json>();
      final controller = await ready(runtime);
      final run = controller.change('include:tool', 'setPluginEnabled', {
        'id': 'include:tool',
        'enabled': true,
      });
      runtime.connection(ready: false);
      expect(controller.fresh, isFalse);
      runtime.connection(ready: true);
      runtime.changing!.complete({'changed': true, 'application': 'applied'});
      await run;
      expect(controller.actionFor('include:tool').unknown, isTrue);
      expect(controller.actionFor('include:tool').result, isNull);
      expect(controller.entries.single['enabled'], isFalse);
      expect(methods(runtime, 'setPluginEnabled'), hasLength(1));
    },
  );

  test(
    'disconnection and observation errors fence late inventory responses',
    () async {
      final runtime = PluginsRuntime();
      final controller = await ready(runtime);
      controller.attach();
      var delayed = runtime.inventoryRead = Completer<Json>();
      var reading = controller.load();
      runtime.connection(ready: false);
      delayed.complete({...runtime.snapshot(), 'entries': []});
      await reading;
      expect(controller.fresh, isFalse);
      expect(controller.entries, hasLength(1));
      runtime.inventoryRead = null;
      runtime.connection(ready: true);
      await controller.load();
      delayed = runtime.inventoryRead = Completer<Json>();
      reading = controller.load();
      runtime.eventsController.addError(StateError('observation failed'));
      await Future<void>.delayed(Duration.zero);
      delayed.complete({...runtime.snapshot(), 'entries': []});
      await reading;
      expect(controller.fresh, isFalse);
      expect(controller.entries, hasLength(1));
      runtime.inventoryRead = null;
      await controller.load();
      expect(controller.fresh, isTrue);
    },
  );

  testWidgets(
    'runtime toggles preserve scrolled position and neighboring row identity',
    (tester) async {
      final runtime = PluginsRuntime()
        ..changing = Completer<Json>()
        ..entries = List.generate(
          30,
          (index) => {
            ...entry(),
            'entryId': 'entry:$index',
            'moduleName': 'tool-$index',
          },
        );
      final controller = await ready(runtime);
      await mount(
        tester,
        PluginRuntimePage(controller: controller),
        size: const Size(390, 844),
      );
      final row = find.byKey(const ValueKey('entry:12'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      final neighbor = tester.element(find.byKey(const ValueKey('entry:13')));
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final offset = scroll.pixels, top = tester.getTopLeft(row).dy;
      final toggle = find.descendant(
        of: row,
        matching: find.byType(PocketSwitchRow),
      );
      tester.widget<PocketSwitchRow>(toggle).onChanged!(true);
      await tester.pumpAndSettle();
      expect(scroll.pixels, offset);
      expect(tester.getTopLeft(row).dy, top);
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNull);
      expect(tester.widget<PocketSwitchRow>(toggle).value, isFalse);
      runtime.inventoryRead = Completer<Json>();
      runtime.changing!.complete({
        'changed': true,
        'application': 'restart-required',
        'restartReason': 'no-hmr',
      });
      await tester.pumpAndSettle();
      expect(scroll.pixels, offset);
      expect(tester.getTopLeft(row).dy, top);
      runtime.inventoryRead!.complete(runtime.snapshot());
      await tester.pumpAndSettle();
      expect(scroll.pixels, offset);
      expect(tester.getTopLeft(row).dy, top);
      expect(
        identical(
          tester.element(find.byKey(const ValueKey('entry:13'))),
          neighbor,
        ),
        isTrue,
      );
      expect(tester.widget<PocketSwitchRow>(toggle).onChanged, isNotNull);
      expect(find.text('配置已保存，重启后生效 · 详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bundle feedback stays inline and details keep the real core outcome',
    (tester) async {
      final runtime = PluginsRuntime();
      final controller = await ready(runtime);
      await mount(
        tester,
        PluginBundlePage(controller: controller, name: '@example/bundle'),
        size: const Size(390, 844),
      );
      final title = find.text('启用插件包');
      final top = tester.getTopLeft(title).dy;
      final toggle = find.ancestor(
        of: title,
        matching: find.byType(PocketSwitchRow),
      );
      tester.widget<PocketSwitchRow>(toggle).onChanged!(true);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(title).dy, top);
      expect(find.textContaining('原因：no-hmr'), findsNothing);
      await tester.tap(find.text('配置已保存，重启后生效 · 详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('原因：no-hmr'), findsOneWidget);
      expect(find.textContaining('配置：停用'), findsOneWidget);
      expect(methods(runtime, 'setBundleEnabled'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('package and configured-entry rows render their original artwork', (
    tester,
  ) async {
    final icon =
        'data:image/svg+xml;base64,${base64Encode(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2h20v20H2z" fill="#1683ff"/></svg>'))}';
    final runtime = PluginsRuntime()
      ..bundles = [
        {
          ...bundle(),
          'enabled': true,
          'meta': {'title': '图标插件', 'icon': icon},
        },
      ]
      ..entries = [
        {
          ...entry(),
          'meta': {'title': '图标工具', 'icon': icon},
        },
      ];
    addTearDown(runtime.dispose);
    await mount(tester, PluginsPage(runtime: runtime));
    expect(find.byType(SvgPicture), findsOneWidget);
    await tap(tester, '图标插件');
    expect(find.byType(SvgPicture), findsNWidgets(2));
    expect(methods(runtime, 'setBundleEnabled'), isEmpty);
    expect(methods(runtime, 'setPluginEnabled'), isEmpty);
    expect(tester.takeException(), isNull);
  });
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

  testWidgets(
    'install and catalog stay on the first phone screen with many bundles',
    (tester) async {
      final runtime = PluginsRuntime()
        ..bundles = List.generate(
          40,
          (index) => {
            ...bundle(),
            'name': '@example/bundle-$index',
            'installed': false,
            'availability': 'installation',
          },
        );
      addTearDown(runtime.dispose);
      await mount(
        tester,
        PluginsPage(runtime: runtime),
        size: const Size(390, 844),
      );

      expect(find.text('安装插件包').hitTestable(), findsOneWidget);
      expect(find.text('可用插件包').hitTestable(), findsOneWidget);
      expect(find.text('运行时条目与预设').hitTestable(), findsOneWidget);
      expect(find.text('40 个未选用的插件包'), findsOneWidget);
      expect(find.text('@example/bundle-0'), findsNothing);
      await tester.tap(find.text('安装插件包'));
      await tester.pumpAndSettle();
      expect(find.byType(PluginInstallPage), findsOneWidget);
      expect(methods(runtime, 'installBundle'), isEmpty);
    },
  );

  testWidgets(
    'selected, shipped, profile-installed and missing bundles remain reachable',
    (tester) async {
      final runtime = PluginsRuntime()
        ..bundles = [
          {
            ...bundle(),
            'name': '@example/selected',
            'enabled': true,
            'meta': {'title': '已选用扩展'},
          },
          {
            ...bundle(),
            'name': '@example/shipped',
            'availability': 'installation',
            'installed': false,
            'meta': {'title': '随应用扩展'},
          },
          {
            ...bundle(),
            'name': '@example/installed',
            'meta': {'title': '自行安装扩展'},
          },
          {
            ...bundle(),
            'name': '@example/missing',
            'availability': 'missing',
            'installed': false,
            'meta': {'title': '待安装扩展'},
            'installTarget': {
              'spec': '@example/missing@1.0.0',
              'version': '1.0.0',
            },
          },
        ];
      addTearDown(runtime.dispose);
      await mount(
        tester,
        PluginsPage(runtime: runtime),
        size: const Size(390, 844),
      );

      expect(find.text('已选用 · 1'), findsOneWidget);
      await tap(tester, '已选用扩展');
      expect(
        tester.widget<PluginBundlePage>(find.byType(PluginBundlePage)).name,
        '@example/selected',
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tap(tester, '可用插件包');
      expect(find.text('随应用提供 · 1'), findsOneWidget);
      expect(find.text('已添加到配置 · 1'), findsOneWidget);
      expect(find.text('其他插件包 · 1'), findsOneWidget);
      expect(find.text('已选用扩展'), findsNothing);
      for (final item in [
        ('随应用扩展', '@example/shipped'),
        ('自行安装扩展', '@example/installed'),
        ('待安装扩展', '@example/missing'),
      ]) {
        await tap(tester, item.$1);
        expect(
          tester.widget<PluginBundlePage>(find.byType(PluginBundlePage)).name,
          item.$2,
        );
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
      }
      expect(methods(runtime, 'setBundleEnabled'), isEmpty);
      expect(methods(runtime, 'installBundle'), isEmpty);
    },
  );

  testWidgets(
    'reopening an in-flight install keeps its draft and never repeats the request',
    (tester) async {
      final runtime = PluginsRuntime()..installing = Completer<Json>();
      addTearDown(runtime.dispose);
      await mount(
        tester,
        PluginsPage(runtime: runtime),
        size: const Size(390, 844),
      );
      await tap(tester, '安装插件包');
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == '包名、Git 地址或设备本地路径',
        ),
        '@example/new',
      );
      await tap(tester, '安装选项');
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'Registry（可选）',
        ),
        'https://registry.example.test',
      );
      await tap(tester, '核对安装来源');
      expect(methods(runtime, 'installBundle'), isEmpty);
      await tap(tester, '确认安装');
      final requestId = runtime.plugins.requestId;
      expect(methods(runtime, 'installBundle'), hasLength(1));
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('查看进行中的安装').hitTestable(), findsOneWidget);
      await tap(tester, '查看进行中的安装');
      expect(find.text('取消本次安装').hitTestable(), findsOneWidget);
      expect(find.text('核对原请求结果').hitTestable(), findsOneWidget);
      expect(runtime.plugins.requestId, requestId);
      expect(runtime.plugins.spec, '@example/new');
      expect(runtime.plugins.registry, 'https://registry.example.test');
      expect(methods(runtime, 'installBundle'), hasLength(1));
      expect(methods(runtime, 'cancelInstall'), isEmpty);
      runtime.installing!.complete(runtime.outcome);
      await tester.pumpAndSettle();
      expect(methods(runtime, 'installBundle'), hasLength(1));
    },
  );

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
