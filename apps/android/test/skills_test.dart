import 'dart:async';

import 'package:dsh_android/composer_commands.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/skills.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Json skill(String name, {bool model = true, String? path}) => {
  'name': name,
  'description': 'Instructions for $name',
  'modelInvocable': model,
  'path': ?path,
};

class SkillsRuntime extends RuntimeController {
  SkillsRuntime() {
    phase = 'ready';
  }
  final notifications = StreamController<Json>.broadcast(sync: true);
  final requests = <Json>[];
  int connection = 0;
  @override
  int get connectionGeneration => connection;
  @override
  Stream<Json> get remoteEvents => notifications.stream;
  Future<Json> Function()? read;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    expectSync(
      method,
      'api.call',
      reason: 'Skill browsing must not activate history or send prompts',
    );
    expectSync(params['namespace'], 'skills');
    expectSync(params['method'], 'list');
    expectSync(params['args'], {
      'request': {'sessionId': 'session'},
    });
    requests.add(params);
    return read == null
        ? {
            'skills': [skill('summarize', model: false), skill('analyze')],
          }
        : await read!();
  }

  void reconnect(String next) {
    phase = next;
    connection++;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(notifications.close());
    super.dispose();
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'source ranking retains prefix, boundary, gap and stable tie behavior',
    () {
      final values = [
        'q-xylophone',
        'qx-long',
        'fabulous',
        'foo-bar',
        'zuv',
        'zu1v',
        'yu1v',
        'zu12v',
      ].map((name) => SessionSkill.fromJson(skill(name))).toList();
      List<String> ranked(String query) =>
          rankSessionSkills(values, query).map((v) => v.name).toList();
      expect(identical(rankSessionSkills(values, ''), values), isTrue);
      expect(ranked('QX'), ['qx-long', 'q-xylophone']);
      expect(ranked('fb'), ['foo-bar', 'fabulous']);
      expect(ranked('uv'), ['zuv', 'zu1v', 'yu1v', 'zu12v']);
      expect(ranked('zzz'), isEmpty);
    },
  );

  test('skill pick inserts literal text and keeps draft arguments; commands retain priority', () {
    expect(
      insertSessionSkill(
        const TextEditingValue(text: '整理这些文件'),
        'summarize',
      ).text,
      '/summarize 整理这些文件',
    );
    final next = insertSessionSkill(
      const TextEditingValue(text: '/old  整理这些文件'),
      'summarize',
    );
    expect(next.text, '/summarize 整理这些文件');
    expect(next.selection.baseOffset, '/summarize '.length);
    expect(
      insertSessionSkill(
        const TextEditingValue(text: '/path/file'),
        'summarize',
      ).text,
      '/summarize /path/file',
    );
    expect(
      typedComposerCommand('/plan details', [
        {
          'name': 'plan',
          'input': {},
          'definitionId': commandDefinitions['plan'],
        },
      ])?.descriptor['name'],
      'plan',
    );
    expect(typedComposerCommand('/summarize details', []), isNull);
  });

  test(
    'cold catalog keeps user-only and virtual skills without creating an Agent',
    () async {
      final runtime = SkillsRuntime();
      final controller = SessionSkillsController(runtime, 'session');
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      controller.start();
      await settle();
      expect(controller.current, isTrue);
      expect(controller.skills.first.modelInvocable, isFalse);
      expect(controller.skills.first.path, isNull);
      expect(runtime.requests, hasLength(1));
      controller.start();
      await settle();
      expect(runtime.requests, hasLength(1));
    },
  );

  test(
    'only a caller-owned unsaved draft may prepare after explicit not-found',
    () async {
      final runtime = SkillsRuntime();
      var prepared = 0;
      runtime.read = () async {
        if (prepared == 0) throw PlatformException(code: 'session/not-found');
        return {
          'skills': [skill('summarize')],
        };
      };
      final controller = SessionSkillsController(
        runtime,
        'session',
        prepareDraft: () async {
          prepared++;
        },
      );
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      controller.start();
      await settle();
      expect(prepared, 1);
      expect(controller.current, isTrue);
      final historical = SessionSkillsController(runtime, 'session');
      addTearDown(historical.dispose);
      runtime.read = () async =>
          throw PlatformException(code: 'session/not-found');
      historical.start();
      await settle();
      expect(historical.error, contains('不可访问'));
      expect(prepared, 1);
    },
  );

  test('preset and plugin invalidation reject stale results, reconnect does not reuse old catalog', () async {
    final runtime = SkillsRuntime();
    final pending = Completer<Json>();
    runtime.read = () => pending.future;
    final controller = SessionSkillsController(runtime, 'session');
    addTearDown(runtime.dispose);
    addTearDown(controller.dispose);
    controller.start();
    runtime.notifications.add({
      'event': 'agent-preset/selected',
      'args': ['other', 'next'],
    });
    expect(runtime.requests, hasLength(1));
    runtime.read = () async => {
      'skills': [skill('fresh')],
    };
    runtime.notifications.add({
      'event': 'agent-preset/selected',
      'args': ['session', 'next'],
    });
    await settle();
    pending.complete({
      'skills': [skill('old')],
    });
    await settle();
    expect(controller.skills.single.name, 'fresh');
    runtime.reconnect('disconnected');
    expect(controller.current, isFalse);
    expect(controller.skills, isEmpty);
    runtime.reconnect('ready');
    await settle();
    expect(controller.skills.single.name, 'fresh');
    final count = runtime.requests.length;
    runtime.notifications.add({'event': 'plugin-manager/changed', 'args': []});
    await settle();
    expect(runtime.requests.length, count + 1);
  });

  test(
    'malformed catalog is visible and disposal ignores late completion',
    () async {
      final runtime = SkillsRuntime();
      addTearDown(runtime.dispose);
      runtime.read = () async => {
        'skills': [skill('duplicate'), skill('duplicate')],
      };
      final controller = SessionSkillsController(runtime, 'session');
      controller.start();
      await settle();
      expect(controller.error, isNotNull);
      expect(controller.current, isFalse);
      final pending = Completer<Json>();
      runtime.read = () => pending.future;
      final request = controller.load();
      controller.dispose();
      pending.complete({
        'skills': [skill('late')],
      });
      await request;
      expect(controller.current, isFalse);
    },
  );

  testWidgets(
    'native picker searches one catalog and returns a skill without sending',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final runtime = SkillsRuntime();
      final controller = SessionSkillsController(runtime, 'session');
      addTearDown(runtime.dispose);
      addTearDown(controller.dispose);
      SessionSkill? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: PocketButton(
                onPressed: () async {
                  picked = await Navigator.of(context).push<SessionSkill>(
                    PocketRoute<SessionSkill>(
                      builder: (_) => SessionSkillsPage(controller: controller),
                    ),
                  );
                },
                child: const Text('选择技能'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择技能'));
      await tester.pumpAndSettle();
      expect(find.textContaining('仅由你主动调用'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('skill-search')), 'sm');
      await tester.pumpAndSettle();
      expect(find.text('/summarize'), findsOneWidget);
      expect(find.text('/analyze'), findsNothing);
      expect(runtime.requests, hasLength(1));
      await tester.tap(find.text('/summarize'));
      await tester.pumpAndSettle();
      expect(picked?.name, 'summarize');
      expect(tester.takeException(), isNull);
    },
  );
}
