import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'approvals_draft.dart';
import 'approvals_notifications.dart';
import 'chat_plan.dart';
import 'runtime.dart';
import 'ui.dart';

QuestionDraftStore _draftsFor(RuntimeController runtime) =>
    runtime.questionDrafts;

/// Both ordinary navigation and notification links open the same DSH requests.
class ApprovalsPage extends StatelessWidget {
  const ApprovalsPage({
    super.key,
    required this.runtime,
    this.requestId,
    this.requestVersion,
  });
  final RuntimeController runtime;
  final String? requestId;
  final int? requestVersion;

  @override
  Widget build(BuildContext context) => requestId == null
      ? _PendingRequests(runtime: runtime)
      : _RequestDetail(
          runtime: runtime,
          requestId: requestId!,
          requestVersion: requestVersion,
        );
}

class _PendingRequests extends StatefulWidget {
  const _PendingRequests({required this.runtime});
  final RuntimeController runtime;
  @override
  State<_PendingRequests> createState() => _PendingRequestsState();
}

class _PendingRequestsState extends State<_PendingRequests>
    with WidgetsBindingObserver {
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      await widget.runtime.refreshInteractions();
      if (widget.runtime.interactionsError == null) {
        _draftsFor(widget.runtime).retainPending(widget.runtime.interactions);
      }
      if (mounted) setState(() => error = null);
    } catch (failure) {
      if (mounted) setState(() => error = '无法读取待处理请求：$failure');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('授权与提问'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新待处理请求',
      onPressed: refresh,
    ),
    body: ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) => PocketList(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          const NotificationAccessCard(),
          if (error != null || widget.runtime.interactionsError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
              child: SelectableText(error ?? widget.runtime.interactionsError!),
            ),
          if (widget.runtime.interactions.isEmpty)
            PocketSection(
              children: [
                PocketRow(
                  icon: loading
                      ? Icons.hourglass_top_rounded
                      : Icons.check_circle_outline_rounded,
                  title: loading
                      ? '正在读取请求'
                      : error == null &&
                            widget.runtime.interactionsError == null
                      ? '当前没有待处理请求'
                      : '待处理状态暂不可用',
                  subtitle: '这里与通知、Web 使用同一份 DSH 请求。',
                ),
              ],
            ),
          if (widget.runtime.interactions.isNotEmpty)
            PocketSection(
              title: '等待你处理',
              children: [
                for (final request in widget.runtime.interactions)
                  PocketRow(
                    icon: request['kind'] == 'approval'
                        ? Icons.verified_user_outlined
                        : Icons.question_answer_outlined,
                    title: request['kind'] == 'approval'
                        ? '${request['toolName']}'
                        : _questionTitle(request),
                    subtitle:
                        '${request['kind'] == 'approval' ? '需要授权' : '需要回答'}'
                        ' · 会话 ${request['sessionId']}',
                    onTap: () => Navigator.push(
                      context,
                      PocketRoute<void>(
                        builder: (_) => ApprovalsPage(
                          runtime: widget.runtime,
                          requestId: request['id'] as String,
                          requestVersion: request['version'] as int,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('返回或关闭页面不会替你拒绝请求。请求的等待与取消由 DSH 管理。'),
          ),
        ],
      ),
    ),
  );
}

String _questionTitle(Json request) {
  final questions = request['questions'] as List? ?? [];
  return questions.isEmpty ? 'Agent 提问' : '${questions.first['question']}';
}

class _RequestDetail extends StatefulWidget {
  const _RequestDetail({
    required this.runtime,
    required this.requestId,
    required this.requestVersion,
  });
  final RuntimeController runtime;
  final String requestId;
  final int? requestVersion;
  @override
  State<_RequestDetail> createState() => _RequestDetailState();
}

class _RequestDetailState extends State<_RequestDetail>
    with WidgetsBindingObserver {
  Json? lastRequest;
  int? version;
  final drafts = <QuestionAnswerDraft>[];
  bool available = false;
  bool loading = true;
  bool sending = false;
  bool submitted = false;
  bool uncertain = false;
  bool engaged = false;
  bool hasLocalEdits = false;
  bool notificationDraftRead = false;
  int refreshEpoch = 0;
  int replyEpoch = 0;
  String? error;
  String? status;

  bool get canReply =>
      available &&
      !sending &&
      !submitted &&
      !uncertain &&
      (version == null ||
          !_draftsFor(widget.runtime)
              .submissionBlocked(widget.requestId, version!)) &&
      widget.runtime.interactionsError == null;

  @override
  void initState() {
    super.initState();
    version = widget.requestVersion;
    widget.runtime.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    synchronize();
    unawaited(refresh());
  }

  void synchronize() {
    Json? match;
    for (final request in widget.runtime.interactions) {
      if (request['id'] == widget.requestId &&
          (version == null || request['version'] == version)) {
        match = request;
        break;
      }
    }
    available = match != null;
    if (match == null) {
      if (lastRequest != null &&
          version != null &&
          widget.runtime.interactionsError == null) {
        _draftsFor(widget.runtime).remove(widget.requestId, version!);
      }
      return;
    }
    version ??= match['version'] as int;
    if (!sending && !submitted) {
      final evidence = _draftsFor(widget.runtime)
          .submissionEvidence(widget.requestId, version!);
      if (evidence == SubmissionEvidence.unconfirmed) {
        uncertain = true;
        error ??= '此请求已有一次提交，结果尚未确认。刷新只能读取待处理状态，不能证明此前的答复未送达；请勿重复提交。';
      } else if (evidence == SubmissionEvidence.accepted) {
        submitted = true;
        status ??= '操作已发送，等待 DSH 完成处理。';
      }
    }
    if (lastRequest == null && match['kind'] == 'question') {
      final questions = (match['questions'] as List).cast<Json>();
      final restored = _draftsFor(widget.runtime)
          .restore(widget.requestId, version!, questions);
      drafts.addAll(restored ?? questions.map(QuestionAnswerDraft.new));
      hasLocalEdits = restored != null;
    }
    lastRequest = match;
  }

  void changed() {
    if (mounted) setState(synchronize);
  }

  Future<void> refresh() async {
    final currentRefresh = ++refreshEpoch;
    final replyAtStart = replyEpoch;
    final startedDuringSend = sending;
    try {
      await widget.runtime.refreshInteractions();
      if (!mounted || currentRefresh != refreshEpoch) return;
      setState(() {
        synchronize();
        // A pending snapshot does not prove a prior write was not delivered.
        // The same request/version remains blocked until the write itself
        // returns an explicit rejection, even after a process reconnect.
        if (replyAtStart == replyEpoch &&
            !startedDuringSend &&
            !uncertain &&
            !sending &&
            (version == null ||
                !_draftsFor(widget.runtime)
                    .submissionBlocked(widget.requestId, version!))) {
          error = null;
        }
      });
      if (available && hasLocalEdits && !engaged) beginEditing();
      await restoreNotificationDraft();
    } catch (failure) {
      if (mounted && currentRefresh == refreshEpoch) {
        setState(() => error = '无法核对请求状态：$failure\n当前输入已保留。');
      }
    } finally {
      if (mounted && currentRefresh == refreshEpoch) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> restoreNotificationDraft() async {
    if (notificationDraftRead ||
        hasLocalEdits ||
        !available ||
        drafts.length != 1 ||
        (drafts.single.question['options'] as List? ?? []).isNotEmpty) {
      return;
    }
    notificationDraftRead = true;
    try {
      final result = await widget.runtime.call('notifications.draft', {
        'id': widget.requestId,
        'version': version,
      }) as Json;
      if (!mounted || !available || hasLocalEdits) return;
      final text = result['text'];
      if (text is String && text.isNotEmpty) {
        setState(() {
          drafts.single.write(text);
          status = '已恢复通知中尚未提交成功的文字，请检查后提交。';
        });
      }
    } catch (failure) {
      if (mounted && !hasLocalEdits) {
        setState(() {
          notificationDraftRead = false;
          error = '通知中的草稿暂无法读取：$failure\n可刷新重试，已有输入不会被覆盖。';
        });
      }
    }
  }

  Future<void> waitAction(String action, {bool reportFailure = true}) async {
    final request = lastRequest;
    if (!available ||
        request == null ||
        request['kind'] != 'question' ||
        request['state'] != 'open' ||
        request['waitState'] == null) {
      return;
    }
    try {
      await widget.runtime.call('interactions.wait', {
        'id': widget.requestId,
        'version': version,
        'action': action,
      });
    } catch (failure) {
      // A released page cannot report focus errors; the DSH lifetime may have
      // already cancelled this request. No answer is sent on this path.
      if (reportFailure && mounted && available) {
        setState(() {
          if (action == 'engage') engaged = false;
          error = '无法更新等待状态：$failure\n输入已保留。';
        });
      }
    }
  }

  void beginEditing() {
    hasLocalEdits = true;
    _draftsFor(widget.runtime).save(widget.requestId, version!, drafts);
    if (engaged) return;
    engaged = true;
    unawaited(waitAction('engage'));
  }

  Future<void> reply(dynamic response) =>
      _submit('interactions.reply', response: response);

  Future<void> dismissPlan() => _submit('interactions.dismiss');

  Future<void> _submit(String method, {dynamic response}) async {
    if (!canReply) return;
    final submittedVersion = version!;
    if (!_draftsFor(widget.runtime)
        .beginSubmission(widget.requestId, submittedVersion)) {
      return;
    }
    ++replyEpoch;
    setState(() {
      sending = true;
      error = null;
      status = null;
    });
    try {
      final result = await widget.runtime.call(method, {
        'id': widget.requestId,
        'version': version,
        'response': ?response,
      }) as Json;
      final hidden =
          method == 'interactions.dismiss' &&
          result['accepted'] == true &&
          result['requestStillPending'] == true;
      final explicitlyRejected =
          result['accepted'] != true && result['requestStillPending'] == true;
      if (hidden || explicitlyRejected) {
        // A named dismissal or an explicit rejection sent no answer.
        _draftsFor(widget.runtime)
            .releaseRejectedSubmission(widget.requestId, submittedVersion);
      } else if (result['accepted'] == true) {
        _draftsFor(widget.runtime)
            .confirmSubmission(widget.requestId, submittedVersion);
      }
      if (!mounted) return;
      setState(() {
        if (hidden) {
          status = '计划仍等待决定；可返回会话提出修改意见。';
        } else if (result['accepted'] == true) {
          _draftsFor(widget.runtime).remove(widget.requestId, version!);
          submitted = true;
          status = '操作已发送，正在核对 DSH 状态。';
        } else if (result['requestStillPending'] != true) {
          _draftsFor(widget.runtime).remove(widget.requestId, version!);
          submitted = true;
          status = result['message'] as String? ?? '该请求已处理或撤回，没有重复发送答复。';
        } else {
          error = result['message'] as String? ?? 'DSH 尚未接受答复，输入已保留。';
        }
      });
      try {
        await widget.runtime.refreshInteractions();
        if (!mounted) return;
        setState(() {
          synchronize();
          if (result['accepted'] == true && !hidden) {
            status = available ? '答复已提交，等待 DSH 完成处理。' : '答复已提交。';
          }
        });
        if (hidden && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      } catch (failure) {
        if (mounted) {
          setState(() {
            uncertain = true;
            error = '答复结果已返回，但无法刷新请求状态：$failure\n输入已保留，请刷新核对。';
          });
        }
      }
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        uncertain = true;
        error = '答复未得到确认：$failure\n输入已保留，正在核对请求状态。';
      });
      try {
        await widget.runtime.refreshInteractions();
        if (!mounted) return;
        setState(() {
          synchronize();
          uncertain = true;
          error = available
              ? '答复结果尚未确认：$failure\n当前请求仍显示待处理，但这不能证明先前的答复未送达。输入已保留，请勿重复提交。'
              : '答复结果尚未确认：$failure\n请求已处理或撤回，当前输入未再次发送。';
        });
      } catch (refreshFailure) {
        if (mounted) {
          setState(
            () => error =
                '答复结果暂不确定：$failure\n'
                '无法核对请求状态：$refreshFailure\n输入已保留，请先刷新核对，避免重复发送。',
          );
        }
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  void answerQuestions() {
    try {
      unawaited(reply(questionDraftAnswer(drafts)));
    } on IncompleteQuestionDraft catch (failure) {
      setState(() => error = '$failure');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(waitAction('releaseFocus', reportFailure: false));
    }
  }

  @override
  void dispose() {
    widget.runtime.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(waitAction('releaseFocus', reportFailure: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = lastRequest;
    final approval = request?['kind'] == 'approval';
    final planReview = request?['kind'] == 'question'
        ? planReviewOf(drafts)
        : null;
    final preview = planReview == null
        ? null
        : planReviewPreview(planReview.plan);
    return PocketScaffold(
      title: Text(approval ? '授权请求' : 'Agent 提问'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '核对请求状态',
        onPressed: sending ? null : refresh,
      ),
      bottom: request == null
          ? null
          : approval
          ? Row(
              children: [
                Expanded(
                  child: PocketButton.tonal(
                    onPressed: canReply ? () => reply('rejected') : null,
                    child: const Text('拒绝'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PocketButton(
                    onPressed: canReply ? () => reply('allowed-once') : null,
                    child: Text(sending ? '正在提交' : '允许一次'),
                  ),
                ),
              ],
            )
          : planReview != null
          ? Row(
              children: [
                Expanded(
                  child: PocketButton.tonal(
                    onPressed: canReply ? dismissPlan : null,
                    child: const Text('请求修改'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PocketButton(
                    onPressed: canReply
                        ? () => reply({
                            'answers': [
                              {
                                'id': planReview.id,
                                'selected': [planReview.approve],
                              },
                            ],
                          })
                        : null,
                    child: Text(sending ? '正在提交' : '批准计划'),
                  ),
                ),
              ],
            )
          : PocketButton(
              onPressed: canReply && drafts.isNotEmpty ? answerQuestions : null,
              child: Text(sending ? '正在提交' : '提交回答'),
            ),
      body: PocketList(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          if (error != null || widget.runtime.interactionsError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
              child: SelectableText(
                error ?? widget.runtime.interactionsError!,
                key: const Key('interaction-error'),
              ),
            ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
              child: Text(status!, key: const Key('interaction-status')),
            ),
          if (!available &&
              !loading &&
              !submitted &&
              error == null &&
              widget.runtime.interactionsError == null)
            const PocketSection(
              children: [
                PocketRow(
                  icon: Icons.check_circle_outline_rounded,
                  title: '请求已处理、撤回或此通知已失效',
                  subtitle: '不会从旧通知重新授权或再次提交。当前草稿仅供查看。',
                ),
              ],
            ),
          if (request == null && loading)
            const PocketSection(
              children: [
                PocketRow(icon: Icons.hourglass_top_rounded, title: '正在读取请求'),
              ],
            ),
          if (request != null) ...[
            PocketSection(
              title: approval ? '${request['toolName']}' : '请求详情',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (approval) ...[
                        SelectableText(_approvalReason(context, request)),
                        if (request['reason'] is String &&
                            request['reason'] !=
                                _approvalReason(context, request))
                          PocketDisclosure(
                            title: '原始请求原因',
                            child: SelectableText(request['reason'] as String),
                          ),
                        const SizedBox(height: 16),
                      ],
                      SelectableText('会话：${request['sessionId']}'),
                      if (request['callId'] != null)
                        SelectableText('工具调用：${request['callId']}'),
                      if (approval && request['toolCall'] != null)
                        PocketDisclosure(
                          title: '完整工具调用参数',
                          child: SelectableText(
                            const JsonEncoder.withIndent('  ')
                                .convert(request['toolCall']),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      if (approval && request['toolCall'] == null)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text('此请求尚未提供工具参数。'),
                        ),
                      if (!approval) ...[
                        const SizedBox(height: 12),
                        Text(_waitDescription(request)),
                        if (request['countdown'] != null &&
                            !const [
                              'waiting',
                              'editing',
                              'continued',
                            ].contains(request['waitState']))
                          PocketButton.tonal(
                            onPressed: canReply
                                ? () => waitAction('takeTime')
                                : null,
                            child: const Text('需要更多时间'),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (planReview != null)
              PocketSection(
                title: '计划审核',
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 10, 22, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          preview!.title.isEmpty
                              ? drafts.single.question['question'] as String
                              : preview.title,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (preview.summary.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            preview.summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 12),
                        PocketButton.tonal(
                          onPressed: () => Navigator.of(context).push<void>(
                            PocketRoute(
                              builder: (_) => ChatPlanDocumentPage(
                                title:
                                    drafts.single.question['question']
                                        as String,
                                markdown: planReview.plan,
                                sessionId: request['sessionId'] as String?,
                              ),
                            ),
                          ),
                          child: const Text('单独查看完整计划'),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            else if (!approval)
              Focus(
                onFocusChange: (focused) {
                  unawaited(
                    waitAction(
                      focused ? 'holdFocus' : 'releaseFocus',
                      reportFailure: focused,
                    ),
                  );
                },
                child: Column(
                  children: [
                    for (final draft in drafts)
                      _QuestionInput(
                        key: ValueKey(draft.id),
                        draft: draft,
                        enabled: canReply,
                        onEdit: () {
                          beginEditing();
                          setState(() => error = null);
                        },
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

String _approvalReason(BuildContext context, Json request) {
  final display = request['displayReason'];
  if (display is Map) {
    final locale = Localizations.localeOf(context);
    final localized =
        display[locale.toLanguageTag()] ??
        display[locale.languageCode] ??
        display['en'];
    if (localized is String && localized.isNotEmpty) return localized;
  }
  return request['reason'] as String? ?? 'DSH 请求你决定是否允许此次操作。';
}

String _waitDescription(Json request) {
  if (request['state'] == 'continued') {
    return 'Agent 已继续执行，答复将作为后续消息送入同一会话。';
  }
  if (request['waitState'] == 'editing' || request['waitState'] == 'waiting') {
    return 'DSH 正在等待你的回答。';
  }
  final countdown = request['countdown'];
  if (countdown is Map && countdown['remainingMs'] is num) {
    final seconds = (countdown['remainingMs'] as num) / 1000;
    return 'DSH 等待时间：约 ${seconds.ceil()} 秒'
        '${countdown['running'] == true ? '' : '（已暂停）'}';
  }
  return '等待你的回答；等待状态由 DSH 管理。';
}

class _QuestionInput extends StatefulWidget {
  const _QuestionInput({
    super.key,
    required this.draft,
    required this.enabled,
    required this.onEdit,
  });
  final QuestionAnswerDraft draft;
  final bool enabled;
  final VoidCallback onEdit;
  @override
  State<_QuestionInput> createState() => _QuestionInputState();
}

class _QuestionInputState extends State<_QuestionInput> {
  late final custom = TextEditingController(text: widget.draft.custom);
  @override
  void didUpdateWidget(_QuestionInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (custom.text != widget.draft.custom) {
      custom.value = TextEditingValue(
        text: widget.draft.custom,
        selection: TextSelection.collapsed(offset: widget.draft.custom.length),
      );
    }
  }

  @override
  void dispose() {
    custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final question = draft.question;
    final intent = question['intent'] as Map?;
    final plan = intent?['kind'] == 'plan-review';
    final options = question['options'] as List? ?? [];
    return PocketSection(
      title: question['header'] as String? ?? (plan ? '计划审核' : null),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                question['question'] as String,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (question['detail'] is String) ...[
                const SizedBox(height: 16),
                SelectableText(question['detail'] as String),
              ],
              if (options.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(draft.multiSelect ? '可选择多项，也可补充文字。' : '选择一项，或填写自己的回答。'),
                const SizedBox(height: 8),
                for (final option in options)
                  Semantics(
                    selected: draft.selected.contains(option['label']),
                    child: PocketTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              recommendedOptionLabel(option['label'] as String)
                                  .label,
                            ),
                          ),
                          if (recommendedOptionLabel(option['label'] as String)
                              .recommended) ...[
                            const SizedBox(width: 8),
                            const Text('推荐', style: TextStyle(fontSize: 12)),
                          ],
                        ],
                      ),
                      subtitle: option['description'] is String
                          ? Text(option['description'] as String)
                          : null,
                      leading: Icon(
                        draft.selected.contains(option['label'])
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                      ),
                      trailing: plan && intent!['approve'] == option['label']
                          ? const Text('批准计划')
                          : null,
                      selected: draft.selected.contains(option['label']),
                      onTap: widget.enabled
                          ? () {
                              draft.choose(option['label'] as String);
                              custom.text = draft.custom;
                              widget.onEdit();
                            }
                          : null,
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: ValueKey('question-custom:${draft.id}'),
                controller: custom,
                enabled: widget.enabled,
                minLines: 2,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: options.isEmpty ? '你的回答' : '自定义回答',
                ),
                onChanged: (value) {
                  draft.write(value);
                  widget.onEdit();
                },
              ),
              const SizedBox(height: 8),
              if (draft.skipped) const Text('已明确跳过此问题；提交时将发送空回答。'),
              Align(
                alignment: Alignment.centerLeft,
                child: PocketButton.tonal(
                  onPressed: widget.enabled
                      ? () {
                          draft.skip();
                          custom.clear();
                          widget.onEdit();
                        }
                      : null,
                  child: const Text('跳过此问题'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
