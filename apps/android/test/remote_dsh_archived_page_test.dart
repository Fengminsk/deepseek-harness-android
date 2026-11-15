// 已归档任务页：注入数据源后的列表、恢复、空态与失败重试。
//
// 页面不直接发请求；测试替身实现 `RemoteDshArchiveSource`，因此可以在没有 PC 的
// 情况下验证「恢复后重读列表」「归档来自电脑」这两个产品行为。

import 'package:dsh_android/remote_dsh_archived_page.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// 已归档任务页的假数据源：记录恢复调用并允许注入读取失败。
class _FakeArchiveSource implements RemoteDshArchiveSource {
  _FakeArchiveSource(this.sessions, {this.error});

  /// 当前已归档会话；恢复后从列表里移除。
  List<RemoteDshArchivedSession> sessions;

  /// 读取时抛出的失败；为 null 时正常返回。
  Object? error;

  int loads = 0;
  final List<String> restored = <String>[];

  @override
  Future<List<RemoteDshArchivedSession>> listArchivedSessions() async {
    loads++;
    final failure = error;
    if (failure != null) throw failure;
    return List<RemoteDshArchivedSession>.of(sessions);
  }

  @override
  Future<void> restoreSession(String sessionId) async {
    restored.add(sessionId);
    sessions = <RemoteDshArchivedSession>[
      for (final session in sessions)
        if (session.id != sessionId) session,
    ];
  }
}

const _archived = <RemoteDshArchivedSession>[
  RemoteDshArchivedSession(id: 'a-1', title: '旧任务', projectName: 'Pocket'),
  RemoteDshArchivedSession(id: 'a-2', title: '另一条旧任务', projectName: 'CarsTool'),
];

Future<void> _show(
  WidgetTester tester,
  RemoteDshArchiveSource source, {
  ValueChanged<RemoteDshArchivedSession>? onOpen,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: RemoteDshArchivedPage(source: source, onOpen: onOpen),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('列出已归档会话的标题与项目，点按交给调用方打开', (tester) async {
    final source = _FakeArchiveSource(
      List<RemoteDshArchivedSession>.of(_archived),
    );
    final opened = <String>[];
    await _show(tester, source, onOpen: (session) => opened.add(session.id));

    expect(find.text('已归档任务'), findsOneWidget);
    expect(find.text('旧任务'), findsOneWidget);
    expect(find.text('另一条旧任务'), findsOneWidget);
    expect(find.text('Pocket'), findsOneWidget);
    expect(find.text('共 2 个已归档会话'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-archived-a-1')));
    await tester.pumpAndSettle();
    expect(opened, <String>['a-1']);
  });

  testWidgets('恢复回写电脑后重读列表，行从页面上消失', (tester) async {
    final source = _FakeArchiveSource(
      List<RemoteDshArchivedSession>.of(_archived),
    );
    await _show(tester, source);

    await tester.tap(find.byKey(const ValueKey('remote-archived-restore-a-1')));
    await tester.pumpAndSettle();

    expect(source.restored, <String>['a-1']);
    expect(source.loads, 2, reason: '恢复后重读列表，以电脑的归档集合为准');
    expect(find.byKey(const ValueKey('remote-archived-a-1')), findsNothing);
    expect(find.byKey(const ValueKey('remote-archived-a-2')), findsOneWidget);
    expect(find.text('已恢复「旧任务」，它会回到项目列表。'), findsOneWidget);
  });

  testWidgets('全部恢复后给出说明归档来源的空态', (tester) async {
    final source = _FakeArchiveSource(<RemoteDshArchivedSession>[
      _archived.first,
    ]);
    await _show(tester, source);

    await tester.tap(find.byKey(const ValueKey('remote-archived-restore-a-1')));
    await tester.pumpAndSettle();

    expect(find.text('没有已归档的任务'), findsOneWidget);
    expect(find.textContaining('在电脑上的 DSH 里归档的会话会显示在这里'), findsOneWidget);
  });

  testWidgets('读取失败给出原因，重试成功后显示列表', (tester) async {
    final source = _FakeArchiveSource(
      List<RemoteDshArchivedSession>.of(_archived),
      error: PlatformException(
        code: 'gateway/unavailable',
        message: '与电脑的连接已断开，正在重连…',
      ),
    );
    await _show(tester, source);

    expect(find.text('读取已归档任务失败'), findsOneWidget);
    expect(find.text('与电脑的连接已断开，正在重连…'), findsOneWidget);

    source.error = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('旧任务'), findsOneWidget);
  });

  test('归档页的目的地标识是公开常量', () {
    expect(RemoteDshArchivedPage.routeDestination, 'remote-dsh-archived');
    expect(
      destinationRouteName(RemoteDshArchivedPage.routeDestination),
      'dsh-destination:remote-dsh-archived',
    );
  });
}
