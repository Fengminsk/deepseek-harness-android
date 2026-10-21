import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'automations_fixture.dart';

// Retain the real EventChannel status handler and connection generation while
// isolating unrelated account, session, Web and task baseline reads.
class AutomationConnectionRuntime extends AutomationRuntime {
  @override
  Future<void> refresh() async {}
}

Future<MockStreamHandlerEventSink> attachAutomationConnection(
  AutomationConnectionRuntime runtime,
) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final listening = Completer<MockStreamHandlerEventSink>();
  messenger.setMockStreamHandler(
    RuntimeController.events,
    MockStreamHandler.inline(onListen: (_, sink) => listening.complete(sink)),
  );
  messenger.setMockMethodCallHandler(
    RuntimeController.channel,
    (_) async => null,
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(RuntimeController.channel, null);
    messenger.setMockStreamHandler(RuntimeController.events, null);
  });
  await runtime.start();
  return listening.future;
}

void automationConnection(
  MockStreamHandlerEventSink sink,
  String generation, {
  String phase = 'ready',
}) => sink.success(
  jsonEncode({
    'method': 'runtime.status',
    'params': {'phase': phase, 'generation': generation},
  }),
);
