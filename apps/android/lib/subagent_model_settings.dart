import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
import 'configuration_state.dart';
import 'models.dart' show ModelDraftGuard, ModelNotice;
import 'runtime.dart';
import 'ui.dart';

const subagentModelSettingsNamespace = 'subagent-model-selection-settings';

/// Edits the original DSH exact-route authorization for newly created sessions.
class SubagentModelSettingsPage extends StatefulWidget {
  const SubagentModelSettingsPage({required this.runtime, super.key});

  final RuntimeController runtime;

  @override
  State<SubagentModelSettingsPage> createState() =>
      _SubagentModelSettingsPageState();
}

class _ModelRoute {
  const _ModelRoute(this.provider, this.model);
  final String provider, model;
  String get id => '$provider\u0000$model';
  Json toJson() => {'provider': provider, 'model': model};
}

class _Selection {
  _Selection(Json value) {
    if (value['enabled'] is! bool || value['allowedModels'] is! List) {
      throw const FormatException('模型选择配置不完整，请刷新后重试。');
    }
    enabled = value['enabled'] as bool;
    final seen = <String>{};
    final parsed = [
      for (final raw in value['allowedModels'] as List)
        if (raw is Map &&
            raw['provider'] is String &&
            (raw['provider'] as String).isNotEmpty &&
            raw['model'] is String &&
            (raw['model'] as String).isNotEmpty)
          _ModelRoute(raw['provider'] as String, raw['model'] as String)
        else
          throw const FormatException('配置中存在无效的模型标识，请先核对原配置。'),
    ];
    routes = [
      for (final route in parsed)
        if (seen.add(route.id)) route,
    ];
    duplicateCount = parsed.length - routes.length;
  }
  late final bool enabled;
  late final List<_ModelRoute> routes;
  late final int duplicateCount;
}

class _Candidate {
  const _Candidate({
    required this.route,
    required this.providerName,
    required this.modelName,
    required this.advertised,
  });
  final _ModelRoute route;
  final String providerName, modelName;
  final bool advertised;
}

class _SubagentModelSettingsPageState extends State<SubagentModelSettingsPage>
    with WidgetsBindingObserver {
  late ConfigurationEditingController controller;
  final search = TextEditingController();
  List<_Candidate> catalog = [];
  List<String> failures = [];
  bool catalogLoading = false, catalogFresh = false, catalogRequested = false;
  String? catalogError;
  int catalogRequest = 0;
  late int connection;
  late String phase;
  Object? forms;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connect();
  }

  void _connect() {
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    forms = widget.runtime.forms;
    controller = ConfigurationEditingController(
      widget.runtime,
      namespace: subagentModelSettingsNamespace,
    )..addListener(_changed);
    widget.runtime.addListener(_runtimeChanged);
    unawaited(controller.start());
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (controller.draft?['enabled'] == true &&
        !catalogRequested &&
        widget.runtime.ready &&
        connection == widget.runtime.connectionGeneration &&
        phase == widget.runtime.phase &&
        identical(forms, widget.runtime.forms)) {
      unawaited(_loadCatalog());
    }
  }

  @override
  void didUpdateWidget(SubagentModelSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_runtimeChanged);
      controller.removeListener(_changed);
      controller.dispose();
      catalogRequest++;
      catalog = [];
      failures = [];
      catalogFresh = catalogLoading = catalogRequested = false;
      catalogError = null;
      search.clear();
      _connect();
    }
  }

  void _runtimeChanged() {
    final connectionChanged =
        connection != widget.runtime.connectionGeneration ||
        phase != widget.runtime.phase;
    if (!connectionChanged && identical(forms, widget.runtime.forms)) return;
    connection = widget.runtime.connectionGeneration;
    phase = widget.runtime.phase;
    forms = widget.runtime.forms;
    catalogRequest++;
    setState(() {
      catalogLoading = catalogFresh = catalogRequested = false;
      catalogError = connectionChanged ? '连接已变化，正在核对模型目录。' : '模型配置已更新，正在核对目录。';
    });
    if (widget.runtime.ready && controller.draft?['enabled'] == true) {
      unawaited(_loadCatalog());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  @override
  void dispose() {
    catalogRequest++;
    WidgetsBinding.instance.removeObserver(this);
    widget.runtime.removeListener(_runtimeChanged);
    controller.removeListener(_changed);
    controller.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await Future.wait([
      controller.refresh(),
      if (controller.draft?['enabled'] == true) _loadCatalog(),
    ]);
  }

  Future<void> _loadCatalog() async {
    if (!widget.runtime.ready) return;
    final runtime = widget.runtime;
    final generation = runtime.connectionGeneration;
    final request = ++catalogRequest;
    setState(() {
      catalogRequested = catalogLoading = true;
      catalogFresh = false;
      catalogError = null;
    });
    bool current() =>
        mounted &&
        identical(runtime, widget.runtime) &&
        request == catalogRequest &&
        runtime.ready &&
        generation == runtime.connectionGeneration;
    try {
      final raw = await runtime
          .call('api.call', {
            'namespace': 'session',
            'method': 'modelCatalog',
            'args': <String, dynamic>{},
          })
          .timeout(configurationRequestTimeout);
      if (!current()) return;
      if (raw is! Map ||
          raw['groups'] is! List ||
          raw['failures'] != null && raw['failures'] is! List) {
        throw const FormatException('模型目录格式不完整');
      }
      final next = <_Candidate>[];
      final seen = <String>{};
      for (final group in raw['groups'] as List) {
        if (group is! Map ||
            group['id'] is! String ||
            (group['id'] as String).isEmpty ||
            group['models'] is! List) {
          throw const FormatException('模型提供方信息不完整');
        }
        for (final model in group['models'] as List) {
          if (model is! Map ||
              model['id'] is! String ||
              (model['id'] as String).isEmpty) {
            throw const FormatException('模型标识不完整');
          }
          final route = _ModelRoute(
            group['id'] as String,
            model['id'] as String,
          );
          if (!seen.add(route.id)) continue;
          next.add(
            _Candidate(
              route: route,
              providerName:
                  group['name'] is String &&
                      (group['name'] as String).isNotEmpty
                  ? group['name'] as String
                  : route.provider,
              modelName:
                  model['name'] is String &&
                      (model['name'] as String).isNotEmpty
                  ? model['name'] as String
                  : route.model,
              advertised: true,
            ),
          );
        }
      }
      setState(() {
        catalog = next;
        failures = [
          for (final failure in raw['failures'] as List? ?? [])
            if (failure is Map)
              '${failure['name'] ?? failure['id'] ?? '模型提供方'}：'
                  '${failure['message'] ?? '暂时无法加载'}',
        ];
        catalogFresh = true;
      });
    } catch (failure) {
      if (current()) setState(() => catalogError = '无法刷新模型目录：$failure');
    } finally {
      if (current()) setState(() => catalogLoading = false);
    }
  }

  _Selection? _selection(Json? value) {
    if (value == null) return null;
    try {
      return _Selection(value);
    } on FormatException {
      return null;
    }
  }

  void _toggle(_Candidate candidate, _Selection selection) {
    if (!controller.canEdit || !controller.writable) return;
    final routes = {for (final route in selection.routes) route.id: route};
    if (routes.containsKey(candidate.route.id)) {
      routes.remove(candidate.route.id);
    } else {
      routes[candidate.route.id] = candidate.route;
    }
    // Restoring the same set restores its baseline order as well: no false edit.
    final ordered = <_ModelRoute>[];
    for (final original
        in _selection(controller.accepted?['value'] as Json?)?.routes ??
            <_ModelRoute>[]) {
      final selected = routes.remove(original.id);
      if (selected != null) ordered.add(selected);
    }
    ordered.addAll(routes.values);
    controller.edit(
      ['allowedModels'],
      [for (final route in ordered) route.toJson()],
    );
  }

  List<_Candidate> _candidates(_Selection selection) {
    final found = {for (final row in catalog) row.route.id: row};
    final stored = _selection(controller.accepted?['value'] as Json?);
    for (final route in [...?stored?.routes, ...selection.routes]) {
      found.putIfAbsent(
        route.id,
        () => _Candidate(
          route: route,
          providerName: route.provider,
          modelName: route.model,
          advertised: false,
        ),
      );
    }
    return found.values.toList();
  }

  Future<void> _save(_Selection selection) async {
    if (!_canSave(selection)) return;
    FocusScope.of(context).unfocus();
    if (selection.duplicateCount > 0) {
      controller.edit(
        ['allowedModels'],
        [for (final route in selection.routes) route.toJson()],
      );
    }
    await controller.save(
      operations: [
        {
          'op': 'set',
          'path': ['enabled'],
          'value': selection.enabled,
        },
        {
          'op': 'set',
          'path': ['allowedModels'],
          'value': [for (final route in selection.routes) route.toJson()],
        },
      ],
    );
  }

  bool _canSave(_Selection selection) =>
      controller.canEdit &&
      controller.fresh &&
      controller.writable &&
      widget.runtime.ready &&
      !controller.conflict &&
      (controller.hasDraft || selection.duplicateCount > 0) &&
      (!selection.enabled || selection.routes.isNotEmpty);

  void _keepDraft() {
    final latest = controller.latest;
    if (latest == null ||
        controller.accepted == null ||
        controller.draft == null) {
      return;
    }
    final comparison = rebaseConfiguration(
      controller.accepted!,
      controller.draft!,
      latest,
    );
    controller.rebase(
      useLocal: {
        for (final conflict in comparison.conflicts) conflict.id: true,
      },
    );
  }

  Widget _comparison(String title, Json? value) {
    final selection = _selection(value);
    return PocketDisclosure(
      title: title,
      child: selection == null
          ? const Text('配置尚未确认')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(selection.enabled ? 'Agent 可选择子任务模型' : '使用默认或继承模型'),
                const SizedBox(height: 8),
                if (selection.routes.isEmpty) const Text('未选择授权模型'),
                for (final route in selection.routes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SelectableText('${route.provider} / ${route.model}'),
                  ),
              ],
            ),
    );
  }

  Widget _recovery() => PocketSection(
    title: controller.uncertain ? '核对保存结果' : '配置已在其他入口更新',
    children: [
      _comparison(
        '当前配置',
        (controller.latest ?? controller.accepted)?['value'] as Json?,
      ),
      _comparison('我的选择', controller.draft),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (controller.uncertain || !controller.fresh)
              PocketButton.tonal(
                key: const ValueKey('subagent-check-result'),
                onPressed: controller.loading || controller.busy
                    ? null
                    : _refresh,
                child: const Text('继续核对'),
              ),
            if (!controller.uncertain)
              PocketButton.tonal(
                key: const ValueKey('subagent-keep-draft'),
                onPressed:
                    controller.fresh &&
                        !controller.busy &&
                        controller.latest != null
                    ? _keepDraft
                    : null,
                child: const Text('保留我的选择'),
              ),
            PocketButton.tonal(
              key: const ValueKey('subagent-adopt-current'),
              onPressed: controller.fresh && !controller.busy
                  ? controller.discardDraft
                  : null,
              child: const Text('采用当前配置'),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _model(_Candidate candidate, _Selection selection) {
    final selected = selection.routes.any(
      (route) => route.id == candidate.route.id,
    );
    return Semantics(
      checked: selected,
      child: PocketTile(
        key: ValueKey('subagent-route-${candidate.route.id}'),
        selected: selected,
        title: Text(candidate.modelName),
        subtitle: Text(
          [
            '${candidate.route.provider} / ${candidate.route.model}',
            if (!candidate.advertised)
              catalogFresh ? '暂不在当前目录中，已保存的选择可保留或移除' : '已保存的模型，目录尚未确认'
            else if (!catalogFresh)
              '上次目录，等待刷新确认',
          ].join('\n'),
        ),
        trailing: Icon(
          selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        ),
        onTap: controller.canEdit && controller.writable
            ? () => _toggle(candidate, selection)
            : null,
      ),
    );
  }

  List<Widget> _models(_Selection selection) {
    final query = search.text.trim().toLowerCase();
    final candidates = _candidates(selection)
        .where(
          (candidate) => [
            candidate.modelName,
            candidate.providerName,
            candidate.route.provider,
            candidate.route.model,
          ].any((value) => value.toLowerCase().contains(query)),
        )
        .toList();
    final groups = <String, List<_Candidate>>{};
    for (final candidate in candidates) {
      groups
          .putIfAbsent(
            candidate.advertised ? candidate.route.provider : '\u0000saved',
            () => [],
          )
          .add(candidate);
    }
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: TextField(
          key: const ValueKey('subagent-model-search'),
          controller: search,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索模型或提供方',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: search.text.isEmpty
                ? null
                : GlassButton(
                    icon: Icons.close_rounded,
                    label: '清除模型搜索',
                    onPressed: () => setState(search.clear),
                  ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Text(
          '已选择 ${selection.routes.length} 个模型${controller.hasDraft ? ' · 待保存' : ''}',
        ),
      ),
      if (catalogLoading && catalog.isEmpty) const ModelNotice('正在读取模型目录…'),
      if (catalogError != null || failures.isNotEmpty)
        PocketSection(
          children: [
            PocketRow(
              icon: Icons.cloud_off_outlined,
              title: catalogError != null ? '模型目录暂未更新' : '部分提供方暂不可用',
              subtitle: '已保存的选择仍然保留，可以移除。',
            ),
            PocketDisclosure(
              title: '查看原因',
              child: SelectableText([?catalogError, ...failures].join('\n')),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: PocketButton.tonal(
                key: const ValueKey('subagent-retry-catalog'),
                onPressed: catalogLoading || !widget.runtime.ready
                    ? null
                    : _loadCatalog,
                child: const Text('刷新模型目录'),
              ),
            ),
          ],
        ),
      if (!catalogLoading && candidates.isEmpty)
        ModelNotice(
          query.isNotEmpty ? '没有匹配的模型，已选项不会改变。' : '暂无模型，请先登录账号或配置模型提供方。',
        ),
      for (final entry in groups.entries)
        PocketSection(
          title: entry.key == '\u0000saved'
              ? '已保存的其他模型'
              : entry.value.first.providerName,
          children: [
            for (final candidate in entry.value) _model(candidate, selection),
          ],
        ),
    ];
  }

  String _saveLabel(_Selection? selection) {
    if (controller.busy) return '正在保存…';
    if (controller.uncertain) return '请先核对保存结果';
    if (controller.conflict) return '请先核对配置变更';
    if (controller.loading) return '正在读取配置…';
    if (!controller.fresh) return '请先刷新配置';
    if (!controller.writable) return '当前配置只读';
    if (selection == null) return '配置需要核对';
    if (selection.enabled && selection.routes.isEmpty) return '请至少选择一个模型';
    if (selection.duplicateCount > 0) return '保存并合并重复项';
    if (!controller.hasDraft) return '已保存';
    return '保存选择';
  }

  @override
  Widget build(BuildContext context) {
    final selection = _selection(controller.draft);
    return ModelDraftGuard(
      hasEdits: () => controller.hasDraft || controller.uncertain,
      busy: controller.busy,
      child: PocketScaffold(
        title: const Text('子 Agent 模型'),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '刷新子 Agent 模型设置',
          onPressed: controller.loading || controller.busy || catalogLoading
              ? null
              : _refresh,
        ),
        bottom: PocketButton(
          key: const ValueKey('save-subagent-models'),
          onPressed: selection != null && _canSave(selection)
              ? () => _save(selection)
              : null,
          child: Text(_saveLabel(selection)),
        ),
        body: PocketList(
          padding: const EdgeInsets.all(20),
          children: [
            for (final message in [controller.error, controller.notice])
              if (message != null) ModelNotice(message),
            if (controller.uncertain || controller.conflict) _recovery(),
            if (controller.loading && controller.draft == null)
              const ModelNotice('正在读取子 Agent 模型设置…'),
            if (controller.draft != null && selection == null)
              const ModelNotice('配置中存在无效的模型标识，请核对原配置。未改动任何配置。'),
            if (selection != null) ...[
              if (selection.duplicateCount > 0)
                const ModelNotice('配置包含重复的模型，已合并显示。保存时会合并重复项。'),
              PocketSection(
                children: [
                  PocketSwitchRow(
                    key: const ValueKey('subagent-model-enabled'),
                    leading: const Icon(Icons.account_tree_outlined),
                    title: const Text('允许 Agent 选择子任务模型'),
                    value: selection.enabled,
                    onChanged: controller.canEdit && controller.writable
                        ? (enabled) => controller.edit(['enabled'], enabled)
                        : null,
                  ),
                ],
              ),
              ModelNotice(
                selection.enabled
                    ? '从下方授权模型中选择子任务的提供方、模型与推理强度。仅影响新会话。'
                    : '子 Agent 使用配置的默认模型，或继承父 Agent 的模型。已选模型会保留。',
              ),
              if (selection.enabled)
                ..._models(selection)
              else if (selection.routes.isNotEmpty)
                PocketSection(
                  children: [
                    _comparison(
                      '已保留 ${selection.routes.length} 个模型',
                      controller.draft,
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}
