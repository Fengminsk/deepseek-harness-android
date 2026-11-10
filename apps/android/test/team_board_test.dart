import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/team_board.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'subagents_data_test.dart' as fixture;

class _Runtime extends fixture.SubagentsRuntime {
  dynamic projection;
  Object? failure;
  bool? lastEnabledRequest;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, Map.of(params)));
    if (method != 'api.call') return super.call(method, params);
    if (failure != null) throw failure!;
    expect(params['args'], isA<Json>());
    final args = params['args'] as Json;
    if (params['namespace'] == 'agentTeams') {
      lastEnabledRequest = args['enabled'] as bool;
      projection = _projection(
        enabled: args['enabled'] as bool,
        tasks: [
          _task('1', status: 'completed'),
        ],
      );
      return null;
    }
    expect(params['namespace'], 'session');
    expect(params['method'], 'projections');
    final request = args;
    expect((request['request'] as Json)['sessionId'], 'root');
    return projection;
  }
}

Map<String, dynamic> _projection({bool enabled = true, List<Json> tasks = const [], String? failure}) => {
  'kind': 'sequenced',
  'asOfSeq': 12,
  'values': {
    'agentTeam': {
      'enabled': enabled,
      'failure': ?failure,
      'tasks': tasks,
    },
  },
};

Json _task(
  String id, {
  String status = 'pending',
  bool ready = true,
  String? ownerName,
  List<String> blockedBy = const [],
  List<String> warnings = const [],
  String description = '',
}) => {
  'id': id,
  'revision': 1,
  'subject': '任务 $id',
  'description': description,
  'status': status,
  'blockedBy': blockedBy,
  'writeScopes': const <String>[],
  'ownerName': ?ownerName,
  if (ownerName != null) 'ownerId': 'owner-$id',
  'ready': ready,
  'warnings': warnings,
};

Future<void> _open(WidgetTester tester, _Runtime runtime) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: TeamBoardSection(runtime: runtime, sessionId: 'root'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('projection parses visible tasks, filters deleted ones, and counts', () {
    final board = TeamBoardState.fromJson({
      'enabled': true,
      'tasks': [
        _task('1', status: 'completed'),
        _task('2', status: 'in_progress', ownerName: '分析员'),
        _task('3', ready: false, blockedBy: ['2']),
        _task('4', status: 'deleted'),
      ],
    })!;
    expect(board.enabled, isTrue);
    expect(board.tasks.map((task) => task.id), ['1', '2', '3']);
    expect(board.completed, 1);
    expect(board.active, 1);
    expect(board.pending, 1);
    expect(board.tasks[1].owner, '分析员');
    expect(board.tasks[2].blocked, isTrue);
    expect(teamProgressLabel(board), '已完成 1  ·  进行中 1  ·  待处理 1');
  });

  test('projection rejects malformed task rows instead of showing partial data', () {
    expect(
      () => TeamBoardState.fromJson({
        'enabled': true,
        'tasks': [
          {'id': '1', 'subject': 'x', 'status': 'unknown', 'ready': true},
        ],
      }),
      throwsFormatException,
    );
    expect(() => TeamBoardState.fromJson({'tasks': []}), throwsFormatException);
  });

  testWidgets('a disabled board and an absent projection keep the switch visible', (tester) async {
    final disabled = _Runtime()..projection = _projection(enabled: false);
    await _open(tester, disabled);
    expect(find.text('团队模式未开启'), findsOneWidget);
    expect(find.text('暂无团队任务'), findsNothing);
    final absent = _Runtime()..projection = {'kind': 'sequenced', 'values': {}};
    await _open(tester, absent);
    expect(find.text('团队模式未开启'), findsOneWidget);
  });

  testWidgets('the switch enables the shared board through the team remote', (tester) async {
    final runtime = _Runtime()..projection = _projection(enabled: false);
    await _open(tester, runtime);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(runtime.lastEnabledRequest, isTrue);
    expect(find.text('团队模式已开启'), findsOneWidget);
    expect(find.text('任务 1'), findsOneWidget);
  });

  testWidgets('enabled board shows progress and expandable task details', (tester) async {
    final runtime = _Runtime()
      ..projection = _projection(tasks: [
        _task('1', status: 'completed', ownerName: '校验员'),
        _task('2', status: 'in_progress', ownerName: '分析员', description: '读取报告'),
        _task('3', ready: false, blockedBy: ['2']),
      ]);
    await _open(tester, runtime);
    expect(find.text('团队任务'), findsOneWidget);
    expect(find.text('已完成 1  ·  进行中 1  ·  待处理 1'), findsOneWidget);
    expect(find.text('任务 2'), findsOneWidget);
    expect(find.text('被阻塞'), findsOneWidget);
    await tester.tap(find.text('任务 2'));
    await tester.pumpAndSettle();
    expect(find.text('读取报告'), findsOneWidget);
    expect(find.text('负责人：分析员'), findsOneWidget);
  });

  testWidgets('host failure stays visible instead of claiming an empty board', (tester) async {
    final runtime = _Runtime()
      ..projection = _projection(failure: '投影损坏');
    await _open(tester, runtime);
    expect(find.text('投影损坏'), findsOneWidget);
  });

  testWidgets('an unreadable projection reports the failure code', (tester) async {
    final runtime = _Runtime()
      ..failure = StateError('projection unavailable');
    await _open(tester, runtime);
    expect(find.textContaining('团队任务未能读取。'), findsOneWidget);
  });
}
