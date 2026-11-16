// 「添加连接」页的多种连接方式：粘贴 / 扫码 / 局域网发现 / 手动地址。
//
// 页面测试不碰真实 UDP、相机与网络：发现、扫码与配对编排都用假实现注入。
// 发现协议本身的解析与收集在 `remote_discovery_test.dart`；扫码通道在
// `remote_pairing_scan_test.dart`；扫描结果的解析/信任语义在 `remote_pairing_test.dart`。

import 'package:dsh_android/remote_device_store.dart';
import 'package:dsh_android/remote_discovery.dart';
import 'package:dsh_android/remote_pairing.dart';
import 'package:dsh_android/remote_pairing_flow.dart';
import 'package:dsh_android/remote_pairing_page.dart';
import 'package:dsh_android/remote_pairing_scan.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/remote_tls_fixture.dart';

/// 配对链接里的令牌（43 字符 base64url）。
const String _pairingToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

final String _instanceId = caCertificateFingerprint(pairingCaPem);

/// 一条形状合法的配对链接。
String _link(String host) =>
    'wss://$host:4777#instance=$_instanceId&token=$_pairingToken';

/// 一条 HTTPS 反代形态的配对链接（显式 443）。
String _proxyLink(String host) =>
    'wss://$host:443#instance=$_instanceId&token=$_pairingToken';

/// 一台发现到的电脑（页面只消费字段，不需要经过协议解析）。
RemoteDiscoveredHost _host({
  required String name,
  required bool open,
  String host = '192.168.1.10',
  String? instanceId,
}) {
  final instance = instanceId ?? _instanceId;
  return RemoteDiscoveredHost(
    name: name,
    origin: Uri.parse('wss://$host:4777'),
    instanceId: instance,
    pairLink: open
        ? 'wss://$host:4777#instance=$instance&token=$_pairingToken'
        : null,
    pairingExpiresAt: open ? DateTime.utc(2026, 11, 16, 3, 0, 0) : null,
  );
}

/// 内存版本的令牌保管口：页面测试不碰 Keystore。
class _MemoryVault implements RemoteDeviceTokenVault {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String tokenRef) async {
    values.remove(tokenRef);
  }

  @override
  Future<bool> isConfigured(String tokenRef) async =>
      values.containsKey(tokenRef);

  @override
  Future<String> read(String tokenRef) async {
    final value = values[tokenRef];
    if (value == null) {
      throw const RemoteDeviceStoreException(
        'remote/credential-read',
        '本机密钥库里没有这台电脑的设备令牌，请重新配对。',
      );
    }
    return value;
  }

  @override
  Future<void> write(String tokenRef, String token) async {
    values[tokenRef] = token;
  }
}

/// 假扫码器：记录调用次数，成功返回固定链接。
class _FakeScanner implements PairingScanner {
  _FakeScanner({Future<String> Function()? answer})
    : answer = answer ?? (() async => _link('192.168.1.11'));

  Future<String> Function() answer;
  int calls = 0;

  @override
  Future<String> scan() {
    calls += 1;
    return answer();
  }
}

/// 假发现：可配置结果/失败，记录调用次数与 dispose。
class _FakeDiscovery implements RemoteDiscovery {
  List<RemoteDiscoveredHost> hosts = const <RemoteDiscoveredHost>[];
  Object? error;
  int calls = 0;
  bool disposed = false;

  @override
  Future<List<RemoteDiscoveredHost>> discover({
    Duration window = remoteDiscoveryDefaultWindow,
  }) async {
    calls += 1;
    final error = this.error;
    if (error != null) throw error;
    return hosts;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

/// 不联网的配对编排：记录收到的链接与信任模式，成功时返回一条已保存设备。
class _FakeFlow extends RemotePairingFlow {
  _FakeFlow({required super.store, this.device});

  final RemoteDevice Function()? device;
  final List<String> links = <String>[];
  String? lastDeviceLabel;

  /// 最近一次调用传入的 TLS 信任模式（普通入口 false，反代入口 true）。
  bool? lastSystemTrust;

  /// 非 null 时配对以它失败（页面错误展示用例）。
  Object? failure;

  @override
  Future<RemoteDevice> pair(
    String link, {
    required String deviceLabel,
    String? appVersion,
    bool systemTrust = false,
  }) async {
    links.add(link);
    lastDeviceLabel = deviceLabel;
    lastSystemTrust = systemTrust;
    final error = failure;
    if (error != null) throw error;
    final result = device;
    if (result == null) {
      throw const RemotePairingFailure('pairing/test', '测试没有配置配对结果。');
    }
    return result();
  }
}

/// 一条字段合法的已配对电脑记录；只有配对成功路径需要它。
RemoteDevice _pairedDevice() => RemoteDevice(
  id: '0123456789abcdef0123456789abcdef',
  label: 'Pixel 8',
  host: '192.168.1.10',
  port: 4777,
  instanceId: _instanceId,
  caPem: pairingCaPem,
  createdAt: DateTime.utc(2026, 11, 16, 3, 0, 0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteDeviceStore store;
  late _FakeFlow flow;
  late _FakeScanner scanner;
  late _FakeDiscovery discovery;

  setUp(() {
    store = RemoteDeviceStore(tokens: _MemoryVault());
    flow = _FakeFlow(store: store);
    scanner = _FakeScanner();
    discovery = _FakeDiscovery();
  });

  /// 把配对页推到一个真实 Navigator 上（配对成功时页面出栈）。
  Future<void> pumpPage(WidgetTester tester, {RemoteDevice? paired}) async {
    flow = _FakeFlow(
      store: store,
      device: paired == null ? null : () => paired,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: Builder(
          builder: (context) => PocketScaffold(
            title: const Text('添加连接'),
            body: PocketList(
              children: [
                PocketButton(
                  onPressed: () async {
                    await Navigator.of(context).push<RemoteDevice>(
                      PocketRoute(
                        builder: (_) => RemotePairingPage(
                          store: store,
                          flow: flow,
                          deviceLabel: 'Pixel 8',
                          scanner: scanner,
                          discovery: discovery,
                        ),
                      ),
                    );
                  },
                  child: const Text('打开配对页'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开配对页'));
    await tester.pumpAndSettle();
  }

  Finder modes() => find.byKey(const ValueKey('remote-pairing-modes'));
  Finder linkField() => find.byKey(const ValueKey('remote-pairing-link'));
  Finder scanButton() => find.byKey(const ValueKey('remote-pairing-scan'));
  Finder submitButton() => find.byKey(const ValueKey('remote-pairing-submit'));
  Finder searchButton() => find.byKey(const ValueKey('remote-pairing-search'));
  Finder manualLink() =>
      find.byKey(const ValueKey('remote-pairing-manual-link'));
  Finder manualAddress() =>
      find.byKey(const ValueKey('remote-pairing-manual-address'));

  /// 点按三段式选择里的某一项。
  Future<void> openMode(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: modes(), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  /// 页面里的主滚动区域（PocketList）。
  Finder listScrollable() => find
      .descendant(
        of: find.byKey(const ValueKey('remote-pairing-list')),
        matching: find.byType(Scrollable),
      )
      .first;

  /// 把懒加载列表里的目标滚到可见处（高级入口在首屏之下）。
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: listScrollable());
    await tester.pumpAndSettle();
  }

  /// 滚回列表顶部，查看状态区里的错误/提示（它在高级入口上方）。
  Future<void> scrollToTop(WidgetTester tester) async {
    await tester.drag(listScrollable(), const Offset(0, 1200));
    await tester.pumpAndSettle();
  }

  /// 展开「手动地址与令牌（高级）」；列表是懒加载的，先把高级入口滚到可见处。
  Future<void> openManual(WidgetTester tester) async {
    final title = find.text('手动地址与令牌（高级）');
    await scrollTo(tester, title);
    await tester.tap(title);
    await tester.pumpAndSettle();
  }

  /// 手动地址面板的提交按钮在首屏之下：先滚动再点。
  Future<void> tapManualSubmit(WidgetTester tester) async {
    final submit = find.byKey(const ValueKey('remote-pairing-manual-submit'));
    await scrollTo(tester, submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
  }

  /// 把手动地址面板的两个输入框填上（懒加载列表需要先滚到可见处）。
  Future<void> fillManual(
    WidgetTester tester, {
    String? link,
    String? address,
  }) async {
    if (link != null) {
      await scrollTo(tester, manualLink());
      await tester.enterText(manualLink(), link);
    }
    if (address != null) {
      await scrollTo(tester, manualAddress());
      await tester.enterText(manualAddress(), address);
    }
    await tester.pump();
  }

  group('五种输入入口', () {
    testWidgets('默认粘贴链接；三段式入口齐全且发现不自动启动', (tester) async {
      await pumpPage(tester);

      for (final label in ['粘贴链接', '扫码配对', '搜索局域网', 'HTTPS 反代']) {
        expect(
          find.descendant(of: modes(), matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(linkField(), findsOneWidget);
      expect(scanButton(), findsNothing);
      expect(searchButton(), findsNothing);
      expect(find.text('手动地址与令牌（高级）'), findsOneWidget);
      // 60 fps 门禁：打开页面不发起发现，只有切到「搜索局域网」才搜索。
      expect(discovery.calls, 0);
    });

    testWidgets('切到「搜索局域网」才发起一次发现；切走再回来不重复搜索', (tester) async {
      await pumpPage(tester);
      await openMode(tester, '搜索局域网');
      expect(discovery.calls, 1);
      await openMode(tester, '粘贴链接');
      await openMode(tester, '搜索局域网');
      expect(discovery.calls, 1);
    });

    testWidgets('扫码入口保留：扫到链接后回到粘贴视图并可提交', (tester) async {
      await pumpPage(tester);
      await openMode(tester, '扫码配对');
      await tester.tap(scanButton());
      await tester.pumpAndSettle();

      expect(scanner.calls, 1);
      expect(
        tester.widget<TextField>(linkField()).controller!.text,
        _link('192.168.1.11'),
      );
      expect(tester.widget<PocketButton>(submitButton()).onPressed, isNotNull);
    });
  });

  group('HTTPS 反代入口', () {
    Finder proxySubmit() =>
        find.byKey(const ValueKey('remote-pairing-proxy-submit'));
    Finder switchProxy() =>
        find.byKey(const ValueKey('remote-pairing-switch-proxy'));

    testWidgets('切到「HTTPS 反代」显示场景说明与反代提交按钮', (tester) async {
      await pumpPage(tester);
      await openMode(tester, 'HTTPS 反代');

      expect(find.textContaining('TLS 在反代处终止'), findsOneWidget);
      expect(find.textContaining('系统根证书'), findsOneWidget);
      expect(proxySubmit(), findsOneWidget);
      // 普通「连接」按钮只在普通入口出现：两个入口的信任模式不同，不能共用同一个按钮。
      expect(submitButton(), findsNothing);
    });

    testWidgets('反代入口配对把 systemTrust 传给配对流程', (tester) async {
      await pumpPage(tester, paired: _pairedDevice());
      await openMode(tester, 'HTTPS 反代');
      await tester.enterText(linkField(), _proxyLink('dsh.example.com'));
      await tester.pump();

      await tester.tap(proxySubmit());
      await tester.pumpAndSettle();

      expect(flow.links, <String>[_proxyLink('dsh.example.com')]);
      expect(flow.lastSystemTrust, isTrue);
      expect(flow.lastDeviceLabel, 'Pixel 8');
      // 配对成功时页面带着设备记录出栈，回到调用方。
      expect(find.text('打开配对页'), findsOneWidget);
    });

    testWidgets('普通入口遇到反代链接只提示切换，不发起配对也不改模式', (tester) async {
      await pumpPage(tester, paired: _pairedDevice());
      await tester.enterText(linkField(), _proxyLink('dsh.example.com'));
      await tester.pump();

      await tester.tap(submitButton());
      await tester.pumpAndSettle();

      // 没有静默改用系统信任：一次配对请求都没发。
      expect(flow.links, isEmpty);
      expect(find.textContaining('指向 HTTPS 反代'), findsOneWidget);
      expect(switchProxy(), findsOneWidget);
      // 仍在普通入口：普通连接按钮还在，反代按钮不在。
      expect(submitButton(), findsOneWidget);
      expect(proxySubmit(), findsNothing);
      expect(
        tester.widget<TextField>(linkField()).controller!.text,
        _proxyLink('dsh.example.com'),
      );
    });

    testWidgets('点切换按钮改用反代入口：链接保留，再按反代模式配对', (tester) async {
      await pumpPage(tester, paired: _pairedDevice());
      await tester.enterText(linkField(), _proxyLink('dsh.example.com'));
      await tester.pump();
      await tester.tap(submitButton());
      await tester.pumpAndSettle();

      await tester.tap(switchProxy());
      await tester.pumpAndSettle();

      expect(proxySubmit(), findsOneWidget);
      expect(submitButton(), findsNothing);
      expect(find.textContaining('指向 HTTPS 反代'), findsNothing);
      expect(
        tester.widget<TextField>(linkField()).controller!.text,
        _proxyLink('dsh.example.com'),
      );

      await tester.tap(proxySubmit());
      await tester.pumpAndSettle();
      expect(flow.links, <String>[_proxyLink('dsh.example.com')]);
      expect(flow.lastSystemTrust, isTrue);
    });

    testWidgets('反代入口的配对失败显示可读原因，停在页面可重试', (tester) async {
      await pumpPage(tester);
      flow.failure = const RemotePairingFailure(
        'pairing/proxy-tls',
        '反代出示的 HTTPS 证书不受系统信任（自签、过期或证书链不完整）。',
      );
      await openMode(tester, 'HTTPS 反代');
      await tester.enterText(linkField(), _proxyLink('dsh.example.com'));
      await tester.pump();

      await tester.tap(proxySubmit());
      await tester.pumpAndSettle();

      expect(find.textContaining('反代出示的 HTTPS 证书不受系统信任'), findsOneWidget);
      expect(proxySubmit(), findsOneWidget);
      expect(
        tester.widget<PocketButton>(proxySubmit()).onPressed,
        isNotNull,
        reason: '失败后停在页面，可以重试',
      );
    });

    testWidgets('原生直连入口的配对仍以 pinned 模式提交', (tester) async {
      await pumpPage(tester, paired: _pairedDevice());
      await tester.enterText(linkField(), _link('192.168.1.10'));
      await tester.pump();

      await tester.tap(submitButton());
      await tester.pumpAndSettle();

      expect(flow.links, <String>[_link('192.168.1.10')]);
      expect(flow.lastSystemTrust, isFalse);
    });
  });

  group('局域网发现列表', () {
    testWidgets('配对窗口打开的电脑可以直接连接（走既有配对流程）', (tester) async {
      final paired = _pairedDevice();
      discovery.hosts = [
        _host(name: 'DESKTOP-ALPHA', open: true, host: '192.168.1.10'),
      ];
      await pumpPage(tester, paired: paired);
      await openMode(tester, '搜索局域网');

      expect(find.text('DESKTOP-ALPHA'), findsOneWidget);
      expect(find.textContaining('192.168.1.10:4777'), findsOneWidget);
      expect(find.text('配对窗口已打开'), findsOneWidget);

      await tester.tap(
        find.byKey(ValueKey('remote-pairing-discovered-connect-$_instanceId')),
      );
      await tester.pumpAndSettle();

      expect(flow.links, <String>[_link('192.168.1.10')]);
      // 配对成功时页面带着设备记录出栈，回到调用方。
      expect(find.text('打开配对页'), findsOneWidget);
      expect(find.text('DESKTOP-ALPHA'), findsNothing);
    });

    testWidgets('配对窗口未打开时提示去电脑上重开，并可重新搜索', (tester) async {
      discovery.hosts = [_host(name: 'DESKTOP-BETA', open: false)];
      await pumpPage(tester);
      await openMode(tester, '搜索局域网');

      expect(find.text('配对窗口未打开。请在电脑上重新打开配对窗口后重试。'), findsOneWidget);
      await tester.tap(
        find.byKey(ValueKey('remote-pairing-discovered-retry-$_instanceId')),
      );
      await tester.pumpAndSettle();
      expect(discovery.calls, 2);
      expect(flow.links, isEmpty);
    });

    testWidgets('空结果给出同网段/防火墙/UDP 4778 说明与重试', (tester) async {
      discovery.hosts = const <RemoteDiscoveredHost>[];
      await pumpPage(tester);
      await openMode(tester, '搜索局域网');

      expect(find.textContaining('没有发现同网段的电脑'), findsOneWidget);
      expect(find.textContaining('UDP 4778'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('remote-pairing-search-retry')),
        findsOneWidget,
      );
    });

    testWidgets('发现失败显示可展示原因并可重试', (tester) async {
      discovery.error = const RemoteDiscoveryFailure(
        'discovery/socket',
        '无法发送局域网发现广播。请确认手机已联网并与电脑在同一网段，或改用扫码/粘贴配对链接。',
      );
      await pumpPage(tester);
      await openMode(tester, '搜索局域网');

      expect(find.textContaining('无法发送局域网发现广播'), findsOneWidget);
      discovery.error = null;
      await tester.tap(
        find.byKey(const ValueKey('remote-pairing-search-retry')),
      );
      await tester.pumpAndSettle();
      expect(discovery.calls, 2);
      expect(find.textContaining('没有发现同网段的电脑'), findsOneWidget);
    });
  });

  group('手动地址与令牌（高级）', () {
    testWidgets('完整链接 + 地址覆盖：换地址但保留 instanceId 与 token', (tester) async {
      await pumpPage(tester);
      await openManual(tester);
      await fillManual(
        tester,
        link: _link('192.168.1.10'),
        address: '127.0.0.1:4777',
      );

      await tapManualSubmit(tester);

      expect(flow.links, <String>[
        'wss://127.0.0.1:4777#instance=$_instanceId&token=$_pairingToken',
      ]);
    });

    testWidgets('只给地址不改链接：直接用粘贴的完整链接配对', (tester) async {
      await pumpPage(tester);
      await openManual(tester);
      await fillManual(tester, link: _link('192.168.1.10'));

      await tapManualSubmit(tester);

      expect(flow.links, <String>[_link('192.168.1.10')]);
    });

    testWidgets('「用上面填写的链接」把主输入框的链接带进手动区', (tester) async {
      await pumpPage(tester);
      await tester.enterText(linkField(), _link('192.168.1.10'));
      await tester.pump();
      await openManual(tester);
      final copy = find.byKey(
        const ValueKey('remote-pairing-manual-copy-link'),
      );
      await scrollTo(tester, copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();

      // 不带地址直接提交：用复制进来的完整链接配对。
      await tapManualSubmit(tester);
      expect(flow.links, <String>[_link('192.168.1.10')]);
    });

    testWidgets('只有配对令牌时明确要求完整链接（不弱化 instance 校验）', (tester) async {
      await pumpPage(tester);
      await openManual(tester);
      await fillManual(tester, link: _pairingToken);

      await tapManualSubmit(tester);
      await scrollToTop(tester);

      expect(find.textContaining('只填配对令牌不够'), findsOneWidget);
      expect(flow.links, isEmpty);
    });

    testWidgets('地址不合法给出可读错误，不发起配对', (tester) async {
      await pumpPage(tester);
      await openManual(tester);
      await fillManual(
        tester,
        link: _link('192.168.1.10'),
        address: '127.0.0.1/wrong',
      );

      await tapManualSubmit(tester);
      await scrollToTop(tester);

      expect(find.textContaining('电脑地址不合法'), findsOneWidget);
      expect(flow.links, isEmpty);
    });

    testWidgets('没填链接时提示粘贴完整配对链接', (tester) async {
      await pumpPage(tester);
      await openManual(tester);

      await tapManualSubmit(tester);
      await scrollToTop(tester);

      expect(find.textContaining('请粘贴电脑上的完整配对链接'), findsOneWidget);
      expect(flow.links, isEmpty);
    });
  });

  testWidgets('页面销毁时释放发现实现（不留后台套接字）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: RemotePairingPage(
          store: store,
          flow: flow,
          deviceLabel: 'Pixel 8',
          scanner: scanner,
          discovery: discovery,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(discovery.disposed, isTrue);
  });
}
