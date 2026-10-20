import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dsh_android/configuration_editor.dart';
import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/settings.dart';
import 'package:dsh_android/ui.dart';

class SettingsRuntime extends RuntimeController {
  SettingsRuntime(this.remote) {
    forms = [cloneConfiguration(remote)];
    phase = 'ready';
  }
  Json remote;
  final writes = <Json>[];
  final credentials = <String, String>{};

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    switch (method) {
      case 'settings.describe':
        return [cloneConfiguration(remote)];
      case 'settings.mutate':
        writes.add(cloneConfiguration(params));
        if (params['revision'] != remote['revision']) {
          throw PlatformException(
            code: 'SETTINGS_CONFLICT',
            message: 'changed',
          );
        }
        for (final op in params['ops'] as List) {
          applyConfigurationEdit(remote['value'] as Json, op as Json);
        }
        remote['revision'] = (remote['revision'] as int) + 1;
        return [cloneConfiguration(remote)];
      case 'credentials.describe':
        return {'configured': credentials.containsKey(params['ref'])};
      case 'credentials.set':
        credentials[params['ref'] as String] = params['value'] as String;
        return {'configured': true};
      default:
        throw StateError('Unexpected method $method');
    }
  }
}

Json fixture() => {
  'ns': 'llm-deepseek',
  'revision': 1,
  'value': {'baseURL': 'https://old.example', 'maxTokens': 1024},
  'user': {'baseURL': 'https://old.example'},
  'secrets': [
    {
      'path': ['apiKey'],
      'set': true,
    },
  ],
  'schema': {
    'uid': 1,
    'refs': {
      '1': {
        'uid': 1,
        'type': 'object',
        'dict': {'baseURL': 2, 'maxTokens': 3, 'apiKey': 4},
      },
      '2': {'uid': 2, 'type': 'string'},
      '3': {
        'uid': 3,
        'type': 'number',
        'meta': {'min': 1, 'step': 1},
      },
      '4': {
        'uid': 4,
        'type': 'string',
        'meta': {'role': 'secret'},
      },
    },
  },
};

Finder field(String name) =>
    find.byKey(ValueKey('configuration-field:${jsonEncode([name])}'));

Future<void> openEditor(WidgetTester tester, SettingsRuntime runtime) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: ConfigPage(runtime: runtime, descriptor: runtime.forms.single),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'native fields save only their changes without writing the hidden key or defaults',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      expect(find.text('已配置；值已隐藏，请在凭据入口管理。'), findsOneWidget);
      await tester.enterText(field('baseURL'), 'https://new.example');
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['ops'], [
        {
          'op': 'set',
          'path': ['baseURL'],
          'value': 'https://new.example',
        },
      ]);
      expect(find.text('已保存并应用。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a stale save retains the draft and merges remote changes after an explicit conflict choice',
    (tester) async {
      final runtime = SettingsRuntime(fixture());
      await openEditor(tester, runtime);
      await tester.enterText(field('baseURL'), 'https://mine.example');
      runtime.remote['revision'] = 2;
      runtime.remote['value'] = {
        'baseURL': 'https://remote.example',
        'maxTokens': 2048,
      };
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('baseURL')).controller!.text,
        'https://mine.example',
      );
      expect(runtime.remote['value']['baseURL'], 'https://remote.example');
      await tester.ensureVisible(find.text('保留我的修改'));
      await tester.tap(find.text('保留我的修改'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('合并到草稿'));
      await tester.tap(find.text('合并到草稿'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('baseURL')).controller!.text,
        'https://mine.example',
      );
      expect(
        tester.widget<TextField>(field('maxTokens')).controller!.text,
        '2048',
      );
      expect(runtime.writes, hasLength(1));
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(runtime.writes.last['revision'], 2);
      expect(runtime.remote['value'], {
        'baseURL': 'https://mine.example',
        'maxTokens': 2048,
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('invalid numeric input prevents a write and stays in the field', (
    tester,
  ) async {
    final runtime = SettingsRuntime(fixture());
    await openEditor(tester, runtime);
    await tester.enterText(field('maxTokens'), '-1');
    await tester.pumpAndSettle();
    expect(find.text('不能小于 1。'), findsOneWidget);
    await tester.tap(find.text('保存并应用'));
    await tester.pumpAndSettle();
    expect(runtime.writes, isEmpty);
    expect(tester.widget<TextField>(field('maxTokens')).controller!.text, '-1');
    await tester.ensureVisible(find.text('使用默认值').first);
    await tester.tap(find.text('使用默认值').first);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('maxTokens')).controller!.text, '-1');
    expect(find.text('不能小于 1。'), findsOneWidget);
    expect(runtime.writes, isEmpty);
    runtime.remote['revision'] = 2;
    runtime.remote['value']['maxTokens'] = 2048;
    await runtime.refreshForms();
    await tester.pumpAndSettle();
    final merge = find.ancestor(
      of: find.text('合并到草稿'),
      matching: find.byType(PocketButton),
    );
    expect(tester.widget<PocketButton>(merge).onPressed, isNull);
    expect(tester.widget<TextField>(field('maxTokens')).controller!.text, '-1');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'default model save uses the revisioned settings owner and reports persistence',
    (tester) async {
      final runtime = SettingsRuntime({
        'ns': 'agent-default-model',
        'revision': 4,
        'value': {'provider': 'deepseek-official', 'model': 'deepseek-flash'},
        'user': {},
        'secrets': [],
      });
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          home: ModelSettings(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      final model = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '模型 ID',
      );
      await tester.enterText(model, 'deepseek-pro');
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(runtime.writes.single['revision'], 4);
      expect(runtime.remote['value']['model'], 'deepseek-pro');
      expect(runtime.model, 'deepseek-pro');
      expect(find.text('默认模型已保存；现有 API Key 未改变。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
