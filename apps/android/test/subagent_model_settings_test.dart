import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/subagent_model_settings.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json route(String provider, String model) => {
  'provider': provider,
  'model': model,
};
Json copy(Json source) => jsonDecode(jsonEncode(source)) as Json;

/// Exact original APIs: reading this page must never ensure or start a session.
class SubagentSettingsRuntime extends RuntimeController {
  SubagentSettingsRuntime() {
    phase = 'ready';
  }

  int revision = 4, generation = 1, catalogReads = 0;
  bool writable = true, describeFails = false, catalogFails = false;
  bool conflictOnce = false, loseReply = false, applyBeforeLoss = false;
  Json value = {'enabled': false, 'allowedModels': <Json>[]};
  Json catalog = {
    'groups': [
      {
        'id': 'deepseek',
        'name': 'DeepSeek',
        'models': [
          {'id': 'flash', 'name': 'DeepSeek Flash'},
          {'id': 'pro', 'name': 'DeepSeek Pro'},
        ],
      },
      {
        'id': 'local',
        'name': '自定义服务商',
        'models': [
          {'id': 'flash', 'name': '本地 Flash'},
        ],
      },
    ],
    'failures': <Json>[],
  };
  final calls = <({String method, Json params})>[];
  Completer<dynamic>? nextCatalog;

  Json get descriptor => {
    'ns': subagentModelSettingsNamespace,
    'revision': revision,
    'value': copy(value),
    'user': copy(value),
    'schema': {
      'type': 'object',
      'dict': {
        'enabled': {'type': 'boolean'},
        'allowedModels': {
          'type': 'array',
          'inner': {
            'type': 'object',
            'dict': {
              'provider': {'type': 'string'},
              'model': {'type': 'string'},
            },
          },
        },
      },
    },
    'secrets': <Json>[],
  };

  @override
  int get connectionGeneration => generation;

  void reconnect() {
    generation++;
    notifyListeners();
  }

  void changedElsewhere(Json next) {
    value = next;
    revision++;
    forms = [descriptor];
    notifyListeners();
  }

  List<Json> get writes => calls
      .where(
        (call) =>
            call.method == 'api.call' && call.params['method'] == 'mutate',
      )
      .map((call) => call.params['args'] as Json)
      .toList();

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method: method, params: copy(params)));
    if (method != 'api.call') {
      throw StateError('Unexpected side effect: $method');
    }
    switch ('${params['namespace']}.${params['method']}') {
      case 'settings.describe':
        if (describeFails) throw PlatformException(code: 'unavailable');
        return {
          'writable': writable,
          'namespaces': [descriptor],
        };
      case 'session.modelCatalog':
        catalogReads++;
        if (nextCatalog != null) {
          final result = nextCatalog!;
          nextCatalog = null;
          return result.future;
        }
        if (catalogFails) throw PlatformException(code: 'catalog/offline');
        return copy(catalog);
      case 'settings.mutate':
        final args = params['args'] as Json;
        expect(args['ns'], subagentModelSettingsNamespace);
        expect(args['expectedRevision'], revision);
        if (conflictOnce) {
          conflictOnce = false;
          value = {
            'enabled': true,
            'allowedModels': [route('local', 'flash')],
          };
          revision++;
          throw PlatformException(code: 'settings/conflict');
        }
        if (!loseReply || applyBeforeLoss) {
          for (final operation in args['ops'] as List) {
            expect(operation['op'], 'set');
            value[(operation['path'] as List).single as String] =
                operation['value'];
          }
          revision++;
        }
        if (loseReply) throw PlatformException(code: 'disconnected');
        return descriptor;
      default:
        throw StateError('Unexpected API: $params');
    }
  }
}

final boundaryKey = GlobalKey();
bool captureFontLoaded = false;
bool get captures => Platform.environment['POCKET_CAPTURE_DIR'] != null;

Future<void> openPage(
  WidgetTester tester,
  SubagentSettingsRuntime runtime, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  Size size = const Size(420, 960),
  bool push = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  if (captures && !captureFontLoaded) {
    await tester.runAsync(() async {
      final bytes = await File(Platform.environment['POCKET_CAPTURE_FONT']!)
          .readAsBytes();
      await (FontLoader(
        'PocketCaptureCjk',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      captureFontLoaded = true;
    });
  }
  final theme = pocketTheme(brightness);
  final page = SubagentModelSettingsPage(runtime: runtime);
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: captures
            ? theme.copyWith(
                textTheme: theme.textTheme.apply(
                  fontFamily: 'PocketCaptureCjk',
                ),
                primaryTextTheme: theme.primaryTextTheme.apply(
                  fontFamily: 'PocketCaptureCjk',
                ),
              )
            : theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: push
            ? Builder(
                builder: (context) => Scaffold(
                  body: PocketButton(
                    onPressed: () => Navigator.push(
                      context,
                      PocketRoute<void>(builder: (_) => page),
                    ),
                    child: const Text('打开模型设置'),
                  ),
                ),
              )
            : page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (push) await tap(tester, find.text('打开模型设置'));
}

Finder get enabled => find.byKey(const ValueKey('subagent-model-enabled'));
Finder get save => find.byKey(const ValueKey('save-subagent-models'));
Finder candidate(String provider, String model) =>
    find.byKey(ValueKey('subagent-route-$provider\u0000$model'));

Future<void> reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder target) async {
  await reveal(tester, target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!captures) return;
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final directory = Directory(Platform.environment['POCKET_CAPTURE_DIR']!);
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png')
        .writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
    'default off page has no writes or implicit session/catalog creation',
    (tester) async {
      final runtime = SubagentSettingsRuntime();
      await openPage(tester, runtime);
      expect(runtime.writes, isEmpty);
      expect(runtime.catalogReads, 0);
      expect(find.textContaining('继承父 Agent'), findsOneWidget);
      expect(tester.widget<PocketButton>(save).onPressed, isNull);
      expect(
        runtime.calls.every((call) => call.params['namespace'] == 'settings'),
        isTrue,
      );
    },
  );

  testWidgets(
    'enable and exact routes save atomically with original revision',
    (tester) async {
      final runtime = SubagentSettingsRuntime();
      await openPage(tester, runtime);
      await tap(tester, enabled);
      expect(runtime.catalogReads, 1);
      expect(tester.widget<PocketButton>(save).onPressed, isNull);
      await tap(tester, candidate('deepseek', 'flash'));
      await tap(tester, candidate('local', 'flash'));
      expect(runtime.writes, isEmpty);
      await tap(tester, save);
      expect(runtime.writes, hasLength(1));
      expect(runtime.writes.single, {
        'ns': subagentModelSettingsNamespace,
        'expectedRevision': 4,
        'ops': [
          {
            'op': 'set',
            'path': ['enabled'],
            'value': true,
          },
          {
            'op': 'set',
            'path': ['allowedModels'],
            'value': [route('deepseek', 'flash'), route('local', 'flash')],
          },
        ],
      });
      expect(find.text('已保存'), findsOneWidget);
    },
  );

  testWidgets(
    'disable retains choices and enabling empty is not unrestricted',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..value = {
          'enabled': true,
          'allowedModels': [route('deepseek', 'flash')],
        };
      await openPage(tester, runtime);
      await tap(tester, candidate('deepseek', 'flash'));
      expect(find.text('请至少选择一个模型'), findsOneWidget);
      expect(tester.widget<PocketButton>(save).onPressed, isNull);
      await tap(tester, candidate('deepseek', 'flash'));
      await tap(tester, enabled);
      expect(find.text('已保留 1 个模型'), findsOneWidget);
      await tap(tester, save);
      expect(runtime.value, {
        'enabled': false,
        'allowedModels': [route('deepseek', 'flash')],
      });
      expect(runtime.writes, hasLength(1));
    },
  );

  testWidgets(
    'restoring the original selected set is not a reordered false edit',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..value = {
          'enabled': true,
          'allowedModels': [
            route('deepseek', 'flash'),
            route('deepseek', 'pro'),
          ],
        };
      await openPage(tester, runtime);
      await tap(tester, candidate('deepseek', 'flash'));
      await tap(tester, candidate('deepseek', 'flash'));
      expect(find.text('已保存'), findsOneWidget);
      expect(tester.widget<PocketButton>(save).onPressed, isNull);
    },
  );

  testWidgets(
    'missing saved exact route remains removable after partial catalog failure',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..value = {
          'enabled': true,
          'allowedModels': [route('legacy', 'CaseSensitive-ID')],
        };
      runtime.catalog['failures'] = [
        {'id': 'legacy', 'name': '旧服务商', 'message': '连接暂不可用'},
      ];
      await openPage(tester, runtime);
      await tap(tester, candidate('deepseek', 'flash'));
      await tap(tester, candidate('legacy', 'CaseSensitive-ID'));
      await tap(tester, save);
      expect(runtime.value['allowedModels'], [route('deepseek', 'flash')]);
      expect(runtime.writes, hasLength(1));
    },
  );

  testWidgets(
    'whole catalog outage preserves saved selection and explicit retry recovers',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..catalogFails = true
        ..value = {
          'enabled': true,
          'allowedModels': [route('legacy', 'opaque-id')],
        };
      await openPage(tester, runtime);
      expect(find.text('模型目录暂未更新'), findsOneWidget);
      await tester.ensureVisible(candidate('legacy', 'opaque-id'));
      expect(
        tester.widget<PocketTile>(candidate('legacy', 'opaque-id')).selected,
        isTrue,
      );
      runtime.catalogFails = false;
      await tap(tester, find.byKey(const ValueKey('subagent-retry-catalog')));
      expect(runtime.catalogReads, 2);
      expect(runtime.value['allowedModels'], [route('legacy', 'opaque-id')]);
      expect(runtime.writes, isEmpty);
    },
  );

  testWidgets(
    'search changes only visible choices and preserves hidden selections',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..value = {
          'enabled': true,
          'allowedModels': [route('deepseek', 'pro')],
        };
      await openPage(tester, runtime);
      await tester.enterText(
        find.byKey(const ValueKey('subagent-model-search')),
        '自定义',
      );
      await tester.pumpAndSettle();
      expect(candidate('deepseek', 'pro'), findsNothing);
      await tap(tester, candidate('local', 'flash'));
      await tap(tester, save);
      expect(runtime.value['allowedModels'], [
        route('deepseek', 'pro'),
        route('local', 'flash'),
      ]);
    },
  );

  testWidgets('read only namespace cannot stage or save', (tester) async {
    final runtime = SubagentSettingsRuntime()
      ..writable = false
      ..value = {
        'enabled': true,
        'allowedModels': [route('deepseek', 'pro')],
      };
    await openPage(tester, runtime);
    expect(tester.widget<PocketSwitchRow>(enabled).onChanged, isNull);
    expect(
      tester.widget<PocketTile>(candidate('deepseek', 'flash')).onTap,
      isNull,
    );
    expect(find.text('当前配置只读'), findsOneWidget);
    expect(runtime.writes, isEmpty);
  });

  testWidgets(
    'remote conflict keeps draft until explicit rebase then uses latest revision',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..conflictOnce = true
        ..value = {
          'enabled': true,
          'allowedModels': [route('deepseek', 'flash')],
        };
      await openPage(tester, runtime);
      await tap(tester, candidate('deepseek', 'pro'));
      await tap(tester, save);
      expect(runtime.writes, hasLength(1));
      expect(tester.widget<PocketButton>(save).onPressed, isNull);
      await tap(tester, find.byKey(const ValueKey('subagent-keep-draft')));
      expect(runtime.writes, hasLength(1));
      await tap(tester, save);
      expect(runtime.writes, hasLength(2));
      expect(runtime.writes.last['expectedRevision'], 5);
      expect(runtime.value['allowedModels'], [
        route('deepseek', 'flash'),
        route('deepseek', 'pro'),
      ]);
    },
  );

  testWidgets(
    'external changes preserve draft and adopt current is read only',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..value = {
          'enabled': true,
          'allowedModels': [route('deepseek', 'flash')],
        };
      await openPage(tester, runtime);
      await tap(tester, candidate('deepseek', 'pro'));
      runtime.changedElsewhere({
        'enabled': false,
        'allowedModels': [route('local', 'flash')],
      });
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('subagent-adopt-current')));
      expect(tester.widget<PocketSwitchRow>(enabled).value, isFalse);
      expect(runtime.writes, isEmpty);
      expect(find.text('已保存'), findsOneWidget);
    },
  );

  testWidgets(
    'unknown save result never replays and user can adopt fresh current state',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..loseReply = true
        ..value = {
          'enabled': true,
          'allowedModels': [route('deepseek', 'flash')],
        };
      await openPage(tester, runtime);
      await tap(tester, candidate('deepseek', 'pro'));
      await tap(tester, save);
      expect(find.text('请先核对保存结果'), findsOneWidget);
      expect(find.byKey(const ValueKey('subagent-keep-draft')), findsNothing);
      await tap(tester, find.byKey(const ValueKey('subagent-check-result')));
      expect(runtime.writes, hasLength(1));
      await tap(tester, find.byKey(const ValueKey('subagent-adopt-current')));
      expect(runtime.writes, hasLength(1));
      expect(find.text('已保存'), findsOneWidget);
    },
  );

  testWidgets(
    'lost reply after commit resolves through readback without duplicate save',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..loseReply = true
        ..applyBeforeLoss = true
        ..value = {
          'enabled': true,
          'allowedModels': [route('deepseek', 'flash')],
        };
      await openPage(tester, runtime);
      await tap(tester, candidate('deepseek', 'pro'));
      await tap(tester, save);
      expect(runtime.writes, hasLength(1));
      expect(find.text('已核对当前配置与目标一致。'), findsOneWidget);
      expect(find.text('已保存'), findsOneWidget);
    },
  );

  testWidgets(
    'exit guard retains draft or discards explicitly without writing',
    (tester) async {
      final runtime = SubagentSettingsRuntime();
      await openPage(tester, runtime, push: true);
      await tap(tester, enabled);
      await tap(tester, find.byTooltip('返回'));
      expect(find.text('保留当前编辑？'), findsOneWidget);
      await tap(tester, find.text('继续编辑'));
      expect(tester.widget<PocketSwitchRow>(enabled).value, isTrue);
      await tap(tester, find.byTooltip('返回'));
      await tap(tester, find.text('放弃编辑并返回'));
      expect(find.text('打开模型设置'), findsOneWidget);
      expect(runtime.writes, isEmpty);
    },
  );

  testWidgets(
    'catalog reply from old connection cannot replace new directory',
    (tester) async {
      final lateCatalog = Completer<dynamic>();
      final runtime = SubagentSettingsRuntime()
        ..nextCatalog = lateCatalog
        ..value = {
          'enabled': true,
          'allowedModels': [route('deepseek', 'flash')],
        };
      await openPage(tester, runtime);
      runtime.reconnect();
      await tester.pumpAndSettle();
      lateCatalog.complete({
        'groups': [
          {
            'id': 'obsolete',
            'name': '旧目录',
            'models': [
              {'id': 'old', 'name': '旧模型'},
            ],
          },
        ],
      });
      await tester.pumpAndSettle();
      expect(candidate('obsolete', 'old'), findsNothing);
      expect(candidate('deepseek', 'flash'), findsOneWidget);
      expect(runtime.writes, isEmpty);
    },
  );

  testWidgets(
    'duplicate saved routes are displayed once and normalize only on explicit save',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..value = {
          'enabled': true,
          'allowedModels': [
            route('deepseek', 'flash'),
            route('deepseek', 'flash'),
          ],
        };
      await openPage(tester, runtime);
      expect(candidate('deepseek', 'flash'), findsOneWidget);
      expect(find.text('保存并合并重复项'), findsOneWidget);
      expect(runtime.writes, isEmpty);
      expect(runtime.value['allowedModels'], hasLength(2));
      await tap(tester, save);
      expect(runtime.writes, hasLength(1));
      expect(runtime.value['allowedModels'], [route('deepseek', 'flash')]);
    },
  );

  testWidgets(
    'malformed saved route does not silently rewrite or drop entries',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..value = {
          'enabled': true,
          'allowedModels': [route('deepseek', '')],
        };
      await openPage(tester, runtime);
      expect(find.textContaining('无效的模型标识'), findsOneWidget);
      expect(tester.widget<PocketButton>(save).onPressed, isNull);
      expect(runtime.writes, isEmpty);
    },
  );

  testWidgets(
    'Web provider changes invalidate catalog in same connection without losing draft',
    (tester) async {
      final runtime = SubagentSettingsRuntime()
        ..value = {
          'enabled': true,
          'allowedModels': [route('deepseek', 'flash')],
        };
      await openPage(tester, runtime);
      await tap(tester, candidate('deepseek', 'pro'));
      runtime.catalog = {
        'groups': [
          {
            'id': 'new',
            'name': '新服务商',
            'models': [
              {'id': 'new-model', 'name': '新模型'},
            ],
          },
        ],
      };
      runtime.forms = [runtime.descriptor];
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(runtime.catalogReads, 2);
      expect(candidate('new', 'new-model'), findsOneWidget);
      expect(
        tester.widget<PocketTile>(candidate('deepseek', 'pro')).selected,
        isTrue,
      );
      expect(runtime.writes, isEmpty);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        'grouped layout ${brightness.name} scale $scale scrolls behind floating controls',
        (tester) async {
          final runtime = SubagentSettingsRuntime()
            ..value = {
              'enabled': true,
              'allowedModels': [
                route('deepseek', 'flash'),
                route('legacy', 'Custom-Long-Model-Identifier'),
              ],
            };
          await openPage(
            tester,
            runtime,
            brightness: brightness,
            scale: scale,
            size: scale > 1 ? const Size(360, 800) : const Size(420, 960),
          );
          await capture(tester, 'subagent-${brightness.name}-$scale-top');
          await reveal(
            tester,
            candidate('legacy', 'Custom-Long-Model-Identifier'),
          );
          await tester.pumpAndSettle();
          await capture(tester, 'subagent-${brightness.name}-$scale-bottom');
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(save).bottom,
            lessThanOrEqualTo(scale > 1 ? 800 : 960),
          );
        },
      );
    }
  }
}
