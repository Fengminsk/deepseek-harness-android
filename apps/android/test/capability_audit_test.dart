import 'package:dsh_android/capability_audit.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const runId = 'f753a8d1-b571-4ab3-b565-bcb093b24d99';

class AuditRuntime extends RuntimeController {
  AuditRuntime() {
    phase = 'ready';
  }

  final calls = <Json>[];
  bool changed = false;

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    expect(method, 'runtime.capabilityAudit');
    calls.add(Map.of(params));
    if (changed) throw StateError('Journal changed');
    if (params['runId'] == runId) {
      return <String, dynamic>{
        'state': 'review',
        'bytes': 432,
        'runId': runId,
        'ownerId': 'task:test',
        'unfinished': true,
        'auditUncertain': true,
        'callCount': 1,
        'calls': [
          <String, dynamic>{
            'callId': '5c01fb49-d7e1-4bac-b02b-010bb571310f',
            'action': 'EDIT',
            'target': 'notes.txt',
            'expectedRevision': 'original-version',
            'resultRevision': null,
            'reason': 'CALL_NOT_SETTLED',
          },
        ],
        'nextOffset': null,
      };
    }
    return <String, dynamic>{
      'state': 'review',
      'startupBlocked': true,
      'admissionBlocked': true,
      'bytes': 432,
      'damaged': false,
      'capacityReached': false,
      'truncated': false,
      'runCount': 1,
      'runs': [
        <String, dynamic>{
          'ownerId': 'task:test',
          'runId': runId,
          'unfinished': true,
          'auditUncertain': true,
          'callCount': 1,
        },
      ],
      'nextOffset': null,
    };
  }
}

void main() {
  testWidgets(
    'uncertain file operation stays read-only across detail and refresh',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final runtime = AuditRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: CapabilityAuditPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('有执行结果需要核对'), findsOneWidget);
      expect(find.text('task:test'), findsOneWidget);
      expect(find.text('已恢复'), findsNothing);
      await tester.tap(find.text('task:test'));
      await tester.pumpAndSettle();
      expect(find.textContaining('notes.txt'), findsOneWidget);
      expect(find.textContaining('original-version'), findsOneWidget);
      expect(runtime.calls.last['expectedBytes'], 432);
      expect(runtime.calls.last['runId'], runId);
      expect(find.text('已恢复'), findsNothing);
      runtime.changed = true;
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is GlassButton && widget.label == '重读记录',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('审计日志已变化或无法读取'), findsOneWidget);
      runtime.fail(StateError('process stopped'));
      await tester.pumpAndSettle();
      expect(find.textContaining('notes.txt'), findsNothing);
      expect(find.textContaining('服务已更换'), findsOneWidget);
    },
  );

  testWidgets('service restart clears stale capability audit facts', (
    tester,
  ) async {
    final runtime = AuditRuntime();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: CapabilityAuditPage(runtime: runtime),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('task:test'), findsOneWidget);
    runtime.changed = true;
    runtime.fail(StateError('process stopped'));
    await tester.pumpAndSettle();
    expect(find.text('task:test'), findsNothing);
    expect(find.textContaining('审计记录未确认'), findsOneWidget);
  });
}
