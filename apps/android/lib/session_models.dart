import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'models.dart';
import 'models_data.dart';
import 'runtime.dart';
import 'ui.dart';

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
  Json? catalog, selection, appliedSelection;
  bool loading = true, busy = false;
  String? error, notice;
  int loadGeneration = 0, editGeneration = 0;
  bool get hasDraft => !mapEquals(selection, appliedSelection);

  void editSelection(Json next) => setState(() {
    selection = next;
    editGeneration++;
    notice = null;
  });

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    if (busy) return;
    final generation = ++loadGeneration;
    final startedAtEdit = editGeneration;
    final preserveDraft = hasDraft;
    setState(() => loading = true);
    try {
      await widget.runtime.ensureSession(widget.sessionId);
      final parts = await Future.wait([
        modelsApi(widget.runtime, 'session', 'modelCatalog'),
        modelsApi(widget.runtime, 'session', 'projections', {
          'request': {'sessionId': widget.sessionId},
        }),
      ]);
      if (!mounted || generation != loadGeneration) return;
      final projection = parts[1] as Json?;
      if (projection?['kind'] != 'sequenced') {
        throw const FormatException('会话模型状态尚未就绪');
      }
      final next = projection!['values']['modelSelection']?['next'] as Json?;
      setState(() {
        catalog = parts[0] as Json;
        appliedSelection = next == null ? null : Json.of(next);
        // Refreshing the server baseline must not discard an existing draft or
        // an edit made while the requests were in flight.
        if (!preserveDraft && startedAtEdit == editGeneration) {
          selection = next == null ? null : Json.of(next);
        }
        notice = hasDraft ? '已刷新会话状态，尚未应用的选择已保留。' : null;
        error = null;
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

  Future<void> apply() async {
    final selected = selection;
    if (busy || loading || selected == null) return;
    final submitted = Json.of(selected);
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final result = await modelsApi(widget.runtime, 'session', 'selectModel', {
        'request': {'sessionId': widget.sessionId, ...submitted},
      }) as Json;
      if (!mounted) return;
      final accepted = result['selected'] as Json;
      setState(() {
        appliedSelection = Json.of(accepted);
        selection = Json.of(accepted);
        notice = '已选择此会话后续请求使用的模型。';
      });
    } catch (failure) {
      if (mounted) setState(() => error = '切换结果未确认，选择已保留；可刷新核对：$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('会话模型'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新会话模型',
      onPressed: busy || loading ? null : load,
    ),
    bottom: PocketButton(
      onPressed: busy || loading || selection == null ? null : apply,
      child: Text(busy ? '正在应用' : '应用到当前会话'),
    ),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        if (loading) const ModelNotice('正在读取会话与模型目录…'),
        for (final text in [error, notice])
          if (text != null) ModelNotice(text),
        if (hasDraft) ...[
          ModelNotice(
            appliedSelection == null
                ? '当前会话尚未选择模型'
                : '当前会话：${appliedSelection!['provider']} / ${appliedSelection!['model']}'
                      '${appliedSelection!['reasoningEffort'] == null ? '' : ' · ${appliedSelection!['reasoningEffort']}'}',
          ),
          ModelNotice(
            '尚未应用：${selection?['provider']} / ${selection?['model']}'
            '${selection?['reasoningEffort'] == null ? '' : ' · ${selection!['reasoningEffort']}'}',
          ),
        ],
        for (final group in catalog?['groups'] as List? ?? [])
          PocketSection(
            title: '${group['name']}',
            children: [
              for (final model in group['models'] as List) ...[
                PocketTile(
                  title: Text('${model['name']}'),
                  subtitle: Text('${model['id']}'),
                  selected:
                      selection?['provider'] == group['id'] &&
                      selection?['model'] == model['id'],
                  onTap: busy
                      ? null
                      : () => editSelection({
                          'provider': group['id'],
                          'model': model['id'],
                        }),
                ),
                if (selection?['provider'] == group['id'] &&
                    selection?['model'] == model['id'] &&
                    (model['reasoning']?['efforts'] as List? ?? []).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        PocketChoice(
                          label: const Text('服务商默认'),
                          selected: selection?['reasoningEffort'] == null,
                          onSelected: busy
                              ? null
                              : (_) => editSelection(
                                  Json.of(selection!)
                                    ..remove('reasoningEffort'),
                                ),
                        ),
                        for (final effort
                            in model['reasoning']['efforts'] as List)
                          PocketChoice(
                            label: Text('${effort['name']}'),
                            selected:
                                selection?['reasoningEffort'] == effort['id'],
                            onSelected: busy
                                ? null
                                : (_) => editSelection({
                                    ...selection!,
                                    'reasoningEffort': effort['id'],
                                  }),
                          ),
                      ],
                    ),
                  ),
              ],
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
  );
}
