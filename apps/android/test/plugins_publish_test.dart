import 'dart:async';

import 'package:dsh_android/main.dart';
import 'package:dsh_android/models_label.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/read_only_presets.dart';

/// Session model state owned by the fixture host: `selectModel` appends the
/// same `model/selection` event the real core writes, so the chat header
/// projection and the model page agree on the applied route.
class _PublishRuntime extends RuntimeController {
  _PublishRuntime() {
    phase = 'ready';
    provider = 'deepseek-official';
    model = 'deepseek-flash';
  }

  final presets = ReadOnlyPresets();
  final pluginReads = <Json>[];
  Json? appliedSelection;

  static const catalog = <String, dynamic>{
    'default': {
      'provider': 'deepseek-official',
      'model': 'deepseek-flash',
      'reasoningEffort': 'low',
    },
    'groups': [
      {
        'id': 'deepseek-official',
        'name': 'DeepSeek',
        'models': [
          {
            'id': 'deepseek-flash',
            'name': 'DeepSeek-V4.1-Flash',
            'reasoning': {
              'defaultEffort': 'low',
              'efforts': [
                {'id': 'low', 'name': '低'},
                {'id': 'high', 'name': '高'},
              ],
            },
          },
          {'id': 'deepseek-v4-pro', 'name': 'DeepSeek-V4-Pro'},
        ],
      },
    ],
    'failures': <Json>[],
    'routableProviders': ['deepseek-official'],
  };

  Json get _projection => {
    'kind': 'sequenced',
    'asOfSeq': timelines.values.single.length,
    'values': {
      'modelSelection': {'next': appliedSelection, 'lastUsed': null},
    },
  };

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    if (!presets.observes(namespace, method)) {
      throw StateError('Unexpected observation: $namespace.$method');
    }
    return presets.watch(args: args, resumeArgs: resumeArgs);
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'session.ensure') return {'sessionId': params['sessionId']};
    if (method == 'api.call' && params['namespace'] == 'session') {
      final args = params['args'] as Json? ?? const {};
      switch (params['method']) {
        case 'modelCatalog':
          return catalog;
        case 'projections':
          return _projection;
        case 'selectModel':
          final request = args['request'] as Json;
          final selected = <String, dynamic>{
            'provider': request['provider'],
            'model': request['model'],
            if (request['reasoningEffort'] != null)
              'reasoningEffort': request['reasoningEffort'],
          };
          appliedSelection = selected;
          final timeline = timelines[request['sessionId'] as String]!;
          timeline.add({
            'seq': timeline.length,
            'time': 0,
            'type': 'model/selection',
            'surfaceOp': 'append',
            'data': selected,
          });
          notifyListeners();
          return {'selected': selected};
      }
    }
    if (presets.handles(method, params)) return presets.reply(params);
    if (method == 'api.call' &&
        params['namespace'] == 'pluginInventory' &&
        params['method'] == 'list') {
      pluginReads.add(params);
      return {
        'managementAvailable': false,
        'entries': [
          {
            'entryId': 'ui-deepseek-model-label-1017',
            'moduleName': deepSeek1017Plugin,
            'enabled': true,
            'fiberPhase': 'active',
          },
        ],
      };
    }
    throw StateError('Unexpected request: $method');
  }

  @override
  void dispose() {
    presets.dispose();
    super.dispose();
  }
}

Widget _host(_PublishRuntime runtime) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  builder: (_, child) => MediaQuery(
    data: const MediaQueryData(size: Size(390, 844), disableAnimations: true),
    child: child!,
  ),
  home: ChatPage(runtime: runtime),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The host channel owns these preference reads; the fixture keeps them local.
void _mockReasoningPreferences(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(RuntimeController.channel, (call) async {
    switch (call.method) {
      case 'session.reasoning.load':
      case 'session.reasoning.save':
        return null;
    }
    throw MissingPluginException('${call.method} is not part of this fixture');
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(RuntimeController.channel, null),
  );
}

void main() {
  test(
    'loading the plugin inventory never notifies the caller synchronously',
    () async {
      final runtime = _PublishRuntime();
      addTearDown(runtime.dispose);
      final controller = runtime.plugins;
      var notifications = 0;
      controller.addListener(() => notifications++);

      final flight = controller.load();
      // Pages start this read from initState, while the tree is building. A
      // synchronous listener call would be a setState-during-build there.
      expect(notifications, 0);

      await flight;
      expect(notifications, greaterThan(0));
      expect(controller.fresh, isTrue);
      expect(controller.loading, isFalse);
      expect(runtime.pluginReads, hasLength(1));
    },
  );

  test('a not-ready load defers its state notification as well', () async {
    final runtime = _PublishRuntime()..phase = 'starting';
    addTearDown(runtime.dispose);
    final controller = runtime.plugins;
    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.load();
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    expect(controller.fresh, isFalse);
    expect(runtime.pluginReads, isEmpty);
  });

  testWidgets(
    'opening the Session model page from the chat title does not notify during build',
    (tester) async {
      _mockReasoningPreferences(tester);
      _phone(tester);
      final runtime = _PublishRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Pocket Harness'), findsOneWidget);
      expect(find.text('1017'), findsOneWidget);
      final readsBefore = runtime.pluginReads.length;

      await tester.tap(find.text('Pocket Harness'));
      await tester.pumpAndSettle();

      // Regression: the page's first plugin publish used to run synchronously
      // from initState and mark the chat header label dirty during this build.
      expect(tester.takeException(), isNull);
      expect(find.text('会话模型'), findsOneWidget);
      expect(runtime.pluginReads.length, greaterThan(readsBefore));
      expect(
        find.byKey(
          const ValueKey('session-model-deepseek-official-deepseek-v4-pro'),
        ),
        findsOneWidget,
      );
      // DeepSeek-V4.1-Flash model rows keep the release badge from the inventory.
      expect(find.textContaining('DeepSeek-V4.1-Flash'), findsWidgets);
      expect(find.text('1017'), findsWidgets);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Pocket Harness'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'applying a model from the Session model page updates the chat header label',
    (tester) async {
      _mockReasoningPreferences(tester);
      _phone(tester);
      final runtime = _PublishRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(_host(runtime));
      await tester.pumpAndSettle();
      expect(find.textContaining('DeepSeek-V4.1-Flash'), findsOneWidget);

      await tester.tap(find.text('Pocket Harness'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(
          const ValueKey('session-model-deepseek-official-deepseek-v4-pro'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('apply-session-model')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已应用'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Pocket Harness'), findsOneWidget);
      expect(find.textContaining('DeepSeek-V4-Pro'), findsOneWidget);
      expect(find.textContaining('DeepSeek-V4.1-Flash'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
