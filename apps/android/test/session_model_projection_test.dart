import 'package:dsh_android/main.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_model_projection.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _flash = {'provider': 'deepseek-account', 'model': 'deepseek-flash'};
const _pro = {'provider': 'deepseek-account', 'model': 'deepseek-v4-pro'};

Json _selected(int seq, Json selection) => {
  'seq': seq,
  'type': 'model/selection',
  'data': selection,
};

Json _used(int seq, Json selection) => {
  'seq': seq,
  'type': 'request/header',
  'data': {
    'header': {'config': selection},
    'reason': 'initial',
  },
};

void main() {
  test('a blank Session leaves default selection to its caller', () {
    expect(nextSessionModel(const []), isNull);
    expect(
      nextSessionModel([
        {
          'seq': 0,
          'type': 'turn/start',
          'data': {'turn': 1},
        },
      ]),
      isNull,
    );
  });

  test(
    'without pending intent the latest request determines the next model',
    () {
      expect(nextSessionModel([_used(0, _flash), _used(1, _pro)]), _pro);
    },
  );

  test('repeated old headers cannot consume a newer pending model choice', () {
    // The original session-projections.host.spec.ts repeats both selection and
    // old request headers before the selected request finally arrives.
    expect(
      nextSessionModel([
        _selected(0, _pro),
        _selected(1, _pro),
        _used(2, _flash),
        _used(3, _flash),
      ]),
      _pro,
    );
  });

  test('a matching request consumes the pending choice exactly once', () {
    final events = [_selected(0, _pro), _used(1, _flash), _used(2, _pro)];
    expect(nextSessionModel(events), _pro);
    expect(nextSessionModel([...events, _used(3, _flash)]), _flash);
  });

  test(
    'consumption requires provider and reasoning effort as well as model',
    () {
      final chosen = {..._pro, 'reasoningEffort': 'max'};
      final otherProvider = {...chosen, 'provider': 'another-provider'};
      final otherEffort = {..._pro, 'reasoningEffort': 'high'};
      expect(
        nextSessionModel([
          _selected(0, chosen),
          _used(1, otherProvider),
          _used(2, otherEffort),
          _used(3, _flash),
        ]),
        chosen,
      );
      expect(
        nextSessionModel([
          _selected(0, chosen),
          _used(1, chosen),
          _used(2, _flash),
        ]),
        _flash,
      );
    },
  );

  test('request effort is normalized as in the original projection', () {
    final chosen = {..._pro, 'reasoningEffort': '2'};
    expect(
      nextSessionModel([
        _selected(0, chosen),
        _used(1, {..._pro, 'reasoningEffort': 2}),
        _used(2, _flash),
      ]),
      _flash,
    );
  });

  test('a later explicit choice replaces earlier pending intent', () {
    expect(
      nextSessionModel([
        _selected(0, _pro),
        _selected(1, _flash),
        _used(2, _pro),
      ]),
      _flash,
    );
  });

  testWidgets(
    'chat title retains pending choice and a new Session uses its own default',
    (tester) async {
      final runtime = RuntimeController()
        ..phase = 'ready'
        ..model = 'new-session-default';
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: ChatPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      final id = runtime.timelines.keys.single;
      final events = runtime.timelines[id]!;
      events.add(_selected(0, _pro));
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('deepseek-v4-pro'), findsOneWidget);
      events.addAll([_used(1, _flash), _used(2, _flash)]);
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('deepseek-v4-pro'), findsOneWidget);
      expect(find.text('deepseek-flash'), findsNothing);

      events.add(_used(3, _pro));
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('deepseek-v4-pro'), findsOneWidget);
      events.add(_used(4, _flash));
      runtime.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('deepseek-flash'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '此会话草稿');
      await tester.tap(find.byTooltip('新对话'));
      await tester.pumpAndSettle();
      expect(runtime.timelines, hasLength(2));
      expect(find.text('new-session-default'), findsOneWidget);
      expect(find.text('deepseek-flash'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
