import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_models.dart';
import 'package:dsh_android/models_label.dart';
import 'package:dsh_android/session_reasoning_preferences.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const provider = 'deepseek-account';
const flash = 'deepseek-flash';
const pro = 'deepseek-v4-pro';
Json pick(String model, [String effort = 'high']) => {
  'provider': provider,
  'model': model,
  'reasoningEffort': effort,
};

class _Runtime extends RuntimeController {
  _Runtime() {
    phase = 'ready';
  }
  Json? current = pick(flash);
  final preferences = _Preferences();
  int seq = 4, subscriptions = 0;
  final ensured = <String>[];
  final applied = <Json>[];
  final control = StreamController<Json>.broadcast(sync: true);
  Future<Json> Function()? read;
  Future<Json> Function(Json)? select;
  bool? badgePluginEnabled = true;
  Json directory = {
    'default': pick(flash),
    'routableProviders': [provider],
    'groups': [
      {
        'id': provider,
        'name': 'DeepSeek 账号',
        'models': [
          for (final model in [flash, pro])
            {
              'id': model,
              'name': model == flash
                  ? 'DeepSeek-V4.1-Flash'
                  : 'DeepSeek-V4-Pro',
              'reasoning': {
                'defaultEffort': 'high',
                'efforts': [
                  {'id': 'high', 'name': 'High'},
                  {'id': 'max', 'name': 'Max', 'description': '使用更高推理强度'},
                ],
              },
            },
        ],
      },
    ],
    'failures': [],
  };

  @override
  Future<Json> ensureSession(String id) async {
    ensured.add(id);
    return {'sessionId': id, 'created': current == null};
  }

  @override
  Stream<Json> watchApi(
    String namespace,
    String method, {
    Json args = const {},
    Json Function()? resumeArgs,
  }) {
    expectSync(namespace, 'session');
    expectSync(method, 'control');
    expectSync(args, isEmpty);
    subscriptions++;
    return control.stream.transform(
      StreamTransformer.fromHandlers(
        handleData: (frame, sink) => sink.add(frame),
        handleDone: (sink) => sink.close(),
      ),
    );
  }

  Json projection() => {
    'kind': 'sequenced',
    'asOfSeq': seq,
    'values': {
      'modelSelection': {
        'next': current == null ? null : Json.of(current!),
        'lastUsed': null,
      },
    },
  };

  void remote(Json next, {bool publish = true}) {
    current = Json.of(next);
    seq++;
    if (publish) {
      control.add({
        'type': 'item',
        'value': {
          'type': 'projection',
          'sessionId': 'session-A',
          'key': 'modelSelection',
          'value': {'next': Json.of(next), 'lastUsed': null},
          'seq': seq,
        },
      });
    }
  }

  Json accepted(Json request) => {
    'provider': request['provider'],
    'model': request['model'],
    'reasoningEffort': request['reasoningEffort'] ?? 'high',
  };

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'api.call' &&
        params['namespace'] == 'pluginInventory' &&
        params['method'] == 'list') {
      return {
        'managementAvailable': false,
        'entries': [
          if (badgePluginEnabled != null)
            {
              'entryId': 'ui-deepseek-model-label-1017',
              'moduleName': deepSeek1017Plugin,
              'enabled': badgePluginEnabled,
              'fiberPhase': badgePluginEnabled == true ? 'active' : null,
            },
        ],
      };
    }
    if (method != 'api.call' || params['namespace'] != 'session') {
      throw StateError('Unexpected API: $method $params');
    }
    switch (params['method']) {
      case 'modelCatalog':
        return directory;
      case 'projections':
        expectSync(params['args'], {
          'request': {'sessionId': 'session-A'},
        });
        return read == null ? projection() : read!();
      case 'selectModel':
        expectSync(ensured, isNotEmpty);
        final request = Json.of(params['args']['request'] as Json);
        expectSync(
          request.keys.toSet().difference({
            'sessionId',
            'provider',
            'model',
            'reasoningEffort',
          }),
          isEmpty,
        );
        applied.add(request);
        if (select != null) return select!(request);
        remote(accepted(request));
        return {'selected': Json.of(current!)};
      default:
        throw StateError('Unexpected session method: ${params['method']}');
    }
  }

  @override
  void dispose() {
    unawaited(control.close());
    super.dispose();
  }
}

class _Preferences extends SessionReasoningPreferences {
  final records = <String, Json>{};
  Object? saveFailure;
  Future<void> Function()? beforeSave;

  @override
  Future<Json?> load(String sessionId) async => records[sessionId];

  @override
  Future<void> save(String sessionId, Json? effectiveSelection) async {
    await beforeSave?.call();
    if (saveFailure != null) throw saveFailure!;
    if (effectiveSelection == null) {
      records.remove(sessionId);
    } else {
      records[sessionId] = Json.of(effectiveSelection);
    }
  }
}

Future<void> _open(
  WidgetTester tester,
  _Runtime runtime, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: SessionModelPage(
        runtime: runtime,
        sessionId: 'session-A',
        reasoningPreferences: runtime.preferences,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder model(String id) => find.byKey(ValueKey('session-model-$provider-$id'));
Finder get applyButton => find.byKey(const ValueKey('apply-session-model'));
Future<void> tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

bool selected(WidgetTester tester, String id) =>
    (tester.widget<PocketTile>(model(id)).trailing as Icon).icon ==
    Icons.check_circle_rounded;
bool enabled(WidgetTester tester) =>
    tester.widget<PocketButton>(applyButton).onPressed != null;
Future<void> refresh(WidgetTester tester) =>
    tap(tester, find.byTooltip('刷新会话模型'));

void main() {
  testWidgets('default detent survives confirmed normalization and reopening', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    await tap(tester, find.text('默认'));
    await tap(tester, applyButton);
    expect(runtime.current, pick(flash));
    expect(runtime.preferences.records['session-A'], pick(flash));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: SessionModelPage(
          runtime: runtime,
          sessionId: 'session-A',
          reasoningPreferences: runtime.preferences,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final control = find.byKey(const ValueKey('session-reasoning-effort'));
    expect(tester.widget<SegmentedControl<String?>>(control).value, isNull);
    expect(enabled(tester), isFalse);
    await tap(tester, find.text('高'));
    await tap(tester, applyButton);
    expect(runtime.preferences.records, isEmpty);
    expect(tester.widget<SegmentedControl<String?>>(control).value, 'high');
  });

  testWidgets(
    'remote changes invalidate remembered default without hiding them',
    (tester) async {
      final runtime = _Runtime();
      runtime.preferences.records['session-A'] = pick(flash);
      await _open(tester, runtime);
      final control = find.byKey(const ValueKey('session-reasoning-effort'));
      expect(tester.widget<SegmentedControl<String?>>(control).value, isNull);
      runtime.remote(pick(pro, 'max'));
      await tester.pumpAndSettle();
      expect(runtime.preferences.records, isEmpty);
      expect(tester.widget<SegmentedControl<String?>>(control).value, 'max');
      expect(enabled(tester), isFalse);
    },
  );

  testWidgets('a changed model default exposes the actual selected effort', (
    tester,
  ) async {
    final runtime = _Runtime();
    runtime.preferences.records['session-A'] = pick(flash);
    runtime.directory['groups'][0]['models'][0]['reasoning']['defaultEffort'] =
        'max';
    await _open(tester, runtime);
    expect(runtime.preferences.records, isEmpty);
    final control = find.byKey(const ValueKey('session-reasoning-effort'));
    expect(tester.widget<SegmentedControl<String?>>(control).value, 'high');
  });

  testWidgets(
    'preference write failure reports separately from applied model',
    (tester) async {
      final runtime = _Runtime();
      runtime.preferences.saveFailure = StateError('disk full');
      await _open(tester, runtime);
      await tap(tester, find.text('默认'));
      await tap(tester, applyButton);
      expect(runtime.current, pick(flash));
      expect(runtime.preferences.records, isEmpty);
      expect(find.textContaining('默认档位未保存'), findsOneWidget);
      expect(find.textContaining('切换结果未确认'), findsNothing);
      expect(enabled(tester), isFalse);
    },
  );

  testWidgets(
    'Chinese sliding detents match the compact expected presentation',
    (tester) async {
      final expected = jsonDecode(
        File('test/fixtures/model_reasoning.expected.json').readAsStringSync(),
      ) as Json;
      final runtime = _Runtime();
      runtime.directory['groups'][0]['models'][0]['reasoning']['efforts'] = [
        for (final id in ['off', 'low', 'high', 'max']) {'id': id, 'name': id},
      ];
      await _open(tester, runtime);
      final control = find.byKey(const ValueKey('session-reasoning-effort'));
      await Scrollable.ensureVisible(tester.element(control), alignment: .5);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedControl<String?>>(control)
            .segments
            .map((s) => s.$2)
            .toList(),
        expected['detents'],
      );
      expect(tester.getSize(control).height, lessThanOrEqualTo(52));
      expect(
        find.text(expected['explicitHighDescription'] as String),
        findsOneWidget,
      );
      await tap(tester, find.text('默认'));
      expect(
        find.text(expected['defaultDescription'] as String),
        findsOneWidget,
      );
      expect(find.text('High'), findsNothing);
      expect(find.text('Max'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('official Flash badge appears on current and selectable model', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    expect(
      find.descendant(of: model(flash), matching: find.text('1017')),
      findsOneWidget,
    );
    expect(find.byType(ModelReleaseLabel), findsNWidgets(3));
    expect(find.text('1017'), findsNWidgets(2));
    expect(runtime.current, pick(flash));
    expect(runtime.applied, isEmpty);
  });

  testWidgets('a disabled or missing plugin removes only the visual badge', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    expect(find.text('1017'), findsNWidgets(2));
    runtime.badgePluginEnabled = false;
    await runtime.plugins.load(invalidate: true);
    await tester.pump();
    expect(find.text('1017'), findsNothing);
    expect(find.textContaining('DeepSeek-V4.1-Flash'), findsWidgets);
    expect(runtime.current, pick(flash));
    runtime.badgePluginEnabled = null;
    await runtime.plugins.load(invalidate: true);
    await tester.pump();
    expect(find.text('1017'), findsNothing);
    expect(runtime.current, pick(flash));
  });

  testWidgets(
    'refresh preserves a live observer while transport recovery is pending',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      await tap(tester, model(pro));
      runtime.control.add({'type': 'disconnected'});
      runtime.control.addError(StateError('temporary cleanup failure'));
      await tester.pumpAndSettle();
      await refresh(tester);
      expect(runtime.subscriptions, 1);
      expect(selected(tester, pro), isTrue);
      expect(runtime.applied, isEmpty);
    },
  );

  testWidgets(
    'session model page waits for the service and automatically recovers',
    (tester) async {
      final runtime = _Runtime()..phase = 'starting';
      await _open(tester, runtime);
      expect(runtime.ensured, isEmpty);
      expect(find.textContaining('本地服务尚未就绪'), findsOneWidget);
      runtime.phase = 'ready';
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(runtime.ensured, ['session-A']);
      expect(selected(tester, flash), isTrue);
      expect(find.textContaining('本地服务尚未就绪'), findsNothing);
    },
  );

  testWidgets(
    'a connection change during preflight preserves draft and cannot submit it',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      await tap(tester, model(pro));
      final pending = Completer<Json>();
      final oldProjection = runtime.projection();
      runtime.read = () => pending.future;
      await tester.ensureVisible(applyButton);
      await tester.tap(applyButton);
      await tester.pump();
      runtime.fail(StateError('service disconnected'));
      runtime.read = null;
      pending.complete(oldProjection);
      await tester.pumpAndSettle();
      expect(runtime.applied, isEmpty);
      expect(enabled(tester), isFalse);
      expect(selected(tester, pro), isTrue);
      runtime.phase = 'ready';
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(selected(tester, pro), isTrue);
      expect(enabled(tester), isTrue);
      expect(runtime.applied, isEmpty);
    },
  );

  testWidgets(
    'blank Session inherits real catalog default and can choose another account model',
    (tester) async {
      final runtime = _Runtime()..current = null;
      await _open(tester, runtime);
      expect(runtime.ensured, ['session-A']);
      expect(selected(tester, flash), isTrue);
      expect(find.textContaining('继承默认模型'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));
      expect(enabled(tester), isFalse);
      expect(find.text('已是当前模型'), findsOneWidget);
      await tap(tester, model(pro));
      expect(selected(tester, pro), isTrue);
      expect(selected(tester, flash), isFalse);
      expect(enabled(tester), isTrue);
      expect(find.textContaining('待应用 · DeepSeek-V4-Pro'), findsOneWidget);
      await tap(tester, applyButton);
      expect(runtime.applied.single, {
        'sessionId': 'session-A',
        'provider': provider,
        'model': pro,
      });
      expect(find.textContaining('已应用。'), findsOneWidget);
      expect(enabled(tester), isFalse);
      expect(runtime.current, pick(pro));
    },
  );

  testWidgets(
    'retapping the selected row preserves reasoning and default choice is explicit',
    (tester) async {
      final runtime = _Runtime()..current = pick(pro, 'max');
      await _open(tester, runtime);
      await tap(tester, model(pro));
      await tap(tester, find.text('最高'));
      expect(enabled(tester), isFalse);
      await tap(tester, find.text('默认'));
      expect(enabled(tester), isTrue);
      await tap(tester, applyButton);
      expect(runtime.applied.single.containsKey('reasoningEffort'), isFalse);
      expect(runtime.current, pick(pro));
    },
  );

  testWidgets('reasoning slider commits the catalog effort on release', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    final control = find.byKey(const ValueKey('session-reasoning-effort'));
    await Scrollable.ensureVisible(tester.element(control), alignment: .5);
    await tester.pumpAndSettle();
    expect(enabled(tester), isFalse);
    final bounds = tester.getRect(control);
    final gesture = await tester.startGesture(
      Offset(bounds.left + bounds.width / 2, bounds.center.dy),
    );
    await gesture.moveTo(
      Offset(bounds.left + bounds.width * 5 / 6, bounds.center.dy),
    );
    await tester.pump();
    expect(enabled(tester), isFalse);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(enabled(tester), isTrue);
    await tap(tester, applyButton);
    expect(runtime.applied.single['reasoningEffort'], 'max');
  });

  testWidgets(
    'unavailable current route is retained and never replaced with catalog default',
    (tester) async {
      final runtime = _Runtime()
        ..current = {'provider': 'removed', 'model': 'old-model'};
      await _open(tester, runtime);
      expect(selected(tester, flash), isFalse);
      expect(selected(tester, pro), isFalse);
      expect(find.textContaining('暂不在可用目录'), findsOneWidget);
      expect(find.text('请选择可用模型'), findsOneWidget);
      expect(runtime.applied, isEmpty);
      await tap(tester, model(pro));
      expect(enabled(tester), isTrue);
    },
  );

  testWidgets(
    'edits during refresh survive and a stale snapshot cannot replace a newer stream',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      final stale = runtime.projection();
      final pending = Completer<Json>();
      runtime.read = () => pending.future;
      await refresh(tester);
      await tap(tester, model(pro));
      await tap(tester, find.text('最高'));
      runtime.remote(pick(flash, 'max'));
      pending.complete(stale);
      await tester.pumpAndSettle();
      expect(selected(tester, pro), isTrue);
      expect(find.textContaining('待应用 · DeepSeek-V4-Pro · 最高'), findsOneWidget);
      expect(find.text('会话模型已变化'), findsOneWidget);
      expect(enabled(tester), isFalse);
      runtime.read = null;
      await tap(tester, find.text('保留我的选择，按最新状态继续'));
      await tap(tester, applyButton);
      expect(runtime.applied.single['reasoningEffort'], 'max');
      expect(runtime.current, pick(pro, 'max'));
    },
  );

  testWidgets(
    'remote selection follows without local edits and preserves a changed local draft',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      runtime.remote(pick(pro));
      await tester.pumpAndSettle();
      expect(selected(tester, pro), isTrue);
      await tap(tester, find.text('最高'));
      runtime.remote(pick(flash));
      await tester.pumpAndSettle();
      expect(selected(tester, pro), isTrue);
      expect(enabled(tester), isFalse);
      expect(find.text('会话模型已变化'), findsOneWidget);
      await tap(tester, find.text('采用当前会话模型'));
      expect(selected(tester, flash), isTrue);
      expect(find.text('会话模型已变化'), findsNothing);
      expect(runtime.applied, isEmpty);
    },
  );

  testWidgets(
    'preflight catches an unobserved concurrent edit and does not write over it',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      await tap(tester, model(pro));
      runtime.remote(pick(flash, 'max'), publish: false);
      await tap(tester, applyButton);
      expect(runtime.applied, isEmpty);
      expect(selected(tester, pro), isTrue);
      expect(find.text('会话模型已变化'), findsOneWidget);
      expect(enabled(tester), isFalse);
    },
  );

  testWidgets(
    'later remote selection wins over a successful older acknowledgement',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      await tap(tester, model(pro));
      runtime.select = (request) async {
        final accepted = runtime.accepted(request);
        runtime.remote(accepted);
        runtime.remote(pick(flash, 'max'));
        return {'selected': accepted};
      };
      await tap(tester, applyButton);
      expect(runtime.applied, hasLength(1));
      expect(runtime.current, pick(flash, 'max'));
      expect(selected(tester, pro), isTrue);
      expect(find.textContaining('会话随后又发生变化'), findsOneWidget);
      expect(find.textContaining('已应用。'), findsNothing);
    },
  );

  testWidgets(
    'lost acknowledgement keeps draft and refresh confirms normalized selection without resubmission',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      await tap(tester, model(pro));
      runtime.select = (request) async {
        runtime.remote(runtime.accepted(request), publish: false);
        throw StateError('connection lost after acceptance');
      };
      await tap(tester, applyButton);
      expect(selected(tester, pro), isTrue);
      expect(find.textContaining('切换结果未确认'), findsOneWidget);
      expect(enabled(tester), isFalse);
      expect(find.text('请先刷新确认结果'), findsOneWidget);
      expect(runtime.preferences.records, isEmpty);
      await refresh(tester);
      expect(selected(tester, pro), isTrue);
      expect(find.text('已是当前模型'), findsOneWidget);
      expect(find.text('会话模型已变化'), findsNothing);
      expect(runtime.applied, hasLength(1));
      expect(runtime.preferences.records['session-A'], pick(pro));
    },
  );

  testWidgets(
    'acknowledged apply with failed readback remains distinct from an unsubmitted failure',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      await tap(tester, model(pro));
      runtime.select = (request) async {
        runtime.remote(runtime.accepted(request), publish: false);
        runtime.read = () => throw StateError('readback disconnected');
        return {'selected': Json.of(runtime.current!)};
      };
      await tap(tester, applyButton);
      expect(find.textContaining('服务已接受选择，但最新会话状态尚未核对'), findsOneWidget);
      expect(selected(tester, pro), isTrue);
      runtime.read = null;
      await refresh(tester);
      expect(find.text('已是当前模型'), findsOneWidget);
      expect(runtime.applied, hasLength(1));
    },
  );

  testWidgets(
    'failed preflight preserves inputs and states that nothing was submitted',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      await tap(tester, model(pro));
      runtime.read = () => throw StateError('unavailable');
      await tap(tester, applyButton);
      expect(find.textContaining('本次尚未提交'), findsOneWidget);
      expect(runtime.applied, isEmpty);
      expect(runtime.preferences.records, isEmpty);
      expect(selected(tester, pro), isTrue);
    },
  );

  testWidgets('provider failures are visible alongside usable models', (
    tester,
  ) async {
    final runtime = _Runtime();
    runtime.directory['failures'] = [
      {'id': 'offline', 'name': '离线服务商', 'message': 'catalog unavailable'},
    ];
    await _open(tester, runtime);
    expect(find.textContaining('离线服务商 暂不可用'), findsOneWidget);
    await tap(tester, model(pro));
    expect(enabled(tester), isTrue);
  });

  testWidgets('refresh settling after disposal cannot change the page', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    final pending = Completer<Json>();
    runtime.read = () => pending.future;
    await refresh(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(runtime.projection());
    await tester.pumpAndSettle();
    expect(runtime.control.hasListener, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text retains reachable choice and apply controls', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime, scale: 1.5);
    await tap(tester, model(pro));
    await tap(tester, find.text('最高'));
    expect(enabled(tester), isTrue);
    await tap(tester, applyButton);
    expect(runtime.current, pick(pro, 'max'));
    expect(tester.takeException(), isNull);
  });
}
