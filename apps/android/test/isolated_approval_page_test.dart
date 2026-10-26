import 'package:dsh_android/isolated_approval_page.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const runId = '123e4567-e89b-12d3-a456-426614174000';
const requestId = '123e4567-e89b-12d3-a456-426614174001';
const challenge = '123e4567-e89b-12d3-a456-426614174002';
const program = '(input) => input.value + 1';
final programSha256 = 'a' * 64;
final snapshotSha256 = 'b' * 64;

Json review({bool active = false}) => {
  'requestId': requestId,
  'challenge': challenge,
  'runId': runId,
  'sessionId': '123e4567-e89b-12d3-a456-426614174003',
  'expiresAtMillis': 2000000000000,
  'active': active,
  'workspacePath': '/data/user/0/com.minnnng.dsh_android/files/projects/work',
  'readablePaths': ['notes/'],
  'writablePaths': ['notes/out.txt'],
  'exactHosts': ['example.com'],
  'fileCallLimit': 4,
  'networkCallLimit': 2,
  'leaseMillis': 8000,
  'program': program,
  'programSha256': programSha256,
  'snapshotSha256': snapshotSha256,
};

class ApprovalRuntime extends RuntimeController {
  ApprovalRuntime() {
    phase = 'ready';
  }
  List<Json> rows = [review()];
  Json? detailOverride;
  final calls = <(String, Json)>[];

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, Map.of(params)));
    if (method == 'runtime.isolatedApprovals.list') {
      return rows
          .map((row) => Map<String, dynamic>.of(row)..remove('program'))
          .toList();
    }
    if (method == 'runtime.isolatedApprovals.detail') {
      return detailOverride ??
          rows.singleWhere((row) => row['requestId'] == params['requestId']);
    }
    if (method == 'runtime.isolatedApprovals.deny') return true;
    throw StateError('Unexpected approval route: $method');
  }
}

Future<void> open(WidgetTester tester, ApprovalRuntime runtime) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(runtime.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.dark),
      home: IsolatedApprovalInboxPage(runtime: runtime),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('文件访问'));
  await tester.pumpAndSettle();
}

void main() {
  test('malformed review fails closed without editable scope', () {
    expect(
      () => IsolatedApprovalReview.parse({'active': true}),
      throwsFormatException,
    );
    final invalid = review()..['writablePaths'] = '../outside';
    expect(() => IsolatedApprovalReview.parse(invalid), throwsFormatException);
    final missingProgram = review()..remove('program');
    expect(
      () => IsolatedApprovalReview.parse(missingProgram, requireProgram: true),
      throwsFormatException,
    );
    final invalidDigest = review()..['snapshotSha256'] = 'short';
    expect(
      () => IsolatedApprovalReview.parse(invalidDigest),
      throwsFormatException,
    );
    final scope = IsolatedApprovalReview.parse(review());
    expect(scope.writablePaths, ['notes/out.txt']);
    expect(() => scope.writablePaths.add('escape'), throwsUnsupportedError);
  });

  testWidgets(
    'review shows bounded paths and deny sends only request identity',
    (tester) async {
      final runtime = ApprovalRuntime();
      await open(tester, runtime);
      expect(
        find.text('/data/user/0/com.minnnng.dsh_android/files/projects/work'),
        findsWidgets,
      );
      expect(find.text('notes/out.txt'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.text('文件调用 4 次'), findsOneWidget);
      expect(find.text('网络调用 2 次'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      final denial = runtime.calls.singleWhere(
        (call) => call.$1 == 'runtime.isolatedApprovals.deny',
      );
      expect(denial.$2, {'requestId': requestId, 'challenge': challenge});
    },
  );

  testWidgets('program opens full read-only secondary page with both hashes', (
    tester,
  ) async {
    final runtime = ApprovalRuntime();
    await open(tester, runtime);
    await tester.tap(find.text('执行代码'));
    await tester.pumpAndSettle();
    expect(find.text('本次运行的完整程序'), findsOneWidget);
    expect(find.text(program), findsOneWidget);
    expect(find.text(programSha256), findsOneWidget);
    expect(find.text(snapshotSha256), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('changed detail snapshot cannot be approved', (tester) async {
    final runtime = ApprovalRuntime()
      ..detailOverride = (review()..['snapshotSha256'] = 'c' * 64);
    await open(tester, runtime);
    expect(find.text('授权请求已变化，请返回列表刷新后核对'), findsOneWidget);
    expect(find.text('正在读取完整程序'), findsOneWidget);
    await tester.tap(find.text('检查后允许这次运行'));
    await tester.pumpAndSettle();
    expect(runtime.calls.where((call) => call.$1.endsWith('.deny')), isEmpty);
  });

  testWidgets('grant asks native Activity to review exact pending request', (
    tester,
  ) async {
    final runtime = ApprovalRuntime();
    MethodCall? nativeCall;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RuntimeController.channel,
      (call) async {
        nativeCall = call;
        return 'true';
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        null,
      ),
    );
    await open(tester, runtime);
    await tester.tap(find.text('检查后允许这次运行'));
    await tester.pumpAndSettle();
    expect(nativeCall?.method, 'isolatedApproval.review');
    expect(nativeCall?.arguments, {
      'requestId': requestId,
      'snapshotSha256': snapshotSha256,
    });
    expect(runtime.calls.where((call) => call.$1.endsWith('.deny')), isEmpty);
  });

  testWidgets('dismissed native confirmation keeps review pending', (
    tester,
  ) async {
    final runtime = ApprovalRuntime();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      RuntimeController.channel,
      (call) async => false,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        null,
      ),
    );
    await open(tester, runtime);
    await tester.tap(find.text('检查后允许这次运行'));
    await tester.pumpAndSettle();
    expect(find.text('审阅本次运行'), findsOneWidget);
    expect(find.text('授权状态未确认，请返回列表刷新后核对'), findsNothing);
    expect(runtime.calls.where((call) => call.$1.endsWith('.deny')), isEmpty);
  });
}
