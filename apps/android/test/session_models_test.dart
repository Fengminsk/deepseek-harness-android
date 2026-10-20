import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_models.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Runtime extends RuntimeController {
  Json current = {'provider': 'fixture', 'model': 'one'};
  Completer<Json>? pendingProjection;
  bool failRefresh = false, failApply = false;
  final applied = <Json>[];

  @override
  Future<Json> ensureSession(String id) async => {
    'sessionId': id,
    'created': false,
  };

  Json projection() => {
    'kind': 'sequenced',
    'asOfSeq': 4,
    'values': {
      'modelSelection': {'next': Json.of(current)},
    },
  };

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method != 'api.call' || params['namespace'] != 'session') {
      throw StateError('Unexpected API: $method $params');
    }
    switch (params['method']) {
      case 'modelCatalog':
        return {
          'groups': [
            {
              'id': 'fixture',
              'name': 'Fixture',
              'models': [
                for (final id in ['one', 'two'])
                  {
                    'id': id,
                    'name': 'Model $id',
                    'reasoning': {
                      'efforts': [
                        {'id': 'high', 'name': 'High effort'},
                      ],
                    },
                  },
              ],
            },
          ],
        };
      case 'projections':
        if (failRefresh) throw StateError('refresh unavailable');
        return pendingProjection?.future ?? projection();
      case 'selectModel':
        final request = Json.of(params['args']['request'] as Json);
        applied.add(request);
        if (failApply) throw StateError('selection acknowledgment unavailable');
        current = Json.of(request)..remove('sessionId');
        return {'selected': Json.of(current)};
      default:
        throw StateError('Unexpected session method: ${params['method']}');
    }
  }
}

Future<void> _open(WidgetTester tester, _Runtime runtime) async {
  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: SessionModelPage(runtime: runtime, sessionId: 'session-A'),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

bool _selected(WidgetTester tester, String model) => tester
    .widget<PocketTile>(
      find.ancestor(
        of: find.text('Model $model'),
        matching: find.byType(PocketTile),
      ),
    )
    .selected;

bool _effortSelected(WidgetTester tester, String label) => tester
    .widget<PocketChoice>(
      find.ancestor(of: find.text(label), matching: find.byType(PocketChoice)),
    )
    .selected;

void main() {
  testWidgets('edits during refresh survive the older projection', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    runtime.pendingProjection = Completer<Json>();
    await _tap(tester, find.byTooltip('刷新会话模型'));
    await _tap(tester, find.text('Model two'));
    await _tap(tester, find.text('High effort'));
    expect(_selected(tester, 'two'), isTrue);

    runtime.pendingProjection!.complete(runtime.projection());
    await tester.pumpAndSettle();
    expect(_selected(tester, 'two'), isTrue);
    expect(_effortSelected(tester, 'High effort'), isTrue);
    expect(find.text('当前会话：fixture / one'), findsOneWidget);
    expect(find.text('尚未应用：fixture / two · high'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit refresh preserves an existing unapplied draft', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    await _tap(tester, find.text('Model two'));
    await _tap(tester, find.text('High effort'));
    await _tap(tester, find.byTooltip('刷新会话模型'));

    expect(_selected(tester, 'two'), isTrue);
    expect(_effortSelected(tester, 'High effort'), isTrue);
    await _tap(tester, find.text('应用到当前会话'));
    expect(runtime.applied.single, {
      'sessionId': 'session-A',
      'provider': 'fixture',
      'model': 'two',
      'reasoningEffort': 'high',
    });
    expect(find.textContaining('尚未应用：'), findsNothing);
    expect(find.text('已选择此会话后续请求使用的模型。'), findsOneWidget);
  });

  testWidgets('removing an effort does not mutate the saved baseline', (
    tester,
  ) async {
    final runtime = _Runtime()
      ..current = {
        'provider': 'fixture',
        'model': 'one',
        'reasoningEffort': 'high',
      };
    await _open(tester, runtime);
    await _tap(tester, find.text('服务商默认'));
    await _tap(tester, find.byTooltip('刷新会话模型'));

    expect(_effortSelected(tester, '服务商默认'), isTrue);
    expect(find.text('当前会话：fixture / one · high'), findsOneWidget);
    await _tap(tester, find.text('应用到当前会话'));
    expect(runtime.applied.single, {
      'sessionId': 'session-A',
      'provider': 'fixture',
      'model': 'one',
    });
  });

  testWidgets('refresh and apply failures retain the choice for recovery', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    await _tap(tester, find.text('Model two'));
    runtime.failRefresh = true;
    await _tap(tester, find.byTooltip('刷新会话模型'));
    expect(_selected(tester, 'two'), isTrue);
    expect(find.textContaining('无法读取会话模型，选择已保留'), findsOneWidget);

    runtime.failRefresh = false;
    await _tap(tester, find.byTooltip('刷新会话模型'));
    runtime.failApply = true;
    await _tap(tester, find.text('应用到当前会话'));
    expect(_selected(tester, 'two'), isTrue);
    expect(find.textContaining('切换结果未确认，选择已保留'), findsOneWidget);
    expect(find.text('尚未应用：fixture / two'), findsOneWidget);

    runtime.failApply = false;
    await _tap(tester, find.text('应用到当前会话'));
    expect(runtime.applied.length, 2);
    expect(runtime.applied.first, runtime.applied.last);
    expect(find.textContaining('尚未应用：'), findsNothing);
  });

  testWidgets('refresh adopts remote changes when there is no local draft', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    runtime.current = {'provider': 'fixture', 'model': 'two'};
    await _tap(tester, find.byTooltip('刷新会话模型'));
    expect(_selected(tester, 'two'), isTrue);
    expect(find.textContaining('尚未应用：'), findsNothing);
  });

  testWidgets(
    'refresh verifies an uncertain apply without discarding its draft',
    (tester) async {
      final runtime = _Runtime();
      await _open(tester, runtime);
      await _tap(tester, find.text('Model two'));
      runtime.failApply = true;
      await _tap(tester, find.text('应用到当前会话'));
      // The service accepted the change, but its earlier acknowledgment was lost.
      runtime.current = {'provider': 'fixture', 'model': 'two'};
      await _tap(tester, find.byTooltip('刷新会话模型'));
      expect(_selected(tester, 'two'), isTrue);
      expect(find.textContaining('尚未应用：'), findsNothing);
      expect(find.textContaining('切换结果未确认'), findsNothing);
      expect(runtime.applied.length, 1);
    },
  );

  testWidgets('a refresh settling after the page closes cannot update it', (
    tester,
  ) async {
    final runtime = _Runtime();
    await _open(tester, runtime);
    runtime.pendingProjection = Completer<Json>();
    await _tap(tester, find.byTooltip('刷新会话模型'));
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.pendingProjection!.complete(runtime.projection());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
