// 远程附件上行（App 侧）：反向请求应答、分页读、调用面阶段投影与会话数据源透传。
//
// 这些测试不连宿主、不拨号：
// - 反向请求用注入的设备读取器模拟 `AttachmentTransfers.read`（真实实现的形状见
//   `apps/android/android/app/src/main/kotlin/.../AttachmentTransfers.kt`）；
// - 门面调用用假传输，`attachments.prepare` 里按宿主的方式循环发
//   `native.attachments.read`，从而在 Flutter 侧走完「手机选文件 → 宿主分页拉取
//   字节 → 收据 → session.send{attachmentIds}」整条链路（设计文档 §3.4、§3.5 A3）。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/attachments.dart';
import 'package:dsh_android/remote_attachments.dart';
import 'package:dsh_android/remote_connection.dart';
import 'package:dsh_android/remote_conversation_live_source.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_device_store.dart';
import 'package:dsh_android/remote_native_bridge.dart';
import 'package:dsh_android/remote_pairing.dart';
import 'package:dsh_android/remote_transport.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/remote_conversation_fakes.dart';
import 'support/remote_tls_fixture.dart';

/// 一个合法的 `attachment.pick` 结果 id（小写 UUID v4，与设备侧生成规则一致）。
const String _attachmentId = '3f0b2f1c-6a1e-4b8e-9c2d-1a2b3c4d5e6f';

/// 另一条合法 id：只用于「从未登记」的反向请求用例，避免与同进程的登记状态耦合。
const String _unusedAttachmentId = '7c9d1a2b-3e4f-4a5b-8c6d-7e8f9a0b1c2d';

/// 由字节数组模拟的设备侧缓存：`attachment.read` 只读这一次选中副本。
class _DeviceCache {
  _DeviceCache(this.bytes);

  final List<int> bytes;

  /// 设备侧通道收到的调用（方法名与参数）。
  final List<({String method, Map<String, dynamic> params})> calls =
      <({String method, Map<String, dynamic> params})>[];

  /// `attachment.read` 返回的页数。
  int pages = 0;

  Future<String?> invoke(String method, Map<String, dynamic> params) async {
    calls.add((method: method, params: Map<String, dynamic>.of(params)));
    switch (method) {
      case 'attachment.read':
        pages++;
        final offset = params['offset'] as int;
        final length = params['length'] as int;
        if (offset < 0 || offset > bytes.length) {
          throw PlatformException(
            code: 'attachment-file/invalid-request',
            message: '读取位置已超出文件末尾',
          );
        }
        final end = offset + length < bytes.length
            ? offset + length
            : bytes.length;
        return jsonEncode(<String, dynamic>{
          'data': base64Encode(bytes.sublist(offset, end)),
          'nextOffset': end,
          'size': bytes.length,
          'eof': end >= bytes.length,
        });
      case 'attachment.discard':
        return null;
      default:
        throw PlatformException(
          code: 'attachment-method',
          message: 'Unexpected $method',
        );
    }
  }
}

/// 只记录调用的传输；测试可以注入应答，并通过 [handler] 模拟宿主反向请求。
class _RecordingTransport implements RuntimeTransport {
  final List<({String method, Map<String, dynamic> params})> requests =
      <({String method, Map<String, dynamic> params})>[];

  Future<dynamic> Function(String method, Map<String, dynamic> params)? handler;

  /// 各方法的应答；没有配置时返回 null。
  final Map<String, Future<dynamic> Function(Map<String, dynamic> params)>
  answers = <String, Future<dynamic> Function(Map<String, dynamic> params)>{};

  List<Map<String, dynamic>> paramsOf(String method) => <Map<String, dynamic>>[
    for (final request in requests)
      if (request.method == method) request.params,
  ];

  @override
  Stream<Map<String, dynamic>> get events =>
      Stream<Map<String, dynamic>>.empty();

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async {
    requests.add((method: method, params: Map<String, dynamic>.of(params)));
    final answer = answers[method];
    if (answer != null) return answer(params);
    return <String, dynamic>{};
  }

  @override
  void notify(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {}

  @override
  void setRequestHandler(
    Future<dynamic> Function(String method, Map<String, dynamic> params)?
    handler,
  ) {
    this.handler = handler;
  }

  @override
  Future<void> close() async {}
}

/// 会话数据源与附件调用面需要的假连接。
class _FakeAttachmentConnection extends ChangeNotifier
    implements RemoteAttachmentConnection {
  _FakeAttachmentConnection({required this.transport});

  @override
  RuntimeTransport? transport;

  @override
  RemoteConnectionPhase phase = RemoteConnectionPhase.ready;

  @override
  String? lastError;

  void setPhase(RemoteConnectionPhase next, {String? error}) {
    phase = next;
    lastError = error;
    notifyListeners();
  }
}

/// 把「宿主」行为接到假传输上：`attachments.prepare` 内循环反向请求分页读。
void _serveAttachmentPrepare(
  _RecordingTransport transport,
  _DeviceCache device,
) {
  transport.answers['attachments.prepare'] = (params) async {
    final id = params['id'] as String;
    final assembled = <int>[];
    var offset = 0;
    var pages = 0;
    while (true) {
      final page = await transport.handler!(
        remoteAttachmentReadMethod,
        <String, dynamic>{
          'id': id,
          'offset': offset,
          'length': remoteAttachmentReadPageBytes,
        },
      ) as Map<String, dynamic>;
      assembled.addAll(base64Decode(page['data'] as String));
      offset = page['nextOffset'] as int;
      pages++;
      if (page['eof'] == true) break;
    }
    expect(assembled, device.bytes, reason: '宿主按页拼回的字节必须与设备副本一致');
    expect(pages, (device.bytes.length / remoteAttachmentReadPageBytes).ceil());
    return <String, dynamic>{
      'id': id,
      'kind': 'file',
      'name': params['name'] ?? '附件',
      'bytes': assembled.length,
      'receiptId': 'receipt-$id',
    };
  };
}

/// 模拟 `attachment.pick` 原生通道：返回一条固定选中项。
void _mockPicker(
  TestWidgetsFlutterBinding binding, {
  String id = _attachmentId,
  String name = '季度报告.pdf',
  int bytes = 12,
  String mediaType = 'application/pdf',
}) {
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    RuntimeController.channel,
    (call) async => call.method == 'attachment.pick'
        ? jsonEncode(<String, dynamic>{
            'cancelled': false,
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': id,
                'name': name,
                'bytes': bytes,
                'mediaType': mediaType,
              },
            ],
            'failures': <Object>[],
          })
        : null,
  );
  addTearDown(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RuntimeController.channel,
      null,
    ),
  );
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------- 反向请求
  group('native.attachments.read 反向应答', () {
    test('小文件单页：返回 §3.4.2 的 data/nextOffset/size/eof', () async {
      final device = _DeviceCache(
        List<int>.generate(1000, (index) => index % 251),
      );
      final bridge = RemoteNativeBridge(invokeDevice: device.invoke);
      bridge.allow(_attachmentId);

      final reply = await bridge.handle(
        remoteAttachmentReadMethod,
        <String, dynamic>{
          'id': _attachmentId,
          'offset': 0,
          'length': remoteAttachmentReadPageBytes,
        },
      ) as Map<String, dynamic>;

      expect(base64Decode(reply['data'] as String), device.bytes);
      expect(reply['nextOffset'], 1000);
      expect(reply['size'], 1000);
      expect(reply['eof'], isTrue);
      expect(device.calls.single.params, <String, dynamic>{
        'id': _attachmentId,
        'offset': 0,
        'length': remoteAttachmentReadPageBytes,
      });
    });

    test('多页大文件：按 256 KiB 推进直到 eof，拼回原字节', () async {
      final total = remoteAttachmentReadPageBytes * 2 + 40000;
      final device = _DeviceCache(
        List<int>.generate(total, (index) => (index * 31) % 256),
      );
      final bridge = RemoteNativeBridge(invokeDevice: device.invoke);
      bridge.allow(_attachmentId);

      final assembled = <int>[];
      var offset = 0;
      while (true) {
        final page = await bridge.handle(
          remoteAttachmentReadMethod,
          <String, dynamic>{
            'id': _attachmentId,
            'offset': offset,
            'length': remoteAttachmentReadPageBytes,
          },
        ) as Map<String, dynamic>;
        assembled.addAll(base64Decode(page['data'] as String));
        offset = page['nextOffset'] as int;
        expect(page['size'], total);
        if (page['eof'] == true) break;
      }

      expect(assembled, device.bytes);
      expect(device.pages, 3);
    });

    test('未登记与格式非法的 id 一律 not-found，不暴露本机文件', () async {
      final device = _DeviceCache(const <int>[1, 2, 3]);
      final bridge = RemoteNativeBridge(invokeDevice: device.invoke);

      for (final id in <Object?>[_attachmentId, 'not-a-uuid', 7]) {
        await expectLater(
          bridge.handle(remoteAttachmentReadMethod, <String, dynamic>{
            'id': id,
            'offset': 0,
            'length': 1,
          }),
          throwsA(
            isA<RuntimeTransportFailure>().having(
              (failure) => failure.code,
              'code',
              id == 7
                  ? 'attachment-file/invalid-request'
                  : 'attachment-file/not-found',
            ),
          ),
        );
      }
      expect(device.calls, isEmpty, reason: '未登记的 id 不触碰设备侧文件');
    });

    test('请求范围越界回 invalid-request', () async {
      final device = _DeviceCache(const <int>[1]);
      final bridge = RemoteNativeBridge(invokeDevice: device.invoke);
      bridge.allow(_attachmentId);

      for (final range in <({int offset, int length})>[
        (offset: -1, length: 1),
        (offset: 0, length: 0),
        (offset: 0, length: remoteAttachmentReadPageBytes + 1),
      ]) {
        await expectLater(
          bridge.handle(remoteAttachmentReadMethod, <String, dynamic>{
            'id': _attachmentId,
            'offset': range.offset,
            'length': range.length,
          }),
          throwsA(
            isA<RuntimeTransportFailure>().having(
              (failure) => failure.code,
              'code',
              'attachment-file/invalid-request',
            ),
          ),
        );
      }
    });

    test('未知方法抛 UnsupportedError（传输层据此回 -32601）', () async {
      final bridge = RemoteNativeBridge(
        invokeDevice: _DeviceCache(const <int>[1]).invoke,
      );
      for (final method in <String>[
        'native.documents.roots',
        'native.attachments.write',
        'native.attachments.read.extra',
      ]) {
        await expectLater(
          bridge.handle(method, const <String, dynamic>{}),
          throwsA(isA<UnsupportedError>()),
        );
      }
    });

    test('设备侧失败按错误码透传，未知设备错误归为 gateway/internal', () async {
      var error = PlatformException(
        code: 'attachment-file/not-found',
        message: '文件已不在手机上',
      );
      final bridge = RemoteNativeBridge(
        invokeDevice: (method, params) async => throw error,
      );
      bridge.allow(_attachmentId);

      await expectLater(
        bridge.handle(remoteAttachmentReadMethod, <String, dynamic>{
          'id': _attachmentId,
          'offset': 0,
          'length': 1,
        }),
        throwsA(
          isA<RuntimeTransportFailure>()
              .having(
                (failure) => failure.code,
                'code',
                'attachment-file/not-found',
              )
              .having((failure) => failure.message, 'message', '文件已不在手机上'),
        ),
      );

      error = PlatformException(code: 'attachment-busy', message: '忙');
      await expectLater(
        bridge.handle(remoteAttachmentReadMethod, <String, dynamic>{
          'id': _attachmentId,
          'offset': 0,
          'length': 1,
        }),
        throwsA(
          isA<RuntimeTransportFailure>().having(
            (failure) => failure.code,
            'code',
            'gateway/internal',
          ),
        ),
      );
    });

    test('设备返回形状不合法时拒绝，不把坏帧交给宿主', () async {
      final bridge = RemoteNativeBridge(
        invokeDevice: (method, params) async => jsonEncode(<String, dynamic>{
          'data': '',
          'nextOffset': 0,
          'size': 10,
          'eof': false,
        }),
      );
      bridge.allow(_attachmentId);

      await expectLater(
        bridge.handle(remoteAttachmentReadMethod, <String, dynamic>{
          'id': _attachmentId,
          'offset': 0,
          'length': 10,
        }),
        throwsA(
          isA<RuntimeTransportFailure>().having(
            (failure) => failure.code,
            'code',
            'gateway/internal',
          ),
        ),
      );
    });

    test('连接换代后旧传输上的反向请求不再被应答', () async {
      final device = _DeviceCache(const <int>[1, 2, 3]);
      final bridge = RemoteNativeBridge(invokeDevice: device.invoke);
      bridge.allow(_attachmentId);
      final first = _RecordingTransport();
      final second = _RecordingTransport();
      bridge.install(first);
      bridge.install(second);

      await expectLater(
        first.handler!(remoteAttachmentReadMethod, <String, dynamic>{
          'id': _attachmentId,
          'offset': 0,
          'length': 3,
        }),
        throwsA(isA<UnsupportedError>()),
      );
      final reply = await second.handler!(
        remoteAttachmentReadMethod,
        <String, dynamic>{'id': _attachmentId, 'offset': 0, 'length': 3},
      ) as Map<String, dynamic>;
      expect(reply['size'], 3);
    });

    test('连接建立后安装处理器：只应答 native.attachments.read，其余回 -32601', () async {
      final link = _InstallingTransport();
      final controller = RemoteConnectionController(
        store: RemoteDeviceStore(
          channel: const MethodChannel('test/remote_attachments_unused'),
          tokens: _MemoryTokenVault(),
        ),
        createTransport: ({
          required String endpoint,
          required String token,
          required String pinnedCaPem,
          required bool systemTrust,
          required String deviceLabel,
          required String appVersion,
          required List<String> capabilities,
        }) => link,
      );
      addTearDown(controller.dispose);

      await controller.connect(
        RemoteDevice(
          id: '0123456789abcdef0123456789abcdef',
          label: 'Pixel 8',
          host: '192.168.1.20',
          port: 4777,
          instanceId: caCertificateFingerprint(pairingCaPem),
          caPem: pairingCaPem,
          createdAt: DateTime.utc(2026, 11, 15, 6),
        ),
      );

      final handler = link.requestHandler;
      expect(handler, isNotNull, reason: '连接建好传输后必须安装反向请求处理器');
      await expectLater(
        handler!('native.documents.roots', const <String, dynamic>{}),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        handler(remoteAttachmentReadMethod, <String, dynamic>{
          'id': _unusedAttachmentId,
          'offset': 0,
          'length': 1,
        }),
        throwsA(
          isA<RuntimeTransportFailure>().having(
            (failure) => failure.code,
            'code',
            'attachment-file/not-found',
          ),
        ),
      );
    });
  });

  // ---------------------------------------------------------------- 调用面
  group('RemoteAttachmentSurface', () {
    test('prepare 登记草稿、release 注销并清理手机副本', () async {
      final device = _DeviceCache(const <int>[1]);
      final bridge = RemoteNativeBridge(invokeDevice: device.invoke);
      final transport = _RecordingTransport();
      final connection = _FakeAttachmentConnection(transport: transport);
      final surface = RemoteAttachmentSurface(
        connection: connection,
        bridge: bridge,
      );
      addTearDown(surface.dispose);

      await surface.call(remoteAttachmentPrepareMethod, <String, dynamic>{
        'sessionId': 's-1',
        'id': _attachmentId,
        'name': '季度报告.pdf',
        'mediaType': 'application/pdf',
        'bytes': 12,
      });
      expect(bridge.allows(_attachmentId), isTrue);
      expect(transport.paramsOf(remoteAttachmentPrepareMethod).single, {
        'sessionId': 's-1',
        'id': _attachmentId,
        'name': '季度报告.pdf',
        'mediaType': 'application/pdf',
        'bytes': 12,
      });

      await surface.call(remoteAttachmentReleaseMethod, <String, dynamic>{
        'sessionId': 's-1',
        'id': _attachmentId,
      });
      expect(bridge.allows(_attachmentId), isFalse);
      expect(
        device.calls.map((call) => call.method),
        contains('attachment.discard'),
        reason: 'release 受理后删除手机上的私有副本',
      );
    });

    test('断连时 call 以 gateway/cancelled 失败；重连换代后 generation 递增', () async {
      final transport = _RecordingTransport();
      final connection = _FakeAttachmentConnection(transport: transport);
      final surface = RemoteAttachmentSurface(
        connection: connection,
        bridge: RemoteNativeBridge(invokeDevice: _DeviceCache(const []).invoke),
      );
      addTearDown(surface.dispose);
      expect(surface.ready, isTrue);
      expect(surface.phase, 'ready');
      expect(surface.connectionGeneration, 0);

      connection.setPhase(RemoteConnectionPhase.reconnecting);
      expect(surface.ready, isFalse);
      expect(surface.phase, 'reconnecting');
      await expectLater(
        surface.call(remoteAttachmentPrepareMethod, const <String, dynamic>{}),
        throwsA(
          isA<RemoteAttachmentFailure>()
              .having((failure) => failure.code, 'code', 'gateway/cancelled')
              .having(
                (failure) => failure.message,
                'message',
                '与电脑的连接已断开，请重试。',
              ),
        ),
      );
      expect(transport.requests, isEmpty);

      connection.setPhase(RemoteConnectionPhase.ready);
      expect(surface.connectionGeneration, 1);
    });

    test('attachment-file/unsupported 翻译成「这台手机上的 App 版本不支持上传附件」', () async {
      final transport = _RecordingTransport()
        ..answers[remoteAttachmentPrepareMethod] = (params) async =>
            <String, dynamic>{
              '_pocket_error': <String, dynamic>{
                'code': 'attachment-file/unsupported',
                'message': 'attachment-file/unsupported',
              },
            };
      final connection = _FakeAttachmentConnection(transport: transport);
      final surface = RemoteAttachmentSurface(
        connection: connection,
        bridge: RemoteNativeBridge(invokeDevice: _DeviceCache(const []).invoke),
      );
      addTearDown(surface.dispose);

      await expectLater(
        surface.call(remoteAttachmentPrepareMethod, <String, dynamic>{
          'sessionId': 's-1',
          'id': _attachmentId,
        }),
        throwsA(
          isA<RemoteAttachmentFailure>()
              .having(
                (failure) => failure.code,
                'code',
                'attachment-file/unsupported',
              )
              .having(
                (failure) => failure.message,
                'message',
                '这台手机上的 App 版本不支持上传附件。',
              ),
        ),
      );
    });

    test('not-found 与断连中途中止都给出 §3.4.3 的专用文案', () async {
      var failure = const RuntimeTransportFailure(
        code: 'attachment-file/not-found',
        message: 'ENOENT',
      );
      final transport = _RecordingTransport()
        ..answers[remoteAttachmentPrepareMethod] = (params) async =>
            throw failure;
      final surface = RemoteAttachmentSurface(
        connection: _FakeAttachmentConnection(transport: transport),
        bridge: RemoteNativeBridge(invokeDevice: _DeviceCache(const []).invoke),
      );
      addTearDown(surface.dispose);

      await expectLater(
        surface.call(remoteAttachmentPrepareMethod, <String, dynamic>{
          'id': _attachmentId,
        }),
        throwsA(
          isA<RemoteAttachmentFailure>().having(
            (failure) => failure.message,
            'message',
            '文件已不在手机上，请重新选择。',
          ),
        ),
      );

      failure = const RuntimeTransportFailure(
        code: 'gateway/cancelled',
        message: '操作已取消（连接或页面已关闭）。',
      );
      await expectLater(
        surface.call(remoteAttachmentPrepareMethod, <String, dynamic>{
          'id': _attachmentId,
        }),
        throwsA(
          isA<RemoteAttachmentFailure>()
              .having((failure) => failure.code, 'code', 'gateway/cancelled')
              .having((failure) => failure.message, 'message', '连接已断开，请重试。'),
        ),
      );
    });
  });

  // ------------------------------------------------------------ 草稿 + 上行链路
  group('附件草稿（远程调用面）', () {
    test('多页大文件：宿主按页拉取、拼回原字节并给出收据', () async {
      _mockPicker(binding, bytes: 12);
      final device = _DeviceCache(
        List<int>.generate(700000, (index) => index % 256),
      );
      final transport = _RecordingTransport();
      final bridge = RemoteNativeBridge(invokeDevice: device.invoke);
      bridge.install(transport);
      _serveAttachmentPrepare(transport, device);
      final drafts = AttachmentDrafts(
        RemoteAttachmentSurface(
          connection: _FakeAttachmentConnection(transport: transport),
          bridge: bridge,
        ),
      );
      addTearDown(drafts.dispose);

      await drafts.pick('s-1');

      expect(drafts.ready('s-1'), isTrue);
      expect(drafts.snapshotIds('s-1'), <String>[_attachmentId]);
      expect(drafts.items('s-1').single.name, '季度报告.pdf');
      expect(
        transport.paramsOf(remoteAttachmentPrepareMethod).single,
        <String, dynamic>{
          'sessionId': 's-1',
          'id': _attachmentId,
          'name': '季度报告.pdf',
          'mediaType': 'application/pdf',
          'bytes': 12,
        },
        reason: '远程调用面在 prepare 上带草稿元数据供宿主对账',
      );
      expect(device.pages, 3, reason: '700000 字节按 256 KiB 分三页拉取');

      await drafts.consume('s-1', <String>[_attachmentId]);
      expect(drafts.items('s-1'), isEmpty);
      expect(bridge.allows(_attachmentId), isFalse);
      expect(transport.paramsOf(remoteAttachmentReleaseMethod).single, {
        'sessionId': 's-1',
        'id': _attachmentId,
      });
    });

    test('旧宿主返回 attachment-file/unsupported 时草稿显示可读原因', () async {
      _mockPicker(binding);
      final transport = _RecordingTransport()
        ..answers[remoteAttachmentPrepareMethod] = (params) async =>
            throw const RuntimeTransportFailure(
              code: 'attachment-file/unsupported',
              message: 'unsupported',
            );
      final drafts = AttachmentDrafts(
        RemoteAttachmentSurface(
          connection: _FakeAttachmentConnection(transport: transport),
        ),
      );
      addTearDown(drafts.dispose);

      await drafts.pick('s-1');

      expect(drafts.ready('s-1'), isFalse);
      final item = drafts.items('s-1').single;
      expect(item.status, 'error');
      expect(item.error, '这台手机上的 App 版本不支持上传附件。');
      expect(() => drafts.snapshotIds('s-1'), throwsStateError);
    });

    test('断连中止：已准备草稿置为可重试错误，重连后重试不再重新选择文件', () async {
      _mockPicker(binding);
      final device = _DeviceCache(const <int>[1, 2, 3]);
      final transport = _RecordingTransport();
      final bridge = RemoteNativeBridge(invokeDevice: device.invoke);
      bridge.install(transport);
      _serveAttachmentPrepare(transport, device);
      final connection = _FakeAttachmentConnection(transport: transport);
      final drafts = AttachmentDrafts(
        RemoteAttachmentSurface(connection: connection, bridge: bridge),
      );
      addTearDown(drafts.dispose);

      await drafts.pick('s-1');
      expect(drafts.ready('s-1'), isTrue);

      connection.setPhase(RemoteConnectionPhase.reconnecting);
      expect(drafts.ready('s-1'), isFalse);
      expect(drafts.items('s-1').single.error, contains('服务已重启'));
      expect(() => drafts.snapshotIds('s-1'), throwsStateError);

      connection.setPhase(RemoteConnectionPhase.ready);
      await drafts.retry('s-1', _attachmentId);
      expect(drafts.ready('s-1'), isTrue);
      expect(transport.paramsOf(remoteAttachmentPrepareMethod), hasLength(2));
    });

    test('上传失败后移除再重试：release 注销草稿，重新准备成功', () async {
      _mockPicker(binding);
      final device = _DeviceCache(const <int>[1, 2, 3]);
      final transport = _RecordingTransport();
      final bridge = RemoteNativeBridge(invokeDevice: device.invoke);
      bridge.install(transport);
      transport.answers[remoteAttachmentPrepareMethod] = (params) async =>
          throw const RuntimeTransportFailure(
            code: 'gateway/cancelled',
            message: '断线',
          );
      final drafts = AttachmentDrafts(
        RemoteAttachmentSurface(
          connection: _FakeAttachmentConnection(transport: transport),
          bridge: bridge,
        ),
      );
      addTearDown(drafts.dispose);

      await drafts.pick('s-1');
      expect(drafts.items('s-1').single.status, 'error');
      expect(drafts.items('s-1').single.error, '连接已断开，请重试。');

      await drafts.remove('s-1', _attachmentId);
      expect(drafts.items('s-1'), isEmpty);
      expect(bridge.allows(_attachmentId), isFalse);

      _serveAttachmentPrepare(transport, device);
      await drafts.pick('s-1');
      expect(drafts.ready('s-1'), isTrue);
    });
  });

  // ------------------------------------------------------------ 数据源透传
  group('RemoteConversationLiveSource 的附件参数', () {
    ({RemoteConversationLiveSource source, _RecordingTransport transport})
    liveSource() {
      final transport = _RecordingTransport();
      transport.answers['api.subscribe'] = (params) async => <String, dynamic>{
        'streamId': params['streamId'],
        'generation': 'generation-1',
      };
      transport.answers['settings.describe'] = (params) async =>
          <Map<String, dynamic>>[
            <String, dynamic>{
              'ns': 'agent-default-model',
              'value': <String, dynamic>{
                'provider': 'deepseek-account',
                'model': 'deepseek-flash',
              },
            },
          ];
      final connection = FakeRemoteConnection(
        transport: transport,
        supported: <String>{
          remoteConversationReadMethod,
          remoteConversationSendMethod,
          remoteConversationCommandMethod,
        },
      );
      final events = StreamController<Map<String, dynamic>>.broadcast(
        sync: true,
      );
      final source = RemoteConversationLiveSource(
        connection: connection,
        sessionId: 's-1',
        events: events.stream,
      );
      addTearDown(() async {
        source.dispose();
        await events.close();
      });
      return (source: source, transport: transport);
    }

    test('send 透传 attachmentIds；没有附件时字段缺席', () async {
      final (:source, :transport) = liveSource();

      await source.send('这条带附件', attachmentIds: <String>[_attachmentId]);
      await source.send('这条没有附件');

      final sent = transport.paramsOf(remoteConversationSendMethod);
      expect(sent, hasLength(2));
      expect(sent.first['text'], '这条带附件');
      expect(sent.first['attachmentIds'], <String>[_attachmentId]);
      expect(sent.last.containsKey('attachmentIds'), isFalse);
      expect(sent.first['sessionId'], 's-1');
    });

    test('submitCommand 透传 attachmentIds（含空数组）', () async {
      final (:source, :transport) = liveSource();
      transport.answers[remoteConversationCommandMethod] = (params) async =>
          <String, dynamic>{
            'commandId': 'c-1',
            'result': <String, dynamic>{'kind': 'success'},
          };

      final withAttachment = await source.submitCommand(
        '/plan',
        attachmentIds: <String>[_attachmentId],
      );
      final withoutAttachment = await source.submitCommand('/plan');

      expect(withAttachment.succeeded, isTrue);
      expect(withoutAttachment.succeeded, isTrue);
      final commands = transport.paramsOf(remoteConversationCommandMethod);
      expect(commands.first, <String, dynamic>{
        'sessionId': 's-1',
        'line': '/plan',
        'attachmentIds': <String>[_attachmentId],
      });
      expect(commands.last['attachmentIds'], isEmpty);
    });

    test('createAttachmentSurface 返回绑定同一条连接的调用面', () async {
      final (:source, :transport) = liveSource();
      final surface = source.createAttachmentSurface();
      expect(surface, isA<RemoteAttachmentSurface>());
      final remote = surface as RemoteAttachmentSurface;
      expect(remote.connection.phase, RemoteConnectionPhase.ready);
      expect(remote.connection.transport, same(transport));
    });
  });
}

/// 不拨号的传输替身：只记录安装进来的反向请求处理器。
class _InstallingTransport implements RemoteTransportLink {
  /// `connect` 安装进来的反向请求处理器；没有安装时为 null。
  Future<dynamic> Function(String method, Map<String, dynamic> params)?
  requestHandler;

  final Completer<RemoteHostInfo> _handshake = Completer<RemoteHostInfo>();

  @override
  Stream<Map<String, dynamic>> get events =>
      Stream<Map<String, dynamic>>.empty();

  @override
  Future<RemoteHostInfo> get handshake => _handshake.future;

  @override
  RemoteHostInfo? get host => null;

  @override
  String get phase => 'handshaking';

  @override
  bool get isClosed => false;

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) async => <String, dynamic>{};

  @override
  void notify(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {}

  @override
  void setRequestHandler(
    Future<dynamic> Function(String method, Map<String, dynamic> params)?
    handler,
  ) {
    requestHandler = handler;
  }

  @override
  Future<void> close() async {}
}

/// 内存版本的设备令牌保管口：测试不碰 Keystore、不读偏好。
class _MemoryTokenVault implements RemoteDeviceTokenVault {
  @override
  Future<void> delete(String tokenRef) async {}

  @override
  Future<bool> isConfigured(String tokenRef) async => true;

  @override
  Future<String> read(String tokenRef) async =>
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';

  @override
  Future<void> write(String tokenRef, String token) async {}
}
