import 'dart:async';

import 'package:dsh_android/models_label.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _CatalogRuntime extends RuntimeController {
  _CatalogRuntime() {
    phase = 'ready';
  }

  int epoch = 0;
  final reads = <Completer<Json>>[];
  @override
  int get connectionGeneration => epoch;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) {
    if (method != 'api.call' ||
        params['namespace'] != 'session' ||
        params['method'] != 'modelCatalog') {
      throw StateError('Unexpected request: $method $params');
    }
    final read = Completer<Json>();
    reads.add(read);
    return read.future;
  }

  void reconnect() {
    epoch++;
    notifyListeners();
  }
}

Json _catalog(String name) => {
  'groups': [
    {
      'id': 'deepseek-official',
      'models': [
        {'id': 'deepseek-flash', 'name': name},
      ],
    },
  ],
};

void main() {
  test('1017 is limited to the two official exact Flash catalog entries', () {
    for (final provider in ['deepseek-account', 'deepseek-official']) {
      expect(
        showsDeepSeek1017Badge(
          providerId: provider,
          modelId: 'deepseek-flash',
          modelName: 'DeepSeek-V4.1-Flash',
        ),
        isTrue,
      );
    }
    for (final input in [
      ('custom-deepseek', 'deepseek-flash', 'DeepSeek-V4.1-Flash'),
      ('deepseek-official', 'deepseek-flash-copy', 'DeepSeek-V4.1-Flash'),
      ('deepseek-account', 'deepseek-flash', 'My Flash'),
      ('deepseek-account', 'deepseek-flash', 'DeepSeek-V4.1-Flash-1017'),
      ('deepseek-official', 'deepseek-flash', 'DeepSeek-V4.1-Flash-1024'),
    ]) {
      expect(
        showsDeepSeek1017Badge(
          providerId: input.$1,
          modelId: input.$2,
          modelName: input.$3,
        ),
        isFalse,
        reason: '$input must preserve the catalog label',
      );
    }
    expect(
      showsDeepSeek1017Badge(
        providerId: 'deepseek-account',
        modelId: 'deepseek-flash',
        modelName: 'DeepSeek-V4.1-Flash',
        enabled: false,
      ),
      isFalse,
    );
  });

  testWidgets('inline badge is visual and can be disabled without renaming', (
    tester,
  ) async {
    Widget page(bool enabled) => MaterialApp(
      home: Scaffold(
        body: ModelReleaseLabel(
          providerId: 'deepseek-official',
          modelId: 'deepseek-flash',
          modelName: 'DeepSeek-V4.1-Flash',
          suffix: ' · High',
          badgeEnabled: enabled,
        ),
      ),
    );
    await tester.pumpWidget(page(true));
    expect(find.text('1017'), findsOneWidget);
    expect(find.textContaining('DeepSeek-V4.1-Flash'), findsOneWidget);
    await tester.pumpWidget(page(false));
    expect(find.text('1017'), findsNothing);
    expect(find.text('DeepSeek-V4.1-Flash · High'), findsOneWidget);
  });

  testWidgets('a prior connection cannot publish a stale catalog label', (
    tester,
  ) async {
    final runtime = _CatalogRuntime();
    final catalog = CurrentModelCatalog(runtime);
    addTearDown(() {
      catalog.dispose();
      runtime.dispose();
    });
    const route = {'provider': 'deepseek-official', 'model': 'deepseek-flash'};
    expect(runtime.reads, hasLength(1));
    expect(currentModelCatalogName(catalog, route), 'deepseek-flash');
    runtime.reconnect();
    expect(runtime.reads, hasLength(2));
    runtime.reads.first.complete(_catalog('Stale version'));
    await tester.pump();
    expect(currentModelCatalogName(catalog, route), 'deepseek-flash');
    runtime.reads.last.complete(_catalog('DeepSeek-V4.1-Flash'));
    await tester.pump();
    expect(currentModelCatalogName(catalog, route), 'DeepSeek-V4.1-Flash');
  });
}
