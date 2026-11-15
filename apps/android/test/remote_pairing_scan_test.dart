// 扫码配对：页面接线（扫码 → 填入输入框 → 既有配对流程）与原生通道错误翻译。
//
// 相机与 ZXing 在 Android 原生侧（`PairingQrScan.kt`），这里不碰真实相机：
// - 页面测试注入假 [PairingScanner]，覆盖成功填入 / 取消 / 失败 / 相机不可用 /
//   已有输入时覆盖确认 / 扫码中进度；
// - 通道测试用 mock MethodChannel 验证 `remote.pairing.scan` 的回执与错误码翻译。
// 配对本身的解析、CA 指纹与令牌语义由 `remote_pairing_test.dart` 覆盖，本文件只
// 断言扫码后走的还是同一条 [RemotePairingFlow.pair]。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/remote_device_store.dart';
import 'package:dsh_android/remote_pairing.dart';
import 'package:dsh_android/remote_pairing_flow.dart';
import 'package:dsh_android/remote_pairing_page.dart';
import 'package:dsh_android/remote_pairing_scan.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/remote_tls_fixture.dart';

/// 配对链接里的令牌（43 字符 base64url）。
const String _pairingToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

final String _instanceId = caCertificateFingerprint(pairingCaPem);

/// 一条形状合法的配对链接；扫码测试不真的发起 HTTP。
String _link(String host) =>
    'wss://$host:4777#instance=$_instanceId&token=$_pairingToken';

final String _firstLink = _link('192.168.1.10');
final String _secondLink = _link('192.168.1.11');

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

/// 假扫码器：记录调用次数，结果由每个用例注入。
class _FakeScanner implements PairingScanner {
  _FakeScanner(this.answer);

  Future<String> Function() answer;
  int calls = 0;

  @override
  Future<String> scan() {
    calls++;
    return answer();
  }
}

/// 不联网的配对编排：记录收到的链接，成功时返回一条已保存设备。
class _FakeFlow extends RemotePairingFlow {
  _FakeFlow({required super.store, this.device});

  final RemoteDevice Function()? device;
  final List<String> links = <String>[];
  String? lastDeviceLabel;

  @override
  Future<RemoteDevice> pair(
    String link, {
    required String deviceLabel,
    String? appVersion,
  }) async {
    links.add(link);
    lastDeviceLabel = deviceLabel;
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
  createdAt: DateTime.utc(2026, 11, 16, 2, 0, 0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteDeviceStore store;
  late _FakeFlow flow;
  late _FakeScanner scanner;

  setUp(() {
    store = RemoteDeviceStore(tokens: _MemoryVault());
    flow = _FakeFlow(store: store);
    scanner = _FakeScanner(() async => _firstLink);
  });

  /// 把配对页推到一个真实 Navigator 上，并返回配对页的返回值。
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
    // task-18 起页面是三段式入口：扫码按钮只在「扫码配对」方式下渲染。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('remote-pairing-modes')),
        matching: find.text('扫码配对'),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder scanButton() => find.byKey(const ValueKey('remote-pairing-scan'));
  Finder submitButton() => find.byKey(const ValueKey('remote-pairing-submit'));
  Finder linkField() => find.byKey(const ValueKey('remote-pairing-link'));

  String linkText(WidgetTester tester) =>
      tester.widget<TextField>(linkField()).controller!.text;

  bool enabled(WidgetTester tester, Finder finder) =>
      tester.widget<PocketButton>(finder).onPressed != null;

  group('扫码配对页', () {
    testWidgets('扫码成功把链接填进输入框，连接按钮随即可用', (tester) async {
      await pumpPage(tester);
      expect(linkText(tester), isEmpty);
      expect(enabled(tester, submitButton()), isFalse);

      await tester.tap(scanButton());
      await tester.pumpAndSettle();

      expect(scanner.calls, 1);
      expect(linkText(tester), _firstLink);
      expect(enabled(tester, submitButton()), isTrue);
      expect(find.textContaining('不是配对链接'), findsNothing);
    });

    testWidgets('扫到的文本先按既有解析校验；不是配对链接时不覆盖输入', (tester) async {
      scanner.answer = () async => 'https://example.com/not-a-pairing-link';
      await pumpPage(tester);
      await tester.enterText(linkField(), _firstLink);

      await tester.tap(scanButton());
      await tester.pumpAndSettle();

      expect(find.textContaining('扫到的内容不是配对链接'), findsOneWidget);
      expect(linkText(tester), _firstLink);
    });

    testWidgets('取消扫码不当作失败：输入框与提示保持原样', (tester) async {
      scanner.answer = () async => throw const PairingScanCancelled();
      await pumpPage(tester);

      await tester.tap(scanButton());
      await tester.pumpAndSettle();

      expect(linkText(tester), isEmpty);
      expect(find.textContaining('扫码已取消'), findsNothing);
      expect(find.textContaining('先扫码或粘贴'), findsOneWidget);
      expect(enabled(tester, submitButton()), isFalse);
    });

    testWidgets('解码失败显示可读原因，可重试扫码', (tester) async {
      scanner.answer = () async => throw const PairingScanFailure(
        'pairing/decode-failed',
        '照片里没有识别到配对二维码。请对准电脑上的二维码重拍，或改为粘贴配对链接。',
      );
      await pumpPage(tester);

      await tester.tap(scanButton());
      await tester.pumpAndSettle();

      expect(find.textContaining('照片里没有识别到配对二维码'), findsOneWidget);
      expect(linkText(tester), isEmpty);
      // 失败后扫码按钮恢复可点，允许重拍。
      expect(enabled(tester, scanButton()), isTrue);
    });

    testWidgets('相机不可用时提示改为粘贴，手动粘贴后仍可配对', (tester) async {
      scanner.answer = () async => throw const PairingScanFailure(
        'pairing/camera-unavailable',
        '这台手机上没有可用的相机应用，请改为粘贴电脑上的配对链接。',
      );
      await pumpPage(tester);

      await tester.tap(scanButton());
      await tester.pumpAndSettle();

      expect(find.textContaining('没有可用的相机应用'), findsOneWidget);
      await tester.enterText(linkField(), _firstLink);
      await tester.pump();
      expect(enabled(tester, submitButton()), isTrue);
    });

    testWidgets('输入框已有另一条链接时先确认，取消则保留原内容', (tester) async {
      await pumpPage(tester);
      await tester.enterText(linkField(), _firstLink);
      await tester.pump();
      scanner.answer = () async => _secondLink;

      await tester.tap(scanButton());
      await tester.pumpAndSettle();
      expect(find.text('替换已填写的链接'), findsOneWidget);

      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(linkText(tester), _firstLink);
    });

    testWidgets('确认替换后用扫码结果覆盖输入框', (tester) async {
      await pumpPage(tester);
      await tester.enterText(linkField(), _firstLink);
      await tester.pump();
      scanner.answer = () async => _secondLink;

      await tester.tap(scanButton());
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('remote-pairing-scan-replace')),
      );
      await tester.pumpAndSettle();

      expect(linkText(tester), _secondLink);
      expect(enabled(tester, submitButton()), isTrue);
    });

    testWidgets('输入框内容与扫码结果相同时不弹确认', (tester) async {
      await pumpPage(tester);
      await tester.enterText(linkField(), _firstLink);
      await tester.pump();

      await tester.tap(scanButton());
      await tester.pumpAndSettle();

      expect(find.text('替换已填写的链接'), findsNothing);
      expect(linkText(tester), _firstLink);
    });

    testWidgets('扫码中显示进度并禁用配对与再次扫码', (tester) async {
      final pending = Completer<String>();
      scanner.answer = () => pending.future;
      await pumpPage(tester);

      await tester.tap(scanButton());
      await tester.pump();

      expect(enabled(tester, scanButton()), isFalse);
      expect(enabled(tester, submitButton()), isFalse);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('在相机里对准'), findsOneWidget);

      pending.complete(_firstLink);
      await tester.pumpAndSettle();
      expect(linkText(tester), _firstLink);
      expect(enabled(tester, submitButton()), isTrue);
    });

    testWidgets('扫码后点连接走既有配对流程，并用扫到的链接', (tester) async {
      final paired = _pairedDevice();
      await pumpPage(tester, paired: paired);

      await tester.tap(scanButton());
      await tester.pumpAndSettle();
      await tester.tap(submitButton());
      await tester.pumpAndSettle();

      expect(flow.links, <String>[_firstLink]);
      expect(flow.lastDeviceLabel, 'Pixel 8');
      // 配对成功时页面带着设备记录出栈，回到调用方。
      expect(find.text('打开配对页'), findsOneWidget);
      expect(find.text('扫码配对'), findsNothing);
    });
  });

  group('MethodChannelPairingScanner', () {
    const channel = MethodChannel('dsh/runtime');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? seen;

    void mock(Future<Object?> Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(channel, (call) {
        seen = call;
        return handler(call);
      });
    }

    tearDown(() {
      seen = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('scan 解析 {text} 回执并走 remote.pairing.scan', () async {
      mock((_) async => jsonEncode(<String, Object?>{'text': _firstLink}));
      final text = await MethodChannelPairingScanner().scan();
      expect(text, _firstLink);
      expect(seen?.method, pairingScanMethod);
    });

    test('原生取消回执 {cancelled:true} 翻译成 PairingScanCancelled', () async {
      mock((_) async => jsonEncode(<String, Object?>{'cancelled': true}));
      await expectLater(
        MethodChannelPairingScanner().scan(),
        throwsA(isA<PairingScanCancelled>()),
      );
    });

    test('PlatformException 的错误码与中文消息原样交给页面', () async {
      mock(
        (_) async => throw PlatformException(
          code: 'pairing/camera-unavailable',
          message: '这台手机上没有可用的相机应用，请改为粘贴电脑上的配对链接。',
        ),
      );
      await expectLater(
        MethodChannelPairingScanner().scan(),
        throwsA(
          isA<PairingScanFailure>()
              .having((f) => f.code, 'code', 'pairing/camera-unavailable')
              .having((f) => f.message, 'message', contains('没有可用的相机应用')),
        ),
      );
    });

    test('原生 pairing/scan-cancelled 错误码同样按取消处理', () async {
      mock(
        (_) async => throw PlatformException(
          code: 'pairing/scan-cancelled',
          message: '扫码已取消。',
        ),
      );
      await expectLater(
        MethodChannelPairingScanner().scan(),
        throwsA(isA<PairingScanCancelled>()),
      );
    });

    test('没有原生通道时降级为「改为粘贴」的失败', () async {
      messenger.setMockMethodCallHandler(channel, null);
      await expectLater(
        MethodChannelPairingScanner().scan(),
        throwsA(
          isA<PairingScanFailure>().having(
            (f) => f.code,
            'code',
            'pairing/camera-unavailable',
          ),
        ),
      );
    });

    test('无法识别的回执按解码失败处理', () async {
      mock((_) async => 'not-json');
      await expectLater(
        MethodChannelPairingScanner().scan(),
        throwsA(
          isA<PairingScanFailure>().having(
            (f) => f.code,
            'code',
            'pairing/decode-failed',
          ),
        ),
      );
    });

    test('scanImage 走 debug-only 通道并带上图片路径', () async {
      mock((_) async => jsonEncode(<String, Object?>{'text': _firstLink}));
      final text = await MethodChannelPairingScanner().scanImage(
        '/data/user/0/com.minnnng.dsh_android/files/pairing-scan/qr.png',
      );
      expect(text, _firstLink);
      expect(seen?.method, pairingScanImageMethod);
      expect(
        (seen?.arguments as Map<Object?, Object?>)['path'],
        '/data/user/0/com.minnnng.dsh_android/files/pairing-scan/qr.png',
      );
    });
  });
}
