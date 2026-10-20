import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/subagents_data.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const address = SubagentAddress(
  parentSessionId: 'parent',
  childSessionId: 'child',
  mode: 'continuable',
);

Json record(int seq, String text) => {
  'type': 'event',
  'event': {
    'seq': seq,
    'time': seq * 1000,
    'type': 'user/message',
    'surfaceOp': 'append',
    'data': {
      'id': 'message-$seq',
      'role': 'user',
      'source': {'kind': 'user'},
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  },
};

Json inspection({
  String mode = 'continuable',
  bool running = false,
  bool canPrompt = true,
  String? reason,
  int cursor = 9,
  List<Json>? records,
  bool hasMore = false,
  Json? submission,
}) => {
  'address': {...address.json, 'mode': mode},
  'snapshot': {
    'type': 'snapshot',
    'cursor': cursor,
    'hasMore': hasMore,
    'records': records ?? [record(9, 'saved input')],
  },
  'capabilities': {
    'parentAvailable': true,
    'attached': running,
    'running': running,
    'canPrompt': canPrompt,
    'canInterrupt': running,
    'readOnlyReason': reason,
  },
  'task': {
    'pending': [
      {'itemId': 'q1', 'prompt': 'queued input', 'status': 'queued'},
    ],
    'history': <Json>[],
  },
  'submission': submission,
};

class SubagentsRuntime extends RuntimeController {
  SubagentsRuntime() {
    phase = 'ready';
    taskState = {'epoch': 'one'};
  }
  Json currentInspection = inspection();
  Json older = {
    'records': [record(3, 'earlier input')],
    'hasMore': false,
  };
  final calls = <(String, Json)>[];
  Future<dynamic> Function(String, Json)? handle;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, Map.of(params)));
    if (handle != null) return handle!(method, params);
    return switch (method) {
      'subagents.inspect' => currentInspection,
      'subagents.page' => older,
      'subagents.send' => {'messageId': 'accepted-message'},
      'subagents.interrupt' => {'accepted': true},
      _ => throw StateError('Unexpected $method'),
    };
  }
}

void main() {
  late SubagentsRuntime runtime;
  late SubagentConversation conversation;

  setUp(() {
    runtime = SubagentsRuntime();
    conversation = SubagentConversation(runtime, address);
  });
  tearDown(() {
    conversation.dispose();
    runtime.dispose();
  });

  test(
    'read and older-page requests preserve direct parent and exclusive cut',
    () async {
      runtime.currentInspection = inspection(hasMore: true);
      await conversation.refresh();
      await conversation.loadOlder();
      expect(runtime.calls.map((call) => call.$1), [
        'subagents.inspect',
        'subagents.page',
      ]);
      expect(runtime.calls.last.$2, {
        'address': address.json,
        'throughSeq': 9,
        'beforeSeq': 9,
        'maxMessages': 50,
      });
      expect(conversation.events.map((event) => event['seq']), [3, 9]);
      await conversation.refresh();
      expect(conversation.events.map((event) => event['seq']), [3, 9]);
      expect(conversation.hasMore, isFalse);
      expect(runtime.calls.any((call) => call.$1 == 'session.send'), isFalse);
    },
  );

  test(
    'unknown admission preserves exact identity and draft without replay',
    () async {
      runtime.handle = (method, params) async {
        if (method == 'subagents.send') throw TimeoutException('lost receipt');
        if (method == 'subagents.inspect') {
          return inspection(
            submission: params['requestId'] == null
                ? null
                : {'requestId': params['requestId'], 'state': 'not-observed'},
          );
        }
        throw StateError('Unexpected $method');
      };
      await conversation.refresh();
      conversation.edit('keep this exact input');
      conversation.selectDelivery('steer');
      await conversation.send();
      final request = runtime.calls
          .firstWhere((call) => call.$1 == 'subagents.send')
          .$2;
      expect(request['address'], address.json);
      expect(request['delivery'], 'steer');
      expect(request['text'], 'keep this exact input');
      expect(conversation.uncertain, isTrue);
      expect(conversation.draft, 'keep this exact input');
      await conversation.refresh();
      await conversation.send();
      expect(
        runtime.calls.where((call) => call.$1 == 'subagents.send'),
        hasLength(1),
      );
      expect(conversation.submission!.requestId, request['requestId']);
      expect(conversation.canSend, isFalse);

      runtime.handle = (method, params) async {
        if (method != 'subagents.inspect') {
          throw StateError('Unexpected $method');
        }
        return inspection(
          submission: {
            'requestId': params['requestId'],
            'state': 'observed',
            'messageId': 'persisted-identity',
          },
        );
      };
      await conversation.refresh();
      expect(conversation.submission, isNull);
      expect(conversation.draft, '');
      expect(conversation.actionMessage, contains('已被接收'));
      expect(conversation.actionMessage, isNot(contains('已完成')));
    },
  );

  test('late admission never clears edits made after submission', () async {
    final receipt = Completer<Json>();
    runtime.handle = (method, params) async {
      if (method == 'subagents.send') return receipt.future;
      return inspection();
    };
    await conversation.refresh();
    conversation.edit('first input');
    final pending = conversation.send();
    conversation.edit('next draft');
    receipt.complete({'messageId': 'accepted-message'});
    await pending;
    expect(conversation.draft, 'next draft');
    expect(conversation.submission, isNull);
  });

  test(
    'a receipt from before restart only triggers read-only reconciliation',
    () async {
      final receipt = Completer<Json>();
      runtime.handle = (method, params) async {
        if (method == 'subagents.send') return receipt.future;
        return inspection(
          submission: params['requestId'] == null
              ? null
              : {'requestId': params['requestId'], 'state': 'not-observed'},
        );
      };
      await conversation.refresh();
      conversation.edit('survive the reconnect');
      final pending = conversation.send();
      runtime.taskState = {'epoch': 'two'};
      runtime.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      receipt.complete({'messageId': 'old-runtime-admission'});
      await pending;
      expect(conversation.draft, 'survive the reconnect');
      expect(conversation.uncertain, isTrue);
      expect(conversation.canSend, isFalse);
      expect(
        runtime.calls.where((call) => call.$1 == 'subagents.send'),
        hasLength(1),
      );
      expect(
        runtime.calls.last.$2['requestId'],
        conversation.submission!.requestId,
      );
    },
  );

  test('unchanged snapshots retain event identity while revised presentation replaces it', () async {
    await conversation.refresh();
    final oldEvents = conversation.events;
    final oldEvent = oldEvents.single;
    runtime.currentInspection = inspection();
    await conversation.refresh();
    expect(identical(conversation.events, oldEvents), isTrue);
    expect(identical(conversation.events.single, oldEvent), isTrue);
    runtime.currentInspection = inspection(
      records: [record(9, 'restored content')],
    );
    await conversation.refresh();
    expect(identical(conversation.events.single, oldEvent), isFalse);
    expect(
      conversation.events.single['data']['content'][0]['text'],
      'restored content',
    );
  });

  test(
    'known rejection retains draft and permits a new explicit submission',
    () async {
      runtime.handle = (method, params) async {
        if (method == 'subagents.send') {
          throw PlatformException(code: 'subagent/parent-unavailable');
        }
        return inspection();
      };
      await conversation.refresh();
      conversation.edit('not admitted');
      await conversation.send();
      expect(conversation.draft, 'not admitted');
      expect(conversation.submission, isNull);
      expect(conversation.actionMessage, contains('核心未接受'));
      expect(conversation.canSend, isTrue);
      expect(
        runtime.calls.where((call) => call.$1 == 'subagents.send'),
        hasLength(1),
      );
    },
  );

  test(
    'reopening an uncertain child retains its exact request without replay',
    () async {
      runtime.handle = (method, params) async {
        if (method == 'subagents.send') {
          throw TimeoutException('lost acknowledgement');
        }
        return inspection(
          submission: params['requestId'] == null
              ? null
              : {'requestId': params['requestId'], 'state': 'not-observed'},
        );
      };
      await conversation.refresh();
      conversation.edit('original submission');
      await conversation.send();
      final requestId = conversation.submission!.requestId;
      conversation.edit('later unsent edits');
      conversation.dispose();
      conversation = SubagentConversation(runtime, address);
      await conversation.refresh();
      await conversation.send();
      expect(conversation.draft, 'later unsent edits');
      expect(conversation.submission!.text, 'original submission');
      expect(conversation.submission!.requestId, requestId);
      expect(conversation.uncertain, isTrue);
      expect(runtime.calls.last.$2['requestId'], requestId);
      expect(
        runtime.calls.where((call) => call.$1 == 'subagents.send'),
        hasLength(1),
      );
    },
  );

  test(
    'one-shot and unavailable parents cannot be sent to through ordinary chat',
    () async {
      runtime.currentInspection = inspection(
        mode: 'one-shot',
        canPrompt: false,
        reason: 'one-shot',
      );
      await conversation.refresh();
      conversation.edit('retained');
      await conversation.send();
      await conversation.interrupt();
      expect(conversation.address.mode, 'one-shot');
      expect(conversation.draft, 'retained');
      expect(
        runtime.calls.every((call) => call.$1 == 'subagents.inspect'),
        isTrue,
      );
    },
  );

  test(
    'accepted interrupt waits for core quiescence and keeps pending inputs',
    () async {
      runtime.currentInspection = inspection(running: true);
      await conversation.refresh();
      await conversation.interrupt();
      expect(conversation.stopping, isTrue);
      expect(conversation.actionMessage, contains('等待核心确认'));
      expect((conversation.task['pending'] as List), hasLength(1));
      expect(
        runtime.calls.firstWhere((call) => call.$1 == 'subagents.interrupt').$2,
        {'address': address.json},
      );
      runtime.currentInspection = inspection();
      await conversation.refresh();
      expect(conversation.stopping, isFalse);
      expect((conversation.task['pending'] as List), hasLength(1));
      expect(runtime.calls.any((call) => call.$1 == 'session.cancel'), isFalse);
    },
  );

  test('old inspection cannot overwrite a restarted connection', () async {
    final old = Completer<Json>(), fresh = Completer<Json>();
    var reads = 0;
    runtime.handle = (_, _) => reads++ == 0 ? old.future : fresh.future;
    final first = conversation.refresh();
    runtime.phase = 'restarting';
    runtime.notifyListeners();
    runtime.phase = 'ready';
    runtime.taskState = {'epoch': 'two'};
    runtime.notifyListeners();
    fresh.complete(inspection(cursor: 4, records: [record(4, 'new process')]));
    await Future<void>.delayed(Duration.zero);
    old.complete(inspection(cursor: 9, records: [record(9, 'old process')]));
    await first;
    expect(conversation.cursor, 4);
    expect(conversation.events.single['seq'], 4);
    expect(conversation.current, isTrue);
  });

  test(
    'read failure retains history but removes permission to control',
    () async {
      await conversation.refresh();
      runtime.handle = (_, _) async =>
          throw PlatformException(code: 'disconnected');
      await conversation.refresh();
      expect(conversation.events, hasLength(1));
      expect(conversation.current, isFalse);
      expect(conversation.canPrompt, isFalse);
      expect(conversation.error, contains('未确认'));
    },
  );
}
