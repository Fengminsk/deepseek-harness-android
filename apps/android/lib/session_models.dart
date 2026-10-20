import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'models.dart';
import 'models_data.dart';
import 'runtime.dart';
import 'ui.dart';

/// Uses the original Session selection and the catalog default for blank Sessions.
class SessionModelPage extends StatefulWidget {
  const SessionModelPage({
    super.key,
    required this.runtime,
    required this.sessionId,
  });
  final RuntimeController runtime;
  final String sessionId;
  @override
  State<SessionModelPage> createState() => _SessionModelPageState();
}

class _SessionModelPageState extends State<SessionModelPage> {
  Json? catalog, selection, appliedSelection, modelView;
  Json? unconfirmedSelection;
  StreamSubscription<Json>? observation;
  bool loading = true, busy = false, conflict = false, uncertain = false;
  String? error, notice, syncError;
  int loadGeneration = 0, watchGeneration = 0, projectionSeq = -1;
  bool get hasDraft => !mapEquals(selection, appliedSelection);
  bool get inherited => modelView?['next'] == null;
  List<Json> get groups => (catalog?['groups'] as List? ?? []).cast<Json>();

  Json? modelFor(Json? pick) {
    for (final group in groups) {
      if (group['id'] != pick?['provider']) continue;
      for (final model in (group['models'] as List).cast<Json>()) {
        if (model['id'] == pick?['model']) return model;
      }
    }
    return null;
  }

  bool sameRoute(Json? left, Json? right) =>
      left != null &&
      right != null &&
      left['provider'] == right['provider'] &&
      left['model'] == right['model'];

  String label(Json? pick) {
    if (pick == null) return '尚未取得会话模型';
    return '${modelFor(pick)?['name'] ?? pick['model']}'
        '${pick['reasoningEffort'] == null ? '' : ' · ${effortLabel(pick)}'}';
  }

  String effortLabel(Json pick) {
    for (final level
        in modelFor(pick)?['reasoning']?['efforts'] as List? ?? []) {
      if (level['id'] == pick['reasoningEffort']) return '${level['name']}';
    }
    return '${pick['reasoningEffort']}';
  }

  String route(Json pick) => '${pick['provider']} / ${pick['model']}';

  bool sameEffectiveSelection(Json? left, Json? right) {
    if (!sameRoute(left, right)) return false;
    final fallback = modelFor(left)?['reasoning']?['defaultEffort'];
    return (left!['reasoningEffort'] ?? fallback) ==
        (right!['reasoningEffort'] ?? fallback);
  }

  Json checkedSelection(dynamic value) {
    if (value is! Json ||
        value['provider'] is! String ||
        value['model'] is! String ||
        (value['provider'] as String).isEmpty ||
        (value['model'] as String).isEmpty ||
        (value['reasoningEffort'] != null &&
            value['reasoningEffort'] is! String)) {
      throw const FormatException('会话模型数据不完整');
    }
    return Json.of(value);
  }

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<Json> readProjection() async {
    final value = await modelsApi(widget.runtime, 'session', 'projections', {
      'request': {'sessionId': widget.sessionId},
    });
    if (value is! Json ||
        value['kind'] != 'sequenced' ||
        value['values']?['modelSelection'] is! Json) {
      throw const FormatException('会话模型状态尚未就绪，请刷新重试');
    }
    return value;
  }

  void acceptProjection(Json value) => acceptModelView(
    value['values']['modelSelection'] as Json,
    value['asOfSeq'] as int,
  );

  // Sequence comparisons apply only within one control-stream generation.
  // A local draft remains distinct from authoritative Session state.
  void acceptModelView(Json view, int seq) {
    if (seq < projectionSeq) return;
    final next = view['next'];
    if (next != null) checkedSelection(next);
    final oldApplied = appliedSelection;
    final keepDraft = hasDraft;
    projectionSeq = seq;
    modelView = view;
    final effective = next ?? catalog?['default'];
    if (effective == null) return;
    appliedSelection = checkedSelection(effective);
    if (!keepDraft) {
      selection = Json.of(appliedSelection!);
    } else if (mapEquals(selection, appliedSelection)) {
      conflict = false;
      uncertain = false;
    } else if (!mapEquals(oldApplied, appliedSelection)) {
      conflict = true;
    }
  }

  Future<void> watch() async {
    final generation = ++watchGeneration;
    await observation?.cancel();
    if (!mounted || generation != watchGeneration) return;
    observation = widget.runtime
        .watchApi('session', 'control')
        .listen(
          (frame) {
            if (!mounted || generation != watchGeneration) return;
            try {
              setState(() {
                if (frame['type'] == 'opening') {
                  projectionSeq = -1;
                } else if (frame['type'] == 'disconnected') {
                  syncError = '实时同步已断开，选择会保留；应用前会重新核对。';
                } else if (frame['type'] == 'item') {
                  final value = frame['value'] as Json;
                  if (value['type'] == 'baseline') {
                    final baseline =
                        value['value']['projections'][widget.sessionId]
                            as Json?;
                    final projected =
                        baseline?['values']?['modelSelection'] as Json?;
                    if (projected != null) {
                      acceptModelView(projected, baseline!['asOfSeq'] as int);
                    }
                  } else if (value['type'] == 'projection' &&
                      value['sessionId'] == widget.sessionId &&
                      value['key'] == 'modelSelection') {
                    acceptModelView(
                      value['value'] as Json,
                      value['seq'] as int,
                    );
                  }
                  syncError = null;
                }
              });
            } catch (failure) {
              setState(() => syncError = '无法同步会话模型，应用前会重新核对：$failure');
            }
          },
          onError: (Object failure) {
            if (mounted && generation == watchGeneration) {
              setState(() => syncError = '实时同步不可用，应用前会重新核对：$failure');
            }
          },
          onDone: () {
            if (mounted && generation == watchGeneration) {
              setState(() => syncError ??= '实时同步已结束，可刷新重新连接。');
            }
          },
        );
  }

  Future<void> load() async {
    if (busy) return;
    final generation = ++loadGeneration;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final ensured = await widget.runtime.ensureSession(widget.sessionId);
      if (ensured['sessionId'] != widget.sessionId) {
        throw const FormatException('会话标识已变化，请重新打开此会话');
      }
      if (!mounted || generation != loadGeneration) return;
      if (observation == null || syncError != null) await watch();
      if (!mounted || generation != loadGeneration) return;
      final parts = await Future.wait([
        modelsApi(widget.runtime, 'session', 'modelCatalog'),
        readProjection(),
      ]);
      if (!mounted || generation != loadGeneration) return;
      final directory = parts[0] as Json;
      checkedSelection(directory['default']);
      setState(() {
        catalog = directory;
        acceptProjection(parts[1] as Json);
        // A newer stream frame may have arrived before the catalog.
        if (modelView != null) acceptModelView(modelView!, projectionSeq);
        if (unconfirmedSelection != null &&
            mapEquals(selection, unconfirmedSelection) &&
            sameEffectiveSelection(appliedSelection, unconfirmedSelection)) {
          selection = Json.of(appliedSelection!);
          conflict = false;
        }
        unconfirmedSelection = null;
        uncertain = false;
        notice = hasDraft ? '尚未应用的选择已保留。' : '已核对当前会话模型。';
      });
    } catch (failure) {
      if (mounted && generation == loadGeneration) {
        setState(() => error = '无法读取会话模型，选择已保留：$failure');
      }
    } finally {
      if (mounted && generation == loadGeneration) {
        setState(() => loading = false);
      }
    }
  }

  void choose(Json next) => setState(() {
    selection = next;
    notice = null;
    if (!hasDraft) conflict = false;
  });

  Future<void> apply() async {
    if (!canApply) return;
    final submitted = Json.of(selection!);
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    Json? accepted;
    var submittedToService = false;
    try {
      // The original API has no compare-and-set field. Refuse an observed
      // conflicting edit before submitting, and verify the current result.
      final before = await readProjection();
      if (!mounted) return;
      setState(() => acceptProjection(before));
      if (conflict) return;
      if (!hasDraft) {
        setState(() => notice = '会话状态已确认此选择，无需重复应用。');
        return;
      }
      submittedToService = true;
      unconfirmedSelection = submitted;
      final result = await modelsApi(widget.runtime, 'session', 'selectModel', {
        'request': {'sessionId': widget.sessionId, ...submitted},
      }) as Json;
      accepted = checkedSelection(result['selected']);
      if (!mounted) return;
      final after = await readProjection();
      if (!mounted) return;
      setState(() {
        acceptProjection(after);
        if (mapEquals(appliedSelection, accepted)) {
          selection = Json.of(accepted!);
          conflict = false;
          unconfirmedSelection = null;
          notice = '已应用。此会话的后续请求将使用 ${label(accepted)}。';
        } else {
          conflict = true;
          notice = '服务已接受选择，但会话随后又发生变化。你的选择已保留，请比较后继续。';
        }
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          uncertain = submittedToService;
          error = !submittedToService
              ? '无法核对最新会话状态，本次尚未提交。选择已保留，请刷新后重试：$failure'
              : accepted == null
              ? '切换结果未确认，选择已保留。请刷新核对后再操作：$failure'
              : '服务已接受选择，但最新会话状态尚未核对。请刷新确认：$failure';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool get canApply =>
      !busy &&
      !loading &&
      !conflict &&
      !uncertain &&
      modelView != null &&
      hasDraft &&
      modelFor(selection) != null;

  String get buttonLabel {
    if (busy) return '正在核对并应用…';
    if (loading) return '正在读取模型…';
    if (uncertain) return '请先刷新确认结果';
    if (conflict) return '请先处理会话变更';
    if (selection == null) return '请先选择模型';
    if (modelFor(selection) == null) return '请选择可用模型';
    return hasDraft ? '应用此模型' : '已是当前模型';
  }

  @override
  void dispose() {
    watchGeneration++;
    loadGeneration++;
    unawaited(observation?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel = modelFor(selection);
    final reasoning = selectedModel?['reasoning'] as Json?;
    final efforts = (reasoning?['efforts'] as List? ?? []).cast<Json>();
    return ModelDraftGuard(
      hasEdits: () => hasDraft,
      busy: busy,
      child: PocketScaffold(
        title: const Text('会话模型'),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '刷新会话模型',
          onPressed: busy || loading ? null : load,
        ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasDraft && selection != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                child: Text(
                  '待应用 · ${label(selection)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            PocketButton(
              key: const ValueKey('apply-session-model'),
              onPressed: canApply ? apply : null,
              child: Text(buttonLabel),
            ),
          ],
        ),
        body: PocketList(
          padding: const EdgeInsets.all(20),
          children: [
            if (loading) const ModelNotice('正在读取会话与模型目录…'),
            for (final text in [error, notice, syncError])
              if (text != null) ModelNotice(text),
            PocketSection(
              title: '当前会话',
              children: [
                PocketRow(
                  icon: Icons.check_circle_rounded,
                  title: label(appliedSelection),
                  subtitle: appliedSelection == null
                      ? '等待会话状态'
                      : '${route(appliedSelection!)}\n'
                            '${inherited ? '尚未单独设置，继承默认模型' : '已选择，供后续请求使用'}'
                            '${modelFor(appliedSelection) == null ? '\n此模型暂不在可用目录中，请选择其他模型或检查凭据。' : ''}',
                ),
                if (modelView?['lastUsed'] is Json &&
                    !mapEquals(
                      modelView!['lastUsed'] as Json,
                      appliedSelection,
                    ))
                  PocketRow(
                    icon: Icons.history_rounded,
                    title: '上次请求 · ${label(modelView!['lastUsed'] as Json)}',
                    subtitle: '正在进行的请求不会因切换模型而重启。',
                  ),
              ],
            ),
            if (conflict && !busy)
              PocketSection(
                title: '会话模型已变化',
                children: [
                  const ModelNotice('会话中的模型已变化。当前状态已更新，你尚未应用的选择仍保留。'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: PocketButton.tonal(
                      onPressed: busy
                          ? null
                          : () => setState(() => conflict = false),
                      child: const Text('保留我的选择，按最新状态继续'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: PocketButton.tonal(
                      onPressed: busy
                          ? null
                          : () => choose(Json.of(appliedSelection!)),
                      child: const Text('采用当前会话模型'),
                    ),
                  ),
                ],
              ),
            for (final failure in catalog?['failures'] as List? ?? [])
              ModelNotice('${failure['name']} 暂不可用：${failure['message']}'),
            if (!loading && catalog != null && groups.isEmpty)
              const ModelNotice('暂无可用模型。请先登录账号，或在服务商与凭据中完成配置，再刷新。'),
            for (final group in groups)
              PocketSection(
                title: '${group['name']}',
                children: [
                  for (final model in (group['models'] as List).cast<Json>())
                    modelTile(group, model),
                ],
              ),
            if (efforts.isNotEmpty)
              PocketSection(
                title: '推理强度',
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text('适用于 ${selectedModel!['name']}'),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        PocketChoice(
                          label: Text(
                            reasoning?['defaultEffort'] == null
                                ? '服务商默认'
                                : '默认 · ${effortLabel({...selection!, 'reasoningEffort': reasoning!['defaultEffort']})}',
                          ),
                          selected: selection?['reasoningEffort'] == null,
                          onSelected: busy
                              ? null
                              : (_) => choose(
                                  Json.of(selection!)
                                    ..remove('reasoningEffort'),
                                ),
                        ),
                        for (final effort in efforts)
                          PocketChoice(
                            label: Text('${effort['name']}'),
                            selected:
                                selection?['reasoningEffort'] == effort['id'],
                            onSelected: busy
                                ? null
                                : (_) => choose({
                                    ...selection!,
                                    'reasoningEffort': effort['id'],
                                  }),
                          ),
                      ],
                    ),
                  ),
                  for (final effort in efforts)
                    if (selection?['reasoningEffort'] == effort['id'] &&
                        effort['description'] != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                        child: Text('${effort['description']}'),
                      ),
                ],
              ),
            PocketButton.tonal(
              onPressed: busy || loading
                  ? null
                  : () async {
                      await Navigator.push(
                        context,
                        PocketRoute<void>(
                          builder: (_) => ModelsPage(runtime: widget.runtime),
                        ),
                      );
                      if (mounted) await load();
                    },
              child: const Text('管理服务商与凭据'),
            ),
          ],
        ),
      ),
    );
  }

  Widget modelTile(Json group, Json model) {
    final candidate = <String, dynamic>{
      'provider': group['id'],
      'model': model['id'],
    };
    final selected = sameRoute(selection, candidate);
    final current = sameRoute(appliedSelection, candidate);
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: PocketTile(
        key: ValueKey('session-model-${group['id']}-${model['id']}'),
        title: Text('${model['name']}'),
        subtitle: Text(
          '${model['id']}${current ? '\n当前会话使用' : ''}'
          '${selected && hasDraft ? '\n已选中 · 待应用' : ''}'
          '${model['description'] == null ? '' : '\n${model['description']}'}',
        ),
        selected: selected,
        trailing: Icon(
          selected
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          color: selected ? colors.primary : colors.outline,
          semanticLabel: selected ? '已选中' : '选择此模型',
        ),
        onTap: busy
            ? null
            : () {
                // Retapping the same model must not reset its reasoning choice.
                if (!selected) choose(candidate);
              },
      ),
    );
  }
}
