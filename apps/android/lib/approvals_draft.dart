import 'dart:convert';

import 'runtime.dart';

class IncompleteQuestionDraft implements Exception {
  const IncompleteQuestionDraft(this.questionId);
  final String questionId;
  @override
  String toString() => '请回答或明确跳过每个问题。';
}

/// Unsaved presentation state only. The DSH request owns whether it is pending.
class QuestionAnswerDraft {
  QuestionAnswerDraft(this.question) {
    final options = question['options'];
    if (options is List && options.isNotEmpty) {
      final first = options.first;
      if (first is Map && first['label'] is String) {
        final label = first['label'] as String;
        if (recommendedOptionLabel(label).recommended) selected.add(label);
      }
    }
  }
  final Json question;
  final List<String> selected = [];
  String custom = '';
  bool skipped = false;

  String get id => question['id'] as String;
  bool get multiSelect => question['multiSelect'] == true;
  bool get complete =>
      selected.isNotEmpty || custom.trim().isNotEmpty || skipped;

  void choose(String label) {
    if (!(question['options'] as List? ?? []).any(
      (option) => option['label'] == label,
    )) {
      throw ArgumentError.value(label, 'label', 'not an offered option');
    }
    skipped = false;
    if (multiSelect) {
      if (!selected.remove(label)) selected.add(label);
    } else {
      selected
        ..clear()
        ..add(label);
      custom = '';
    }
  }

  void write(String text) {
    skipped = false;
    custom = text;
    if (!multiSelect) selected.clear();
  }

  void skip() {
    skipped = true;
    selected.clear();
    custom = '';
  }

  Json answer() {
    if (!complete) throw IncompleteQuestionDraft(id);
    if (skipped) return {'id': id, 'selected': <String>[]};
    final text = custom.trim();
    return {
      'id': id,
      'selected': text.isEmpty || multiSelect
          ? List<String>.of(selected)
          : <String>[],
      if (text.isNotEmpty) 'custom': text,
    };
  }
}

/// Display a recommendation badge without changing the option label sent to DSH.
({String label, bool recommended}) recommendedOptionLabel(String label) {
  final suffix = RegExp(
    r'\s*(?:\((?:recommended|推荐)\)|（(?:recommended|推荐)）)\s*$',
    caseSensitive: false,
  );
  final match = suffix.firstMatch(label);
  return match == null
      ? (label: label, recommended: false)
      : (label: label.substring(0, match.start), recommended: true);
}

/// Echoes the original question ids and option labels without interpreting
/// their order, including plan-review options named by intent.approve.
Json questionDraftAnswer(List<QuestionAnswerDraft> drafts) => {
  'answers': drafts.map((draft) => draft.answer()).toList(),
};

/// Only the original single-question plan intent gets a dedicated decision UI.
({String id, String approve, String plan})? planReviewOf(
  List<QuestionAnswerDraft> drafts,
) {
  if (drafts.length != 1) return null;
  final question = drafts.single.question;
  final intent = question['intent'];
  final options = question['options'];
  if (intent is! Map ||
      intent['kind'] != 'plan-review' ||
      intent['approve'] is! String ||
      question['id'] is! String ||
      question['question'] is! String ||
      question['detail'] is! String ||
      question['multiSelect'] == true ||
      options is! List ||
      options.isEmpty ||
      options.length > 2 ||
      !options.any(
        (option) => option is Map && option['label'] == intent['approve'],
      )) {
    return null;
  }
  return (
    id: question['id'] as String,
    approve: intent['approve'] as String,
    plan: question['detail'] as String,
  );
}

/// Keep the full review document in the request; only this card's copy is brief.
({String title, String summary}) planReviewPreview(String markdown) {
  final lines = markdown.trim().split(RegExp(r'\r?\n'));
  final title = lines.first.replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '').trim();
  final summary = lines
      .skip(1)
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return (title: title, summary: summary);
}

/// Session-local UI progress and a guard against replaying an unconfirmed write.
/// Neither map decides whether DSH still owns a request. A pending read cannot
/// prove an earlier answer was not delivered. Only an explicit rejected write
/// or a confirmed panel-only dismissal releases the same request/version.
enum SubmissionEvidence { unconfirmed, accepted }

class QuestionDraftStore {
  final _entries = <String, ({String questions, List<Json> progress})>{};
  final _submissionAttempts = <String, SubmissionEvidence>{};

  String _key(String id, int version) => jsonEncode([id, version]);

  bool submissionBlocked(String id, int version) =>
      _submissionAttempts.containsKey(_key(id, version));

  SubmissionEvidence? submissionEvidence(String id, int version) =>
      _submissionAttempts[_key(id, version)];

  /// Called before crossing the native bridge. An exception or lost receipt
  /// leaves this entry blocked even if a later snapshot still shows pending.
  bool beginSubmission(String id, int version) {
    final key = _key(id, version);
    if (_submissionAttempts.containsKey(key)) return false;
    _submissionAttempts[key] = SubmissionEvidence.unconfirmed;
    return true;
  }

  void confirmSubmission(String id, int version) =>
      _submissionAttempts[_key(id, version)] = SubmissionEvidence.accepted;

  /// The bridge explicitly said it did not accept this write and the exact
  /// request is still pending. A read-only snapshot is never sufficient.
  void releaseRejectedSubmission(String id, int version) =>
      _submissionAttempts.remove(_key(id, version));

  void save(String id, int version, List<QuestionAnswerDraft> drafts) {
    _entries[_key(id, version)] = (
      questions: jsonEncode(drafts.map((draft) => draft.question).toList()),
      progress: [
        for (final draft in drafts)
          {
            'selected': List<String>.of(draft.selected),
            'custom': draft.custom,
            'skipped': draft.skipped,
          },
      ],
    );
  }

  List<QuestionAnswerDraft>? restore(
    String id,
    int version,
    List<Json> questions,
  ) {
    final entry = _entries[_key(id, version)];
    if (entry == null || entry.questions != jsonEncode(questions)) return null;
    return [
      for (var index = 0; index < questions.length; index++)
        QuestionAnswerDraft(questions[index])
          ..selected.clear()
          ..selected.addAll(
            (entry.progress[index]['selected'] as List).cast<String>(),
          )
          ..custom = entry.progress[index]['custom'] as String
          ..skipped = entry.progress[index]['skipped'] as bool,
    ];
  }

  void remove(String id, int version) => _entries.remove(_key(id, version));

  void retainPending(List<Json> requests) {
    final keys = {
      for (final request in requests)
        _key(request['id'] as String, request['version'] as int),
    };
    _entries.removeWhere((key, _) => !keys.contains(key));
    // A transient empty/replayed snapshot does not establish non-delivery.
    // Keep submission evidence even after pruning visual draft progress.
  }
}
