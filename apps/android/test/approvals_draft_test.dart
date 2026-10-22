import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_android/approvals_draft.dart';

void main() {
  test('recommended first choice is a draft with the exact wire label', () {
    final draft = QuestionAnswerDraft({
      'id': 'scope',
      'question': 'Which scope?',
      'options': [
        {'label': 'Local (Recommended)'},
        {'label': 'Remote'},
      ],
    });
    expect(recommendedOptionLabel('Local (Recommended)'), (
      label: 'Local',
      recommended: true,
    ));
    expect(recommendedOptionLabel('本地（推荐）'), (label: '本地', recommended: true));
    expect(recommendedOptionLabel('Recommended'), (
      label: 'Recommended',
      recommended: false,
    ));
    expect(draft.answer(), {
      'id': 'scope',
      'selected': ['Local (Recommended)'],
    });
    draft.choose('Remote');
    expect(draft.answer()['selected'], ['Remote']);
  });

  test(
    'single choice and custom text replace one another without changing labels',
    () {
      final draft = QuestionAnswerDraft({
        'id': 'network-choice',
        'question': 'Which network?',
        'options': [
          {'label': 'Local'},
          {'label': 'LAN'},
        ],
      });
      expect(draft.complete, false);
      draft.choose('Local');
      expect(draft.answer(), {
        'id': 'network-choice',
        'selected': ['Local'],
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

  test(
    'plan review narrows only a valid original intent and keeps the full plan',
    () {
      final plan = '# Launch plan\n\nInspect files\nThen change code';
      final draft = QuestionAnswerDraft({
        'id': 'review',
        'question': 'Review this plan',
        'detail': plan,
        'intent': {'kind': 'plan-review', 'approve': 'Proceed'},
        'options': [
          {'label': 'Revise'},
          {'label': 'Proceed'},
        ],
      });
      expect(planReviewOf([draft]), (
        id: 'review',
        approve: 'Proceed',
        plan: plan,
      ));
      expect(planReviewPreview(plan), (
        title: 'Launch plan',
        summary: 'Inspect files Then change code',
      ));
      expect(planReviewOf([draft, draft]), isNull);
      expect(
        planReviewOf([
          QuestionAnswerDraft({
            'id': 2,
            'question': 'Review',
            'detail': plan,
            'intent': {'kind': 'plan-review', 'approve': 'Proceed'},
            'options': [
              {'label': 'Proceed'},
            ],
          }),
        ]),
        isNull,
      );
    },
  );

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

  test('restoring a changed choice replaces the recommended default', () {
    final question = <String, dynamic>{
      'id': 'choice',
      'question': 'Choose',
      'options': [
        {'label': 'A (Recommended)'},
        {'label': 'B'},
      ],
    };
    final draft = QuestionAnswerDraft(question)..choose('B');
    final store = QuestionDraftStore()..save('request', 1, [draft]);
    final restored = store.restore('request', 1, [question])!.single;
    expect(restored.selected, ['B']);
    expect(restored.answer()['selected'], ['B']);
  });

  test(
    'an attempted write stays blocked through snapshots and draft pruning',
    () {
      final store = QuestionDraftStore();
      expect(store.beginSubmission('request', 1), true);
      expect(store.beginSubmission('request', 1), false);
      expect(store.submissionBlocked('request', 1), true);
      store.retainPending([]);
      expect(store.submissionBlocked('request', 1), true);
      expect(store.beginSubmission('request', 2), true);
      store.confirmSubmission('request', 2);
      expect(
        store.submissionEvidence('request', 2),
        SubmissionEvidence.accepted,
      );
      store.releaseRejectedSubmission('request', 1);
      expect(store.beginSubmission('request', 1), true);
      expect(store.submissionBlocked('request', 2), true);
    },
  );
}
