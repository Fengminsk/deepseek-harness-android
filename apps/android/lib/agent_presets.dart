import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'agent_presets_data.dart';
import 'models.dart' show ModelDraftGuard;
import 'runtime.dart';
import 'ui.dart';
import 'text_document_page.dart';

/// Native management and selection over the original DSH preset registry.
class AgentPresetsPage extends StatefulWidget {
  const AgentPresetsPage({required this.runtime, this.sessionId, super.key});

  final RuntimeController runtime;
  final String? sessionId;

  @override
  State<AgentPresetsPage> createState() => _AgentPresetsPageState();
}

class _AgentPresetsPageState extends State<AgentPresetsPage>
    with WidgetsBindingObserver {
  late AgentPresetsController controller;

  void _connect() {
    controller = AgentPresetsController(
      widget.runtime,
      sessionId: widget.sessionId,
    );
    unawaited(controller.load());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connect();
  }

  @override
  void didUpdateWidget(AgentPresetsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.sessionId != widget.sessionId) {
      controller.dispose();
      _connect();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(controller.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  String _label(String? id) {
    if (id == null) {
      if (!controller.fresh) return '尚未确认';
      return controller.isSession ? '未使用预设' : '暂无默认预设';
    }
    for (final option in controller.options) {
      if (option.id == id) return option.label;
    }
    return id;
  }

  String get _applyLabel {
    if (controller.busy) return '正在应用…';
    if (!widget.runtime.ready) return '等待本地服务';
    if (controller.loading) return '正在读取预设…';
    if (controller.uncertain) return '请先刷新确认结果';
    if (controller.conflict) return '请先核对变更';
    if (!controller.fresh) return '请先刷新预设';
    if (controller.draftId == null) return '请选择预设';
    if (!controller.hasDraft) {
      return controller.isSession ? '已是当前预设' : '已是默认预设';
    }
    return controller.isSession ? '应用到此会话' : '设为默认预设';
  }

  void _view(AgentPresetOption option) {
    unawaited(
      Navigator.of(context).push<void>(
        PocketRoute<void>(
          builder: (_) =>
              AgentPresetDocumentPage(controller: controller, option: option),
        ),
      ),
    );
  }

  Widget _option(AgentPresetOption option) {
    final selected = controller.draftId == option.id;
    final labels = [
      if (option.description?.trim().isNotEmpty == true) option.description!,
      if (!option.available) '暂不可用',
      if (option.isDefault) '默认预设',
      if (controller.isSession &&
          controller.sessionExists &&
          controller.appliedId == option.id)
        '当前会话使用',
      if (selected && controller.hasDraft) '已选择 · 待应用',
    ];
    return Semantics(
      selected: selected,
      child: PocketTile(
        key: ValueKey('agent-preset-${option.id}'),
        selected: selected,
        leading: Icon(
          !option.available
              ? Icons.error_outline_rounded
              : selected
              ? Icons.check_circle_rounded
              : Icons.circle_outlined,
        ),
        title: Text(option.label),
        subtitle: labels.isEmpty ? null : Text(labels.join('\n')),
        onTap: controller.canChoose && option.available
            ? () => controller.select(option.id)
            : null,
        trailing: GlassButton(
          key: ValueKey('agent-preset-document-${option.id}'),
          icon: Icons.code_rounded,
          label: '查看 ${option.label} 的声明',
          onPressed: () => _view(option),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final started = controller.isSession && controller.sessionStarted == true;
      final visible = controller.options.where(
        (option) =>
            controller.codingToolsEnabled || !option.requiresCodingTools,
      );
      final available = visible.where((option) => option.available);
      final unavailable = controller.options.where(
        (option) =>
            !option.available &&
            (controller.codingToolsEnabled || !option.requiresCodingTools),
      );
      return ModelDraftGuard(
        hasEdits: () => controller.hasDraft,
        busy: controller.busy,
        child: PocketScaffold(
          title: Text(controller.isSession ? '会话预设' : 'Agent 预设'),
          trailing: GlassButton(
            icon: Icons.refresh_rounded,
            label: '刷新 Agent 预设',
            onPressed: controller.loading || controller.busy
                ? null
                : controller.refresh,
          ),
          bottom: started
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (controller.hasDraft)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                        child: Text(
                          '待应用 · ${_label(controller.draftId)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    PocketButton(
                      key: const ValueKey('apply-agent-preset'),
                      onPressed: controller.canApply ? controller.apply : null,
                      child: Text(_applyLabel),
                    ),
                  ],
                ),
          body: PocketList(
            padding: const EdgeInsets.all(20),
            children: [
              if (controller.loading && controller.options.isEmpty)
                const _PresetNotice('正在读取 Agent 预设…'),
              for (final message in [controller.error, controller.notice])
                if (message != null) _PresetNotice(message),
              if (!controller.loading &&
                  !controller.fresh &&
                  controller.error == null)
                const _PresetNotice('状态尚未确认，刷新后再应用。'),
              PocketSection(
                title: controller.isSession
                    ? controller.fresh && !controller.sessionExists
                          ? '新会话'
                          : '当前会话'
                    : '默认预设',
                children: [
                  PocketRow(
                    key: const ValueKey('applied-agent-preset'),
                    icon: started
                        ? Icons.lock_outline_rounded
                        : Icons.auto_awesome_outlined,
                    title: _label(controller.appliedId),
                    subtitle: started
                        ? '此会话已开始，预设不能再切换。'
                        : controller.isSession
                        ? '开始首次对话前可以选择预设。'
                        : '用于之后创建的会话。',
                  ),
                ],
              ),
              if (controller.uncertain)
                PocketSection(
                  title: '核对应用结果',
                  children: [
                    const _PresetNotice('你的选择仍保留。核对当前预设后，可以采用当前结果。'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          PocketButton.tonal(
                            onPressed: controller.loading || controller.busy
                                ? null
                                : controller.refresh,
                            child: const Text('继续核对'),
                          ),
                          PocketButton.tonal(
                            onPressed: controller.fresh && !controller.busy
                                ? controller.discardDraft
                                : null,
                            child: const Text('采用当前预设'),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              else if (controller.conflict)
                PocketSection(
                  title: '预设已变化',
                  children: [
                    const _PresetNotice('最新状态已读取，你的选择仍保留。'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          PocketButton.tonal(
                            onPressed: controller.fresh && !controller.busy
                                ? controller.rebaseDraft
                                : null,
                            child: const Text('保留我的选择'),
                          ),
                          PocketButton.tonal(
                            onPressed: controller.busy
                                ? null
                                : controller.discardDraft,
                            child: const Text('采用当前预设'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              if (available.isNotEmpty)
                PocketSection(
                  title: started ? '预设目录' : '可用预设',
                  divided: true,
                  children: available.map(_option).toList(),
                ),
              if (unavailable.isNotEmpty)
                PocketSection(
                  title: '暂不可用',
                  divided: true,
                  children: unavailable.map(_option).toList(),
                ),
              if (controller.fresh && controller.options.isEmpty)
                const _PresetNotice('当前服务未提供 Agent 预设。'),
            ],
          ),
        ),
      );
    },
  );
}

/// A read-only entry for an unstarted conversation; loading never creates it.
class SessionPresetChip extends StatefulWidget {
  const SessionPresetChip({
    required this.runtime,
    required this.sessionId,
    super.key,
  });

  final RuntimeController runtime;
  final String sessionId;

  @override
  State<SessionPresetChip> createState() => _SessionPresetChipState();
}

class _SessionPresetChipState extends State<SessionPresetChip> {
  late AgentPresetsController controller;

  void _connect() {
    controller = AgentPresetsController(
      widget.runtime,
      sessionId: widget.sessionId,
    );
    unawaited(controller.load());
  }

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didUpdateWidget(SessionPresetChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.sessionId != widget.sessionId) {
      controller.dispose();
      _connect();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    await Navigator.of(context).push<void>(
      PocketRoute<void>(
        builder: (_) => AgentPresetsPage(
          runtime: widget.runtime,
          sessionId: widget.sessionId,
        ),
      ),
    );
    if (mounted) await controller.refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (controller.fresh && controller.options.isEmpty) {
        return const SizedBox.shrink();
      }
      final id = controller.appliedId;
      String label = id ?? 'Agent 预设';
      for (final option in controller.options) {
        if (option.id == id) label = option.label;
      }
      return Align(
        child: PocketButton.tonal(
          key: const ValueKey('session-preset-chip'),
          glass: true,
          onPressed: _open,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome_outlined, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      );
    },
  );
}

/// The registry's declared composition is inspectable but cannot be edited here.
class AgentPresetDocumentPage extends StatefulWidget {
  const AgentPresetDocumentPage({
    required this.controller,
    required this.option,
    super.key,
  });

  final AgentPresetsController controller;
  final AgentPresetOption option;

  @override
  State<AgentPresetDocumentPage> createState() =>
      _AgentPresetDocumentPageState();
}

class _AgentPresetDocumentPageState extends State<AgentPresetDocumentPage> {
  AgentPresetDocument? document;
  String? error, notice;
  bool loading = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final current = ++generation;
    setState(() {
      loading = true;
      error = notice = null;
    });
    try {
      final value = await widget.controller.readDocument(widget.option.id);
      if (mounted && current == generation) setState(() => document = value);
    } catch (failure) {
      if (mounted && current == generation) {
        setState(() => error = '无法读取声明，请刷新重试。\n$failure');
      }
    } finally {
      if (mounted && current == generation) setState(() => loading = false);
    }
  }

  Future<void> _copy() async {
    final content = document?.content;
    if (content == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: content));
      if (mounted) setState(() => notice = '已复制声明');
    } catch (failure) {
      if (mounted) setState(() => notice = '复制失败，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('预设声明'),
    trailing: GlassButton(
      icon: Icons.copy_rounded,
      label: '复制预设声明',
      onPressed: document == null ? null : _copy,
    ),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        PocketSection(
          children: [
            PocketRow(
              icon: Icons.auto_awesome_outlined,
              title: document?.name?.trim().isNotEmpty == true
                  ? document!.name!
                  : widget.option.label,
              subtitle: document?.description ?? widget.option.description,
            ),
          ],
        ),
        if (widget.option.broken != null)
          PocketSection(
            children: [
              TextDocumentRow(title: '暂不可用的原因', text: widget.option.broken!),
            ],
          ),
        if (loading) const _PresetNotice('正在读取声明…'),
        if (error != null) ...[
          _PresetNotice(error!),
          PocketButton.tonal(
            onPressed: loading ? null : _load,
            child: const Text('重新读取'),
          ),
        ],
        if (notice != null) _PresetNotice(notice!),
        if (document != null) _PresetDocumentText(text: document!.content),
      ],
    ),
  );
}

class _PresetDocumentText extends StatefulWidget {
  const _PresetDocumentText({required this.text});
  final String text;
  @override
  State<_PresetDocumentText> createState() => _PresetDocumentTextState();
}

class _PresetDocumentTextState extends State<_PresetDocumentText> {
  late final input = TextEditingController(text: widget.text);
  @override
  void didUpdateWidget(_PresetDocumentText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) input.text = widget.text;
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextDocumentField(
    fieldKey: const ValueKey('agent-preset-document-content'),
    controller: input,
    readOnly: true,
    monospace: true,
  );
}

class _PresetNotice extends StatelessWidget {
  const _PresetNotice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
      child: Text(text),
    ),
  );
}
