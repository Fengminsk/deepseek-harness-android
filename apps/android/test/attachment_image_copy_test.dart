import 'package:dsh_android/image_preview.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RuntimeController.channel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(RuntimeController.channel, null),
    );
  }

  test('copyAttachmentImage asks the native cache for the verified bytes', () async {
    final calls = <MethodCall>[];
    mockChannel((call) async {
      calls.add(call);
      return null;
    });
    expect(await copyAttachmentImage('att-1'), isNull);
    expect(calls.single.method, 'attachmentFile.copyImage');
    expect(calls.single.arguments, {'id': 'att-1'});
  });

  test('a rejected copy keeps the native reason', () async {
    mockChannel((call) async {
      throw PlatformException(
        code: 'attachment-copy-kind',
        message: '只有图片附件可以复制为剪贴板内容',
      );
    });
    expect(await copyAttachmentImage('att-2'), '只有图片附件可以复制为剪贴板内容');
  });

  test('an unexpected failure still reports a retryable message', () async {
    mockChannel((call) async => throw StateError('bridge unavailable'));
    expect(await copyAttachmentImage('att-3'), '无法复制图片，请重试。');
  });
}
