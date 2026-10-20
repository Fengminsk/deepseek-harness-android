import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_android/approvals_draft.dart';

void main() {
  test(
    'single choice and custom text replace one another without changing labels',
    () {
      final draft = QuestionAnswerDraft({
        'id': 'network-choice',
        'question': 'Which network?',
        'options': [
          {'label': 'Local (Recommended)'},
          {'label': 'LAN'},
        ],
      });
      expect(draft.complete, false);
      draft.choose('Local (Recommended)');
      expect(draft.answer(), {
        'id': 'network-choice',
        'selected': ['Local (Recommended)'],
      });
      draft.write('  My explanation  ');
      expect(draft.answer(), {
        'id': 'network-choice',
        'selected': <String>[],
        'custom': 'My explanation',
      });
      expect(draft.custom, '  My explanation  ');
      draft.choose('LAN');
      expect(draft.custom, '');
      expect(draft.answer()['selected'], ['LAN']);
    },
  );

  test(
    'multiple selections may accompany custom text and can be deselected',
    () {
      final draft = QuestionAnswerDraft({
        'id': 'targets',
        'question': 'Choose targets',
        'multiSelect': true,
        'options': [
          {'label': 'Phone'},
          {'label': 'Tablet'},
        ],
      });
      draft.choose('Phone');
      draft.choose('Tablet');
      draft.write('Computer too');
      draft.choose('Phone');
      expect(draft.answer(), {
        'id': 'targets',
        'selected': ['Tablet'],
        'custom': 'Computer too',
      });
    },
  );

  test('all question ids are echoed, with an empty answer only after explicit skip', () {
    final first = QuestionAnswerDraft({'id': 'a', 'question': 'First'});
    final second = QuestionAnswerDraft({'id': 'b', 'question': 'Second'});
    first.write('Answer');
    expect(
      () => questionDraftAnswer([first, second]),
      throwsA(isA<IncompleteQuestionDraft>()),
    );
    second.skip();
    expect(questionDraftAnswer([first, second]), {
      'answers': [
        {'id': 'a', 'selected': <String>[], 'custom': 'Answer'},
        {'id': 'b', 'selected': <String>[]},
      ],
    });
    second.write('Now answered');
    expect(second.skipped, false);
  });

  test('plan options remain exactly caller-labelled regardless of approval position', () {
    final draft = QuestionAnswerDraft({
      'id': 'review',
      'question': 'Review the plan',
      'detail': 'The whole plan',
      'intent': {'kind': 'plan-review', 'approve': 'Proceed'},
      'options': [
        {'label': 'Revise'},
        {'label': 'Proceed'},
      ],
    });
    expect(draft.complete, false);
    draft.choose('Revise');
    expect(draft.answer()['selected'], ['Revise']);
    draft.choose('Proceed');
    expect(draft.answer()['selected'], ['Proceed']);
  });

  test('UI draft restoration requires the same request, version and question batch', () {
    final question = <String, dynamic>{'id': 'details', 'question': 'Details'};
    final draft = QuestionAnswerDraft(question)
      ..write('  Preserve raw spacing  ');
    final store = QuestionDraftStore();
    store.save('request-a', 4, [draft]);
    final restored = store.restore('request-a', 4, [question])!;
    expect(restored.single.custom, '  Preserve raw spacing  ');
    restored.single.write('A separate copy');
    expect(
      store.restore('request-a', 4, [question])!.single.custom,
      '  Preserve raw spacing  ',
    );
    expect(store.restore('request-b', 4, [question]), isNull);
    expect(store.restore('request-a', 5, [question]), isNull);
    expect(
      store.restore('request-a', 4, [
        {'id': 'details', 'question': 'Changed question'},
      ]),
      isNull,
    );
    store.retainPending([]);
    expect(store.restore('request-a', 4, [question]), isNull);
  });
}
