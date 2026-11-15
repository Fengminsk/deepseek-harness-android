// 远程「本次变更」页：快照定位的加载/降级/失败三态、文件列表、差异渲染与取消。
//
// 页面不直接发门面请求；测试替身实现 `RemoteWorkspaceChangesSource`，因此可以在
// 没有 PC 的情况下验证「先列表、点文件读差异、离开页面取消在途请求」这些产品行为。

import 'dart:async';

import 'package:dsh_android/remote_conversation_source.dart';
import 'package:dsh_android/remote_workspace_diff_page.dart';
import 'package:dsh_android/runtime_transport.dart';
import 'package:dsh_android/ui.dart';
import 'package:dsh_android/workspace_changes.dart';
import 'package:dsh_android/workspace_diff.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/remote_conversation_fakes.dart';

/// 两个文件的摘要：用来验证点第几个文件就请求哪个 index。
WorkspaceChangesSummary _twoFileSummary() => const WorkspaceChangesSummary(
  turn: 3,
  total: 2,
  added: 3,
  deleted: 1,
  files: <WorkspaceChangedFile>[
    WorkspaceChangedFile(
      path: 'lib/a.dart',
      display: 'lib/a.dart',
      added: 2,
      deleted: 1,
    ),
    WorkspaceChangedFile(
      path: 'lib/b.dart',
      display: 'lib/b.dart',
      added: 1,
      deleted: 0,
    ),
  ],
);

Future<void> _show(WidgetTester tester, RemoteWorkspaceChangesSource source) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: RemoteWorkspaceDiffPage(source: source),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('定位成功后列文件，点第二个文件读取该下标的差异', (tester) async {
    final source = FakeRemoteWorkspaceChangesSource(
      resolution: RemoteWorkspaceChangesFound(seq: 7, summary: _twoFileSummary()),
      diffs: <int, WorkspaceFileDiff>{
        1: testWorkspaceFileDiff(
          display: 'lib/b.dart',
          lines: const <String>['+b line', ' b context'],
        ),
      },
    );
    await _show(tester, source);

    expect(source.resolves, 1);
    expect(find.text('本次变更'), findsOneWidget);
    expect(find.text('第 3 轮 · 2 个文件'), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-changes-file-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-changes-file-1')), findsOneWidget);
    expect(find.byType(WorkspaceDiffBody), findsNothing, reason: '先停在文件列表');

    await tester.tap(find.byKey(const ValueKey('remote-changes-file-1')));
    await tester.pumpAndSettle();

    expect(source.diffSeqs, <int>[7], reason: '差异读取必须带快照的 seq');
    expect(source.diffIndexes, <int>[1], reason: '按点中的文件下标读取');
    expect(find.byType(WorkspaceDiffBody), findsOneWidget);
    expect(find.text('lib/b.dart'), findsOneWidget);
    expect(find.text('b line'), findsOneWidget);
    expect(find.text('b context'), findsOneWidget);
  });

  testWidgets('查找期间显示进度，降级态说明原因并可刷新', (tester) async {
    final source = FakeRemoteWorkspaceChangesSource(
      hold: Completer<void>(),
      progress: const <RemoteWorkspaceScanProgress>[
        RemoteWorkspaceScanProgress(attempt: 1, limit: 30, seq: 9),
      ],
      resolution: const RemoteWorkspaceChangesUnavailable(
        scanned: 1,
        limit: 30,
        startSeq: 9,
        announced: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: RemoteWorkspaceDiffPage(source: source),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('remote-changes-resolving')), findsOneWidget);
    expect(find.textContaining('第 1/30 步'), findsOneWidget);

    source.hold!.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('remote-changes-unavailable')),
      findsOneWidget,
    );
    expect(find.text('这轮改动的内容已不可用'), findsOneWidget);
    expect(find.textContaining('只保留在电脑当前运行的 DSH 进程里'), findsOneWidget);

    source.hold = null;
    source.resolution = RemoteWorkspaceChangesFound(
      seq: 9,
      summary: _twoFileSummary(),
    );
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();

    expect(source.resolves, 2);
    expect(find.byKey(const ValueKey('remote-changes-files')), findsOneWidget);
  });

  testWidgets('本轮未结束时提示结束后可查看，不会给出空摘要', (tester) async {
    final source = FakeRemoteWorkspaceChangesSource(
      resolution: const RemoteWorkspaceChangesPendingTurn(),
    );
    await _show(tester, source);

    expect(
      find.byKey(const ValueKey('remote-changes-pending-turn')),
      findsOneWidget,
    );
    expect(find.text('本轮结束后可查看变更'), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-changes-files')), findsNothing);
  });

  testWidgets('读取失败展示原因，重试成功后回到文件列表', (tester) async {
    final source = FakeRemoteWorkspaceChangesSource(
      resolution: const RemoteWorkspaceChangesFailure(
        '与电脑的连接已断开，请重新连接后再试。',
      ),
    );
    await _show(tester, source);

    expect(find.byKey(const ValueKey('remote-changes-failed')), findsOneWidget);
    expect(find.text('与电脑的连接已断开，请重新连接后再试。'), findsOneWidget);

    source.resolution = RemoteWorkspaceChangesFound(
      seq: 4,
      summary: testWorkspaceChangesSummary(turn: 4),
    );
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(source.resolves, 2);
    expect(find.text('第 4 轮 · 1 个文件'), findsOneWidget);
  });

  testWidgets('差异读取失败给出可读状态，重试成功后渲染差异', (tester) async {
    final source = FakeRemoteWorkspaceChangesSource(
      resolution: RemoteWorkspaceChangesFound(
        seq: 5,
        summary: testWorkspaceChangesSummary(turn: 5),
      ),
      diffFailure: const RuntimeTransportFailure(
        code: 'workspace-changes/unavailable',
        message: '这轮改动的内容已不可用。',
      ),
    );
    await _show(tester, source);
    await tester.tap(find.byKey(const ValueKey('remote-changes-file-0')));
    await tester.pumpAndSettle();

    expect(find.text('读取差异失败：这轮改动的内容已不可用。'), findsOneWidget);
    expect(tester.widget<WorkspaceDiffBody>(find.byType(WorkspaceDiffBody)).state.phase,
        WorkspaceReadPhase.error);

    source.diffFailure = null;
    source.diffs[0] = testWorkspaceFileDiff(
      display: 'lib/a.dart',
      lines: const <String>['+fixed line'],
    );
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('fixed line'), findsOneWidget);
  });

  testWidgets('自动换行开关切换差异行的换行行为', (tester) async {
    final source = FakeRemoteWorkspaceChangesSource(
      resolution: RemoteWorkspaceChangesFound(
        seq: 2,
        summary: testWorkspaceChangesSummary(turn: 2),
      ),
      diffs: <int, WorkspaceFileDiff>{
        0: testWorkspaceFileDiff(),
      },
    );
    await _show(tester, source);
    await tester.tap(find.byKey(const ValueKey('remote-changes-file-0')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<WorkspaceDiffBody>(find.byType(WorkspaceDiffBody)).wrap,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('remote-changes-wrap')));
    await tester.pump();

    expect(
      tester.widget<WorkspaceDiffBody>(find.byType(WorkspaceDiffBody)).wrap,
      isFalse,
    );
  });

  testWidgets('顶部的文件条点按回到文件列表', (tester) async {
    final source = FakeRemoteWorkspaceChangesSource(
      resolution: RemoteWorkspaceChangesFound(
        seq: 2,
        summary: _twoFileSummary(),
      ),
      diffs: <int, WorkspaceFileDiff>{
        0: testWorkspaceFileDiff(),
      },
    );
    await _show(tester, source);
    await tester.tap(find.byKey(const ValueKey('remote-changes-file-0')));
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceDiffBody), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-changes-diff-header')));
    await tester.pumpAndSettle();

    expect(find.byType(WorkspaceDiffBody), findsNothing);
    expect(find.byKey(const ValueKey('remote-changes-files')), findsOneWidget);
  });

  testWidgets('离开页面时取消在途请求并释放数据源', (tester) async {
    final source = FakeRemoteWorkspaceChangesSource(hold: Completer<void>());
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: RemoteWorkspaceDiffPage(source: source),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(source.cancels, greaterThanOrEqualTo(1));
    expect(source.disposed, isTrue);
  });

  test('目的地标识是公开常量，不会与会话页叠成两层', () {
    expect(RemoteWorkspaceDiffPage.routeDestination, 'remote-workspace-changes');
    expect(
      destinationRouteName(RemoteWorkspaceDiffPage.routeDestination),
      'dsh-destination:remote-workspace-changes',
    );
  });
}
