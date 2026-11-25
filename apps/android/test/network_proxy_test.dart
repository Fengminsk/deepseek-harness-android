import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/network_proxy.dart';
import 'package:dsh_android/network_proxy_settings.dart';
import 'package:dsh_android/network_proxy_tool_icon.dart';
import 'package:dsh_android/design/popup.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _RealHttpOverrides extends HttpOverrides {}

Json config({String mode = 'system', int port = 7890, String tool = ''}) => {
  'mode': mode,
  'port': port,
  'tool': tool,
  'tools': <Json>[],
  'route': {
    'mode': mode,
    'url': mode == 'local' ? 'http://127.0.0.1:$port' : null,
  },
};

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }
  Json active = config();
  Future<Json> Function()? status;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method != 'runtime.proxy.status') throw StateError(method);
    if (status != null) return status!();
    return {'phase': 'ready', 'configuration': active};
  }
}

class _Platform extends NetworkProxyPlatform {
  Json stored = config();
  final saves = <Json>[];
  final opened = <String>[];
  int applications = 0, probes = 0;
  Object? saveFailure, applyFailure, openFailure, testFailure;
  Future<NetworkProxyConfiguration> Function()? readOverride;
  void Function()? onApply;
  @override
  Future<NetworkProxyConfiguration> read() async => readOverride != null
      ? readOverride!()
      : NetworkProxyConfiguration(stored);
  @override
  Future<NetworkProxyConfiguration> save(Json value) async {
    saves.add(value);
    if (saveFailure != null) throw saveFailure!;
    final previousTools = stored['tools'];
    stored = config(
      mode: value['mode'] as String,
      port: value['port'] as int,
      tool: value['tool'] as String,
    )..['tools'] = previousTools;
    return NetworkProxyConfiguration(stored);
  }

  @override
  Future<void> apply() async {
    applications++;
    if (applyFailure != null) throw applyFailure!;
    onApply?.call();
  }

  @override
  Future<void> openTool(String packageName) async {
    opened.add(packageName);
    if (openFailure != null) throw openFailure!;
  }

  @override
  Future<Json> test(Json value) async {
    probes++;
    if (testFailure != null) throw testFailure!;
    return {'milliseconds': 27, 'host': 'www.gstatic.com'};
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Runtime runtime,
  _Platform platform,
) async {
  tester.view.physicalSize = const Size(420, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: NetworkProxyPage(runtime: runtime, platform: platform),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder keyed(String id) => find.byKey(ValueKey(id));

void main() {
  testWidgets(
    'proxy tool uses the glass popup with artwork and a separate open action',
    (tester) async {
      final expected = jsonDecode(
        File('test/fixtures/network_proxy.expected.json').readAsStringSync(),
      ) as Json;
      final runtime = _Runtime();
      final platform = _Platform();
      const icon =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
      platform.stored['tools'] = [
        {'id': 'com.follow.clash', 'name': 'FlClash', 'icon': icon},
        {'id': 'com.v2ray.ang', 'name': 'v2rayNG'},
      ];
      addTearDown(runtime.dispose);
      await _mount(tester, runtime, platform);
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.text('系统 VPN 设置'), findsOneWidget);
      await tap(tester, keyed('proxy-tool-select'));
      expect(find.byType(CommonPopupMenu), findsOneWidget);
      final menu = tester.widget<CommonPopupMenu>(find.byType(CommonPopupMenu));
      expect(
        menu.items.map((entry) => entry.label).toList(),
        expected['toolChoices'],
      );
      expect(find.byTooltip(expected['openTool'] as String), findsOneWidget);
      expect(menu.items.first.glyph, Icons.vpn_key_outlined);
      expect(menu.items.first.leading, isNull);
      expect(menu.items[1].leading, isA<NetworkProxyToolIcon>());
      expect(find.byType(Image), findsOneWidget);
      await tap(tester, find.text('FlClash'));
      expect(find.byType(CommonPopupMenu), findsNothing);
      expect(find.text('FlClash'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(platform.saves, isEmpty);
      await tap(tester, keyed('proxy-tool-open'));
      expect(platform.opened, ['com.follow.clash']);
      await tap(tester, keyed('proxy-save'));
      expect(platform.stored['tool'], 'com.follow.clash');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pressing the proxy selector and dragging into a choice selects once',
    (tester) async {
      final runtime = _Runtime();
      final platform = _Platform();
      platform.stored['tools'] = [
        {'id': 'com.follow.clash', 'name': 'FlClash'},
        {'id': 'com.v2ray.ang', 'name': 'v2rayNG'},
      ];
      addTearDown(runtime.dispose);
      await _mount(tester, runtime, platform);
      final gesture = await tester.startGesture(
        tester.getCenter(keyed('proxy-tool-select')),
      );
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pumpAndSettle();
      expect(find.byType(CommonPopupMenu), findsOneWidget);
      await gesture.moveTo(tester.getCenter(find.text('v2rayNG')));
      await tester.pump(const Duration(milliseconds: 30));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(CommonPopupMenu), findsNothing);
      expect(find.text('v2rayNG'), findsOneWidget);
      expect(platform.saves, isEmpty);
      await tap(tester, keyed('proxy-save'));
      expect(platform.saves, hasLength(1));
      expect(platform.stored['tool'], 'com.v2ray.ang');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid optional tool artwork preserves the selector', (
    tester,
  ) async {
    final runtime = _Runtime();
    final platform = _Platform()..stored = config(tool: 'com.follow.clash');
    platform.stored['tools'] = [
      {'id': 'com.follow.clash', 'name': 'FlClash', 'icon': 'not-base64'},
    ];
    addTearDown(runtime.dispose);
    await _mount(tester, runtime, platform);
    expect(find.text('FlClash'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    await tap(tester, keyed('proxy-tool-select'));
    expect(find.byType(CommonPopupMenu), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(platform.saves, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saved routes persist and application is confirmed by the Agent process',
    (tester) async {
      final expected = jsonDecode(
        File('test/fixtures/network_proxy.expected.json').readAsStringSync(),
      ) as Json;
      final runtime = _Runtime();
      final platform = _Platform();
      addTearDown(runtime.dispose);
      await _mount(tester, runtime, platform);
      expect(
        tester
            .widget<SegmentedControl<String>>(
              find.byType(SegmentedControl<String>),
            )
            .segments
            .map((entry) => entry.$2)
            .toList(),
        expected['modes'],
      );
      expect(platform.stored['port'], expected['defaultPort']);
      expect(find.text(expected['testButton'] as String), findsOneWidget);
      expect(find.text('Agent 已生效'), findsOneWidget);
      await tap(tester, find.text('本机代理'));
      expect(find.text('更改尚未保存'), findsOneWidget);
      expect(find.text('Agent 已生效'), findsNothing);
      await tester.enterText(keyed('proxy-port'), '7897');
      await tap(tester, keyed('proxy-save'));
      expect(find.text('更改尚未保存'), findsNothing);
      expect(platform.stored['port'], 7897);
      expect(find.text('Agent 仍使用上次配置'), findsOneWidget);
      platform.applyFailure = PlatformException(
        code: 'runtime/task-busy',
        message: 'Agent 任务尚未结束，未切换服务',
      );
      await tap(tester, keyed('proxy-apply'));
      expect(find.textContaining('未切换服务'), findsOneWidget);
      expect(runtime.active['mode'], 'system');
      expect(runtime.phase, 'ready');
      platform.applyFailure = null;
      platform.onApply = () => runtime.active = platform.stored;
      await tap(tester, keyed('proxy-apply'));
      expect(find.text('Agent 已生效'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _mount(tester, runtime, platform);
      expect(
        tester.widget<TextField>(keyed('proxy-port')).controller!.text,
        '7897',
      );
      expect(
        tester
            .widget<SegmentedControl<String>>(
              find.byType(SegmentedControl<String>),
            )
            .value,
        'local',
      );
    },
  );

  testWidgets(
    'invalid and failed saves preserve input without claiming application',
    (tester) async {
      final runtime = _Runtime();
      final platform = _Platform();
      addTearDown(runtime.dispose);
      await _mount(tester, runtime, platform);
      await tap(tester, find.text('本机代理'));
      await tester.enterText(keyed('proxy-port'), '65536');
      await tap(tester, keyed('proxy-save'));
      expect(platform.saves, isEmpty);
      expect(find.text('代理端口须为 1–65535'), findsOneWidget);
      await tap(tester, find.text('手机网络 / VPN'));
      await tap(tester, keyed('proxy-save'));
      expect(platform.stored['mode'], 'system');
      expect(platform.stored['port'], 7890);
      expect(find.text('代理端口须为 1–65535'), findsNothing);
      await tap(tester, find.text('本机代理'));
      await tester.enterText(keyed('proxy-port'), '8888');
      platform.saveFailure = StateError('disk full');
      await tap(tester, keyed('proxy-save'));
      expect(find.textContaining('保存未确认'), findsOneWidget);
      expect(
        tester.widget<TextField>(keyed('proxy-port')).controller!.text,
        '8888',
      );
      expect(platform.applications, 0);
      await tap(tester, find.byTooltip('重新读取代理配置'));
      expect(find.byKey(const ValueKey('proxy-port')), findsNothing);
      expect(
        tester
            .widget<SegmentedControl<String>>(
              find.byType(SegmentedControl<String>),
            )
            .value,
        'system',
      );
    },
  );

  testWidgets('an older refresh cannot replace a newer saved configuration', (
    tester,
  ) async {
    final runtime = _Runtime();
    final platform = _Platform()..stored = config(mode: 'local');
    addTearDown(runtime.dispose);
    await _mount(tester, runtime, platform);
    final old = Completer<NetworkProxyConfiguration>();
    platform.readOverride = () => old.future;
    await tap(tester, find.byTooltip('重新读取代理配置'));
    await tester.enterText(keyed('proxy-port'), '8888');
    await tap(tester, keyed('proxy-save'));
    old.complete(NetworkProxyConfiguration(config(mode: 'local')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(keyed('proxy-port')).controller!.text,
      '8888',
    );
    platform.onApply = () => runtime.active = platform.stored;
    await tap(tester, keyed('proxy-apply'));
    expect(find.text('Agent 已生效'), findsOneWidget);
    await tester.enterText(keyed('proxy-port'), '9999');
    await tap(tester, keyed('proxy-save'));
    await tester.enterText(keyed('proxy-port'), '7777');
    await tester.pump();
    expect(tester.widget<PocketButton>(keyed('proxy-apply')).onPressed, isNull);
    expect(find.text('请先保存配置'), findsOneWidget);
  });

  testWidgets('late status failure cannot erase a newer Agent confirmation', (
    tester,
  ) async {
    final runtime = _Runtime();
    final platform = _Platform()..stored = config(mode: 'local');
    addTearDown(runtime.dispose);
    await _mount(tester, runtime, platform);
    final oldStatus = Completer<Json>();
    runtime.status = () => oldStatus.future;
    await tap(tester, find.byTooltip('重新读取代理配置'));
    runtime.status = null;
    runtime.active = config(mode: 'local', port: 8888);
    await tester.enterText(keyed('proxy-port'), '8888');
    await tap(tester, keyed('proxy-save'));
    expect(find.text('Agent 已生效'), findsOneWidget);
    oldStatus.completeError(StateError('late disconnected'));
    await tester.pumpAndSettle();
    expect(find.text('Agent 已生效'), findsOneWidget);
  });

  testWidgets('missing tools and failed network probes never look connected', (
    tester,
  ) async {
    final runtime = _Runtime();
    final platform = _Platform()..stored = config(tool: 'example.removed');
    addTearDown(runtime.dispose);
    platform.openFailure = PlatformException(
      code: 'proxy-tool',
      message: '该代理工具已卸载或无法打开，请重新选择',
    );
    platform.testFailure = const SocketException('Connection refused');
    await _mount(tester, runtime, platform);
    await tap(tester, keyed('proxy-tool-open'));
    expect(find.textContaining('该代理工具已卸载'), findsOneWidget);
    await tap(tester, keyed('proxy-test'));
    expect(find.textContaining('连接测试失败'), findsOneWidget);
    expect(find.textContaining('HTTPS 测试通过'), findsNothing);
    expect(platform.saves, isEmpty);
    platform.testFailure = null;
    await tap(tester, keyed('proxy-test'));
    expect(find.textContaining('www.gstatic.com'), findsOneWidget);
  });

  testWidgets('native preference and route reads have a finite timeout', (
    tester,
  ) async {
    final pending = Completer<String?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          RuntimeController.channel,
          (_) => pending.future,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(RuntimeController.channel, null),
    );
    final failures = <Object>[];
    unawaited(
      const NetworkProxyPlatform().read().then<void>(
        (_) {},
        onError: (Object e) {
          failures.add(e);
        },
      ),
    );
    unawaited(
      readNetworkProxyRoute().then<void>(
        (_) {},
        onError: (Object e) {
          failures.add(e);
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(failures, hasLength(2));
    expect(failures, everyElement(isA<TimeoutException>()));
    pending.complete(null);
    await tester.pump();
  });

  test('proxy ports reject malformed values', () {
    for (final value in ['0', '-1', '65536', '7.5', 'abc', '']) {
      expect(() => checkedProxyPort(value), throwsFormatException);
    }
    expect(checkedProxyPort('7890'), 7890);
    expect(checkedProxyPort(' 65535 '), 65535);
    expect(
      () => createProxyHttpClient(const NetworkProxyRoute(mode: 'local')),
      throwsFormatException,
    );
    expect(
      () => createProxyHttpClient(const NetworkProxyRoute(mode: 'unknown')),
      throwsFormatException,
    );
  });

  test(
    'manual proxy routes real HTTP traffic and failure does not fall back',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <Uri>[];
        final subscription = proxy.listen((request) {
          requests.add(request.uri);
          request.response.write('via-proxy');
          unawaited(request.response.close());
        });
        final client = createProxyHttpClient(
          NetworkProxyRoute(
            mode: 'local',
            url: 'http://127.0.0.1:${proxy.port}',
          ),
        );
        try {
          final request = await client.getUrl(
            Uri.parse('http://proxy-fixture.invalid/hello'),
          );
          final response = await request.close();
          expect(await utf8.decoder.bind(response).join(), 'via-proxy');
          expect(
            requests.single.toString(),
            'http://proxy-fixture.invalid/hello',
          );
        } finally {
          client.close(force: true);
          await subscription.cancel();
          await proxy.close(force: true);
        }
        final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close();
        final unavailable = createProxyHttpClient(
          NetworkProxyRoute(mode: 'local', url: 'http://127.0.0.1:$port'),
        );
        try {
          await expectLater(
            unavailable.getUrl(Uri.parse('http://proxy-fixture.invalid/hello')),
            throwsA(isA<SocketException>()),
          );
        } finally {
          unavailable.close(force: true);
        }
      }, _RealHttpOverrides());
    },
  );
}
