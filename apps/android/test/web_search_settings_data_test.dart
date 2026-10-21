import 'dart:async';

import 'package:dsh_android/web_search_settings_data.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/web_search_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WebSearchTestRuntime runtime;
  late WebSearchSettingsController controller;
  setUp(() {
    runtime = WebSearchTestRuntime();
    controller = WebSearchSettingsController(runtime);
  });
  tearDown(() {
    controller.dispose();
    runtime.dispose();
  });

  test(
    'reading never writes and identifies only complete known provider pairs',
    () async {
      await controller.start();
      expect(controller.mode, WebSearchMode.messages);
      expect(controller.hasDraft, false);
      expect(controller.canSave, false);
      runtime.change(
        webRoutingNamespace,
        'fetchProvider',
        'third-party',
        notify: false,
      );
      await controller.refresh();
      expect(controller.mode, WebSearchMode.custom);
      expect(runtime.writes, isEmpty);
    },
  );

  test(
    'explicit mode stages both providers and permits account use without a key',
    () async {
      await controller.start();
      controller.chooseMode(WebSearchMode.api);
      expect(controller.mode, WebSearchMode.api);
      expect(runtime.writes, isEmpty);
      expect(controller.canSave, true);
      await controller.save();
      expect(runtime.writes.map((call) => call.method), ['settings.mutate']);
      expect(runtime.values[webRoutingNamespace], {
        'searchProvider': 'deepseek-search-api',
        'fetchProvider': 'deepseek-fetch-api',
      });
      expect(controller.hasDraft, false);
    },
  );

  test('parameters then credential then routing save in order with exact refs and types', () async {
    await controller.start();
    controller.edit(webSearchNamespace, 'maxUses', 6);
    controller.edit(webApiNamespace, 'count', 20);
    controller.chooseMode(WebSearchMode.api);
    controller.editKey('SEARCH_KEY', 'test-key');
    await controller.save();
    expect(
      runtime.writes.map(
        (call) =>
            call.method == 'settings.mutate' ? call.args['ns'] : call.method,
      ),
      [
        webSearchNamespace,
        webApiNamespace,
        'credentials.set',
        webRoutingNamespace,
      ],
    );
    expect(runtime.writes[2].args, {'ref': 'SEARCH_KEY', 'value': 'test-key'});
    expect(runtime.values[webApiNamespace]!['count'], isA<int>());
    expect(controller.keyDraft('SEARCH_KEY'), isEmpty);
    expect(controller.hasDraft, false);
  });

  test('custom pair and extension values survive editing parameters', () async {
    runtime.values[webRoutingNamespace] = {
      'searchProvider': 'external',
      'fetchProvider': 'custom',
      'extension': true,
    };
    runtime.values[webSearchNamespace]!['futureOption'] = {'enabled': true};
    await controller.start();
    controller.edit(webSearchNamespace, 'maxUses', 7);
    await controller.save();
    expect(runtime.values[webRoutingNamespace], {
      'searchProvider': 'external',
      'fetchProvider': 'custom',
      'extension': true,
    });
    expect(runtime.values[webSearchNamespace]!['futureOption'], {
      'enabled': true,
    });
    expect(runtime.writes.single.args['ns'], webSearchNamespace);
  });

  test(
    'selection back to deployment defaults clears routing overrides',
    () async {
      runtime.values[webRoutingNamespace] = {
        'searchProvider': 'deepseek-search-api',
        'fetchProvider': 'deepseek-fetch-api',
      };
      runtime.users[webRoutingNamespace] = {
        ...runtime.values[webRoutingNamespace]!,
      };
      await controller.start();
      controller.chooseMode(WebSearchMode.messages);
      await controller.save();
      expect(
        (runtime.writes.single.args['ops'] as List).map((op) => op['op']),
        ['unset', 'unset'],
      );
      expect(runtime.users[webRoutingNamespace], isEmpty);
      expect(controller.mode, WebSearchMode.messages);
    },
  );

  test(
    'mode selection round trip creates no spurious inherited write',
    () async {
      await controller.start();
      controller.chooseMode(WebSearchMode.api);
      controller.chooseMode(WebSearchMode.messages);
      expect(controller.hasDraft, false);
      expect(controller.canSave, false);
    },
  );

  test('all section versions are checked before the first write', () async {
    await controller.start();
    controller.edit(webSearchNamespace, 'maxUses', 8);
    controller.chooseMode(WebSearchMode.api);
    runtime.change(webApiNamespace, 'count', 30, notify: false);
    await controller.save();
    expect(runtime.writes, isEmpty);
    expect(controller.section(webApiNamespace).conflict, true);
    expect(controller.section(webSearchNamespace).draft!['maxUses'], 8);
  });

  test('a refused parameter section stops key and routing and keeps remaining drafts', () async {
    await controller.start();
    controller.edit(webSearchNamespace, 'maxUses', 8);
    controller.edit(webApiNamespace, 'count', 22);
    controller.chooseMode(WebSearchMode.api);
    controller.editKey('SEARCH_KEY', 'test-key');
    runtime.rejectSection = webApiNamespace;
    await controller.save();
    expect(runtime.writes.map((call) => call.args['ns']), [
      webSearchNamespace,
      webApiNamespace,
    ]);
    expect(controller.completed, [webSearchSectionLabel(webSearchNamespace)]);
    expect(controller.keyDraft('SEARCH_KEY'), 'test-key');
    runtime.rejectSection = null;
    expect(controller.keepDraft(webApiNamespace), true);
    await controller.save();
    expect(
      runtime.writes
          .where((call) => call.args['ns'] == webSearchNamespace)
          .length,
      1,
    );
    expect(
      runtime.values[webRoutingNamespace]!['searchProvider'],
      'deepseek-search-api',
    );
  });

  test(
    'an unconfirmed write is not automatically repeated or followed by routing',
    () async {
      await controller.start();
      controller.edit(webSearchNamespace, 'maxUses', 9);
      controller.chooseMode(WebSearchMode.api);
      runtime.loseSection = webSearchNamespace;
      await controller.save();
      await controller.refresh();
      await controller.save();
      expect(runtime.writes.length, 1);
      expect(controller.section(webSearchNamespace).uncertain, true);
      expect(controller.canSave, false);
    },
  );

  test(
    'matching observation after lost reply confirms parameters without replay',
    () async {
      await controller.start();
      controller.edit(webSearchNamespace, 'maxUses', 9);
      controller.chooseMode(WebSearchMode.api);
      runtime.loseSection = webSearchNamespace;
      runtime.applyBeforeLoss = true;
      await controller.save();
      expect(controller.section(webSearchNamespace).uncertain, false);
      expect(runtime.writes.length, 1);
      runtime.loseSection = null;
      await controller.save();
      expect(runtime.writes.map((call) => call.args['ns']), [
        webSearchNamespace,
        webRoutingNamespace,
      ]);
    },
  );

  test(
    'configured credential status cannot confirm a lost key write',
    () async {
      runtime.configured.add('SEARCH_KEY');
      await controller.start();
      controller.chooseMode(WebSearchMode.api);
      controller.editKey('SEARCH_KEY', 'replacement');
      runtime.failKey = true;
      await controller.save();
      await controller.refresh();
      await controller.save();
      expect(runtime.writes.map((call) => call.method), ['credentials.set']);
      expect(controller.canSave, false);
      expect(controller.keyDraft('SEARCH_KEY'), 'replacement');
      expect(
        controller.credentials.entry('SEARCH_KEY').status!.configured,
        true,
      );
    },
  );

  test(
    'different credential refs keep separate drafts when modes change',
    () async {
      await controller.start();
      controller.editKey(
        controller.reference(webSearchNamespace)!,
        'messages-test',
      );
      controller.chooseMode(WebSearchMode.api);
      controller.editKey(controller.reference(webApiNamespace)!, 'api-test');
      await controller.save();
      expect(
        runtime.writes
            .where((call) => call.method == 'credentials.set')
            .map((call) => call.args),
        [
          {'ref': 'MESSAGES_KEY', 'value': 'messages-test'},
          {'ref': 'SEARCH_KEY', 'value': 'api-test'},
        ],
      );
    },
  );

  for (final remove in [false, true]) {
    test(
      'credential manager ${remove ? 'removal' : 'replacement'} cannot be overwritten by an old unconfirmed input',
      () async {
        await controller.start();
        controller.chooseMode(WebSearchMode.api);
        controller.editKey('SEARCH_KEY', 'old-input');
        runtime.failKey = true;
        await controller.save();
        runtime.failKey = false;
        await controller.refresh();
        if (remove) {
          await controller.credentials.remove('SEARCH_KEY', confirmed: true);
        } else {
          controller.credentials.edit('SEARCH_KEY', 'manager-replacement');
          await controller.credentials.save(
            'SEARCH_KEY',
            acknowledgeUnknown: true,
          );
        }
        await controller.refresh();
        expect(controller.keyNeedsReview('SEARCH_KEY'), true);
        expect(controller.keyDraft('SEARCH_KEY'), 'old-input');
        expect(controller.canSave, false);
        await controller.save();
        expect(runtime.writes.length, 2);
        controller.discardKey('SEARCH_KEY');
        expect(controller.canSave, true);
        await controller.save();
        expect(runtime.writes.length, 3);
        expect(runtime.writes.last.args['ns'], webRoutingNamespace);
        expect(
          runtime.writes
              .where((call) => call.args['value'] == 'old-input')
              .length,
          1,
        );
      },
    );
  }

  test('another credential write after staging requires review even before first combined save', () async {
    await controller.start();
    controller.editKey('MESSAGES_KEY', 'staged-input');
    controller.credentials.edit('MESSAGES_KEY', 'other-input');
    await controller.credentials.save('MESSAGES_KEY');
    await controller.refresh();
    expect(controller.keyNeedsReview('MESSAGES_KEY'), true);
    expect(controller.canSave, false);
    await controller.save();
    expect(runtime.writes.single.args['value'], 'other-input');
  });

  test('credential reply from an older connection retains input and never switches routes', () async {
    await controller.start();
    controller.chooseMode(WebSearchMode.api);
    controller.editKey('SEARCH_KEY', 'waiting-input');
    final pause = Completer<void>();
    runtime.pauseKeyWrite = pause;
    final saving = controller.save();
    while (runtime.writes.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    runtime.reconnect();
    pause.complete();
    await saving;
    await controller.refresh();
    expect(controller.keyDraft('SEARCH_KEY'), 'waiting-input');
    expect(controller.canSave, false);
    await controller.save();
    expect(runtime.writes.single.method, 'credentials.set');
  });

  test(
    'advanced configuration waits for all workflow drafts and uncertain writes',
    () async {
      await controller.start();
      expect(controller.canOpenAdvanced, true);
      controller.chooseMode(WebSearchMode.api);
      expect(controller.canOpenAdvanced, false);
      controller.chooseMode(WebSearchMode.messages);
      expect(controller.canOpenAdvanced, true);
      controller.editKey('MESSAGES_KEY', 'new-key');
      expect(controller.canOpenAdvanced, false);
      runtime.failKey = true;
      await controller.save();
      expect(controller.canOpenAdvanced, false);
    },
  );

  test(
    'readonly credentials do not block settings when no new key was entered',
    () async {
      runtime.credentialWritable = false;
      await controller.start();
      controller.edit(webSearchNamespace, 'maxUses', 12);
      expect(controller.canSave, true);
      await controller.save();
      expect(runtime.writes.single.args['ns'], webSearchNamespace);
      controller.editKey('MESSAGES_KEY', 'new');
      expect(controller.canSave, false);
    },
  );

  test(
    'another credential editor draft is not overwritten by combined save',
    () async {
      await controller.start();
      controller.credentials.edit('MESSAGES_KEY', 'other-editor');
      controller.editKey('MESSAGES_KEY', 'this-editor');
      expect(controller.canSave, false);
      await controller.save();
      expect(runtime.writes, isEmpty);
      expect(
        controller.credentials.entry('MESSAGES_KEY').draft,
        'other-editor',
      );
    },
  );

  test('legacy deployment can edit Messages without inventing missing API sections', () async {
    runtime.absent.add(webApiNamespace);
    await controller.start();
    expect(controller.canChooseMode, false);
    controller.chooseMode(WebSearchMode.api);
    controller.edit(webSearchNamespace, 'maxUses', 10);
    await controller.save();
    expect(runtime.writes.single.args['ns'], webSearchNamespace);
  });

  test('invalid typed values are never staged as guessed settings', () async {
    await controller.start();
    controller.edit(webApiNamespace, 'count', 51);
    controller.edit(webApiNamespace, 'count', '20');
    controller.edit(webApiNamespace, 'sendOriginalQuestion', 'false');
    controller.edit(webSearchNamespace, 'apiKeyEnv', 'invalid-ref');
    expect(controller.hasDraft, false);
  });

  test(
    'detached field editor retains version even before it returns valid text',
    () async {
      await controller.start();
      controller.holdEditor(true);
      runtime.change(webSearchNamespace, 'maxUses', 16, notify: false);
      await controller.refresh();
      controller.edit(webSearchNamespace, 'maxUses', 18);
      controller.holdEditor(false);
      expect(controller.section(webSearchNamespace).conflict, true);
      expect(controller.canSave, false);
      expect(controller.section(webSearchNamespace).draft!['maxUses'], 18);
    },
  );

  test(
    'a connection change during a write prevents later operations',
    () async {
      await controller.start();
      controller.edit(webSearchNamespace, 'maxUses', 9);
      controller.chooseMode(WebSearchMode.api);
      final pause = Completer<void>();
      runtime.pauseWrite = pause;
      final saving = controller.save();
      while (runtime.writes.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      runtime.reconnect();
      pause.complete();
      await saving;
      expect(runtime.writes.length, 1);
    },
  );

  test(
    'own settings notifications do not cause false cross-section conflicts',
    () async {
      runtime.notifyOnWrite = true;
      await controller.start();
      controller.edit(webSearchNamespace, 'maxUses', 8);
      controller.edit(webApiNamespace, 'count', 15);
      controller.chooseMode(WebSearchMode.api);
      await controller.save();
      expect(runtime.writes.map((call) => call.args['ns']), [
        webSearchNamespace,
        webApiNamespace,
        webRoutingNamespace,
      ]);
      expect(controller.hasDraft, false);
    },
  );
}
