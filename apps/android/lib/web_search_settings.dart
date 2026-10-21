import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
import 'configuration_editor.dart';
import 'configuration_fields.dart';
import 'configuration_fields_schema.dart';
import 'configuration_presentation.dart';
import 'configuration_value_row.dart';
import 'credentials.dart';
import 'credentials_data.dart';
import 'models.dart' show ModelDraftGuard;
import 'runtime.dart';
import 'text_document_page.dart';
import 'ui.dart';
import 'web_search_settings_data.dart';

/// The native equivalent of DSH's three-section Web search settings workflow.
/// Opening the page never starts a session or changes an execution provider.
class WebSearchSettingsPage extends StatefulWidget {
  const WebSearchSettingsPage({required this.runtime, super.key});
  final RuntimeController runtime;

  @override
  State<WebSearchSettingsPage> createState() => _WebSearchSettingsPageState();
}

class _WebSearchSettingsPageState extends State<WebSearchSettingsPage>
    with WidgetsBindingObserver {
  late WebSearchSettingsController controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connect();
  }

  void _connect() {
    controller = WebSearchSettingsController(widget.runtime);
    unawaited(controller.start());
  }

  @override
  void didUpdateWidget(WebSearchSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final mode = controller.mode;
      final selected = switch (mode) {
        WebSearchMode.messages => webSearchNamespace,
        WebSearchMode.api => webApiNamespace,
        WebSearchMode.custom => null,
      };
      return ModelDraftGuard(
        hasEdits: () => controller.hasDraft,
        busy: controller.saving,
        child: PocketScaffold(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('网页搜索'),
              Text(
                controller.saving
                    ? '正在保存'
                    : controller.hasDraft
                    ? '未保存'
                    : '',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          trailing: GlassButton(
            key: const ValueKey('web-search-save'),
            icon: Icons.check_rounded,
            label: '保存网页搜索设置',
            solid: true,
            onPressed: controller.canSave ? controller.save : null,
          ),
          body: PocketList(
            key: const PageStorageKey('web-search-settings'),
            children: [
              if (!controller.initialized) const _Note('正在读取网页搜索设置…'),
              if (controller.initialized &&
                  !controller.available(webSearchNamespace))
                const _Note('当前未能读取 DeepSeek 搜索配置。请刷新或检查插件是否已启用。'),
              if (controller.available(webRoutingNamespace))
                PocketSection(
                  children: [
                    ConfigurationValueRow(
                      key: const ValueKey('web-search-mode'),
                      title: '搜索方式',
                      summary: webSearchModeLabel(mode),
                      onTap: () =>
                          _open(context, _ModePage(controller: controller)),
                    ),
                  ],
                ),
              if (selected != null && controller.available(selected))
                _ServiceFields(controller: controller, namespace: selected),
              if (selected == null)
                PocketSection(
                  title: '服务参数',
                  divided: true,
                  children: [
                    for (final ns in [webSearchNamespace, webApiNamespace])
                      if (controller.available(ns))
                        PocketRow(
                          icon: Icons.travel_explore_rounded,
                          title: webSearchSectionLabel(ns),
                          onTap: () => _open(
                            context,
                            _ServicePage(controller: controller, namespace: ns),
                          ),
                        ),
                  ],
                ),
              if (selected == null && controller.available(webRoutingNamespace))
                const _Note('保留当前自定义搜索与读取组合。选择另一种搜索方式后，才会一起切换这两个服务。'),
              if (controller.available(webSearchNamespace))
                const _Note(
                  '使用 DeepSeek 账号模型的对话可在官方允许的接口使用账号授权。未填写 API Key 不会阻止保存。',
                ),
              if (controller.stagedReferences.any(
                (ref) =>
                    selected == null || ref != controller.reference(selected),
              ))
                PocketSection(
                  title: '其他待保存凭据',
                  divided: true,
                  children: [
                    for (final ref in controller.stagedReferences)
                      if (selected == null ||
                          ref != controller.reference(selected))
                        ConfigurationValueRow(
                          title: ref,
                          summary: controller.keyNeedsReview(ref)
                              ? '需要核对'
                              : '已填写',
                          protected: true,
                          onTap: controller.saving
                              ? null
                              : () => _reviewKey(context, controller, ref),
                        ),
                  ],
                ),
              _ReviewStatus(controller: controller),
              PocketSection(
                divided: true,
                children: [
                  PocketRow(
                    icon: Icons.tune_rounded,
                    title: '更多设置',
                    onTap: () =>
                        _open(context, _MorePage(controller: controller)),
                  ),
                  PocketRow(
                    icon: Icons.refresh_rounded,
                    title: '刷新并核对',
                    subtitle: '保留本页未保存的修改',
                    onTap: controller.loading || controller.saving
                        ? null
                        : controller.refresh,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _open(BuildContext context, Widget page) =>
    Navigator.of(context).push<void>(PocketRoute(builder: (_) => page));

class _ModePage extends StatelessWidget {
  const _ModePage({required this.controller});
  final WebSearchSettingsController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => PocketScaffold(
      title: const Text('搜索方式'),
      body: PocketList(
        children: [
          PocketSection(
            divided: true,
            children: [
              for (final mode in [WebSearchMode.messages, WebSearchMode.api])
                PocketTile(
                  key: ValueKey('web-mode-${mode.name}'),
                  title: Text(webSearchModeLabel(mode)),
                  subtitle: Text(
                    mode == WebSearchMode.messages
                        ? '通过 DeepSeek Messages 搜索，使用本机 HTTP 读取网页'
                        : '使用 DeepSeek Search 与 Fetch 接口搜索和读取网页',
                  ),
                  selected: controller.mode == mode,
                  trailing: controller.mode == mode
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: controller.canChooseMode
                      ? () {
                          controller.chooseMode(mode);
                          Navigator.pop(context);
                        }
                      : null,
                ),
            ],
          ),
          if (controller.mode == WebSearchMode.custom)
            PocketSection(
              title: '当前自定义组合',
              children: [
                _RouteValue(
                  controller: controller,
                  field: 'searchProvider',
                  title: '搜索服务',
                ),
                _RouteValue(
                  controller: controller,
                  field: 'fetchProvider',
                  title: '网页读取服务',
                ),
              ],
            ),
          if (!controller.canChooseMode)
            const _Note('需要可写的搜索、读取和 DeepSeek API 配置，才能切换方式。当前设置保持原样。'),
          const _Note('选择只修改本页草稿，返回后点击右上角勾选保存。'),
        ],
      ),
    ),
  );
}

class _RouteValue extends StatelessWidget {
  const _RouteValue({
    required this.controller,
    required this.field,
    required this.title,
  });
  final WebSearchSettingsController controller;
  final String field, title;
  @override
  Widget build(BuildContext context) => PocketRow(
    icon: Icons.route_outlined,
    title: title,
    subtitle: configurationStructureSummary(
      controller.value(webRoutingNamespace, field),
    ),
  );
}

class _ServicePage extends StatelessWidget {
  const _ServicePage({required this.controller, required this.namespace});
  final WebSearchSettingsController controller;
  final String namespace;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => PocketScaffold(
      title: Text(webSearchSectionLabel(namespace)),
      body: PocketList(
        children: [
          _ServiceFields(controller: controller, namespace: namespace),
          const _Note('返回网页搜索后统一保存。未启用此方式时，仅保存它的参数，不切换当前服务。'),
        ],
      ),
    ),
  );
}

class _ServiceFields extends StatelessWidget {
  const _ServiceFields({required this.controller, required this.namespace});
  final WebSearchSettingsController controller;
  final String namespace;

  @override
  Widget build(BuildContext context) {
    final isApi = namespace == webApiNamespace;
    final ref = controller.reference(namespace);
    final row = ref == null ? null : controller.credentials.entry(ref);
    final hasLiteral =
        (controller.section(namespace).accepted?['secrets'] as List? ?? []).any(
          (slot) =>
              slot is Map &&
              configurationEqual(slot['path'], ['apiKey']) &&
              slot['set'] == true,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PocketSection(
          title: isApi ? '搜索与读取参数' : '对话式搜索参数',
          divided: true,
          children: [
            _FieldRow(
              controller: controller,
              namespace: namespace,
              field: 'baseURL',
            ),
            _FieldRow(
              controller: controller,
              namespace: namespace,
              field: isApi ? 'count' : 'maxUses',
            ),
            if (isApi &&
                controller.field(namespace, 'sendOriginalQuestion') != null)
              _FieldRow(
                controller: controller,
                namespace: namespace,
                field: 'sendOriginalQuestion',
              ),
          ],
        ),
        PocketSection(
          title: '授权',
          divided: true,
          children: [
            ConfigurationValueRow(
              key: ValueKey('web-key:$namespace'),
              title: 'API Key',
              summary: ref == null
                  ? '引用无效'
                  : controller.keyNeedsReview(ref)
                  ? '需要核对'
                  : controller.keyDraft(ref).isNotEmpty
                  ? '已填写，待保存'
                  : row!.reading
                  ? '正在核对'
                  : !row.fresh
                  ? '状态待确认'
                  : row.status?.configured == true
                  ? '已配置'
                  : '未配置',
              protected: true,
              onTap:
                  ref != null &&
                      controller.editable(namespace) &&
                      !controller.keyNeedsReview(ref) &&
                      row!.write?.inFlight != true &&
                      row.write?.state != 'unconfirmed'
                  ? () => _editKey(context, controller, ref)
                  : null,
            ),
            if (ref != null &&
                (row!.write?.state == 'unconfirmed' ||
                    controller.keyNeedsReview(ref) ||
                    row.readError != null ||
                    row.draft.isNotEmpty &&
                        row.draft != controller.keyDraft(ref)))
              PocketRow(
                icon: Icons.key_rounded,
                title: '核对凭据写入',
                subtitle: controller.keyNeedsReview(ref)
                    ? '凭据在其他操作中发生变化，本页输入不会自动覆盖它'
                    : row.write?.notice ?? row.readError ?? '凭据管理中有另一份未保存的输入',
                onTap: controller.saving
                    ? null
                    : () => _reviewKey(context, controller, ref),
              ),
          ],
        ),
        if (ref == null) const _Note('当前凭据引用不符合原服务的命名规则，可在更多设置中修正。'),
        if (hasLiteral) const _Note('此服务配置内还有独立密钥。它可能优先于引用凭据，修改引用不会移除配置内的密钥。'),
      ],
    );
  }
}

String _fieldTitle(String ns, String key) => switch (key) {
  'baseURL' => '服务地址',
  'maxUses' => '每次请求最多搜索',
  'count' => '每次搜索结果数',
  _ => key,
};

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.controller,
    required this.namespace,
    required this.field,
  });
  final WebSearchSettingsController controller;
  final String namespace, field;
  @override
  Widget build(BuildContext context) {
    final schema = controller.field(namespace, field);
    if (schema == null) return const SizedBox.shrink();
    final presentation = ConfigurationPresentation(namespace);
    final label = const ['baseURL', 'maxUses', 'count'].contains(field)
        ? _fieldTitle(namespace, field)
        : presentation.title([field], schema);
    final value = controller.value(namespace, field);
    if (schema.type == 'boolean' && value is bool) {
      return PocketSwitchRow(
        key: ValueKey('web-field:$namespace:$field'),
        title: Text(label),
        subtitle: Text(presentation.description([field], schema) ?? ''),
        value: value,
        onChanged: controller.editable(namespace)
            ? (next) => controller.edit(namespace, field, next)
            : null,
      );
    }
    return ConfigurationValueRow(
      key: ValueKey('web-field:$namespace:$field'),
      title: label,
      summary: configurationHasValue(value) && value != null && value != ''
          ? configurationStructureSummary(value)
          : '使用默认值',
      onTap: controller.editable(namespace)
          ? () async {
              controller.holdEditor(true);
              try {
                if (schema.type == 'string') {
                  final next = await Navigator.push<String>(
                    context,
                    PocketRoute(
                      builder: (_) => TextDocumentPage(
                        title: label,
                        text: value is String ? value : '',
                        readOnly: false,
                        fieldKey: const ValueKey('web-field-input'),
                        helperText:
                            '${presentation.description([field], schema) ?? ''}\n留空恢复默认值。返回网页搜索后统一保存。'
                                .trim(),
                        editingState: controller,
                        canEdit: () => controller.editable(namespace),
                        validate: (text) {
                          if (text.trim().isEmpty) return null;
                          if (field == 'apiKeyEnv' &&
                              !validCredentialReference(text.trim())) {
                            return '凭据引用须以字母或下划线开头，只能包含字母、数字和下划线。';
                          }
                          if (field == 'baseURL') {
                            final uri = Uri.tryParse(text.trim());
                            if (uri == null ||
                                !const ['http', 'https'].contains(uri.scheme) ||
                                uri.host.isEmpty ||
                                uri.userInfo.isNotEmpty) {
                              return '请输入完整的 HTTP 或 HTTPS 地址，不包含用户名和密码。';
                            }
                          }
                          return schema.validate(text.trim());
                        },
                      ),
                    ),
                  );
                  if (context.mounted && next != null) {
                    controller.edit(
                      namespace,
                      field,
                      next.trim(),
                      remove: next.trim().isEmpty,
                    );
                  }
                } else {
                  final next = await Navigator.push<ConfigurationFieldResult>(
                    context,
                    PocketRoute(
                      builder: (_) => ConfigurationStructurePage(
                        title: label,
                        field: schema,
                        value: value,
                        namespace: namespace,
                        path: [field],
                        allowReset: true,
                        editingState: controller,
                        canEdit: () => controller.editable(namespace),
                      ),
                    ),
                  );
                  if (context.mounted && next != null) {
                    controller.edit(
                      namespace,
                      field,
                      next.value,
                      remove: next.remove,
                    );
                  }
                }
              } finally {
                controller.holdEditor(false);
              }
            }
          : null,
    );
  }
}

Future<void> _editKey(
  BuildContext context,
  WebSearchSettingsController controller,
  String ref,
) async {
  controller.holdEditor(true);
  try {
    final next = await Navigator.push<String>(
      context,
      PocketRoute(
        builder: (_) => TextDocumentPage(
          title: 'API Key',
          text: controller.keyDraft(ref),
          readOnly: false,
          obscureText: true,
          fieldKey: const ValueKey('web-key-input'),
          helperText:
              '保存到 $ref。已有密钥不会显示，留空保持原密钥。使用同名引用的模型和工具也会受到影响。返回网页搜索后统一保存。',
          editingState: controller,
          canEdit: () =>
              !controller.saving &&
              controller.credentials.entry(ref).write?.inFlight != true &&
              controller.credentials.entry(ref).write?.state != 'unconfirmed',
        ),
      ),
    );
    if (context.mounted && next != null) controller.editKey(ref, next);
  } finally {
    controller.holdEditor(false);
  }
}

Future<void> _manageKey(
  BuildContext context,
  WebSearchSettingsController controller,
  String ref,
) async {
  await _open(
    context,
    CredentialReferencePage(controller: controller.credentials, reference: ref),
  );
  await controller.refresh();
}

Future<void> _reviewKey(
  BuildContext context,
  WebSearchSettingsController controller,
  String ref,
) => _open(context, _KeyReviewPage(controller: controller, reference: ref));

class _KeyReviewPage extends StatelessWidget {
  const _KeyReviewPage({required this.controller, required this.reference});
  final WebSearchSettingsController controller;
  final String reference;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final row = controller.credentials.entry(reference);
      return PocketScaffold(
        title: const Text('核对搜索凭据'),
        body: PocketList(
          children: [
            _Note(reference),
            if (controller.keyNeedsReview(reference))
              const _Note('凭据已在其他操作中变更，或回执来自先前连接。本页输入仍保留，不会自动再次写入。'),
            if (row.write?.notice != null) _Note(row.write!.notice!),
            PocketSection(
              divided: true,
              children: [
                PocketRow(
                  icon: Icons.key_rounded,
                  title: '管理共享凭据',
                  subtitle: '查看状态，明确选择替换或移除',
                  onTap: controller.saving
                      ? null
                      : () => _manageKey(context, controller, reference),
                ),
                if (controller.keyDraft(reference).isNotEmpty)
                  PocketRow(
                    key: const ValueKey('web-key-discard'),
                    icon: Icons.undo_rounded,
                    title: '放弃本页密钥输入',
                    subtitle: '不修改已保存的凭据，也不会撤回此前请求；其余搜索修改保留',
                    onTap: controller.saving || row.write?.inFlight == true
                        ? null
                        : () {
                            controller.discardKey(reference);
                            Navigator.pop(context);
                          },
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _MorePage extends StatelessWidget {
  const _MorePage({required this.controller});
  final WebSearchSettingsController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => PocketScaffold(
      title: const Text('更多搜索设置'),
      body: PocketList(
        children: [
          for (final ns in [webSearchNamespace, webApiNamespace])
            if (controller.available(ns)) ...[
              PocketSection(
                title: webSearchSectionLabel(ns),
                divided: true,
                children: [
                  PocketRow(
                    icon: Icons.travel_explore_rounded,
                    title: '接口与搜索参数',
                    onTap: () => _open(
                      context,
                      _ServicePage(controller: controller, namespace: ns),
                    ),
                  ),
                  _FieldRow(
                    controller: controller,
                    namespace: ns,
                    field: 'apiKeyEnv',
                  ),
                  if (ns == webSearchNamespace)
                    for (final key in ['model', 'apiVersion', 'maxTokens'])
                      _FieldRow(
                        controller: controller,
                        namespace: ns,
                        field: key,
                      ),
                ],
              ),
            ],
          const TextDocumentRow(
            title: '保存与授权说明',
            text: '搜索和读取服务共同切换。保存时先提交接口参数，再保存本次填写的凭据，最后切换服务。中途失败会停止后续步骤；已经确认保存的参数可能已被当前服务使用，不会自动回滚。\n\n账号授权由 DeepSeek 原服务判断，取决于本轮对话使用的模型路由与请求地址。未配置 API Key 不表示账号对话一定无法搜索。\n\n没有填写新密钥时不会写入凭据。切换方式会保留另一套接口参数；自定义服务组合不会自动替换。',
          ),
          PocketSection(
            title: '高级设置',
            children: [
              PocketRow(
                key: const ValueKey('web-search-advanced'),
                icon: Icons.tune_rounded,
                title: '原始配置',
                subtitle: controller.canOpenAdvanced
                    ? '自定义服务组合与配置内密钥'
                    : '先保存或处理当前草稿与未确认操作',
                onTap: controller.canOpenAdvanced
                    ? () =>
                          _open(context, _AdvancedPage(controller: controller))
                    : null,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _AdvancedPage extends StatelessWidget {
  const _AdvancedPage({required this.controller});
  final WebSearchSettingsController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => PocketScaffold(
      title: const Text('原始搜索配置'),
      body: PocketList(
        children: [
          PocketSection(
            divided: true,
            children: [
              for (final scope in controller.served)
                PocketRow(
                  icon: Icons.tune_rounded,
                  title: webSearchSectionLabel(scope.namespace),
                  onTap: controller.canOpenAdvanced
                      ? () async {
                          await _open(
                            context,
                            ConfigPage(
                              runtime: controller.runtime,
                              descriptor: scope.accepted!,
                            ),
                          );
                          await controller.refresh();
                        }
                      : null,
                ),
            ],
          ),
          const _Note('这里直接编辑原服务配置。自定义搜索与读取组合、配置内密钥可分别管理；普通搜索设置无需修改这些内容。'),
        ],
      ),
    ),
  );
}

class _ReviewStatus extends StatelessWidget {
  const _ReviewStatus({required this.controller});
  final WebSearchSettingsController controller;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (controller.notice != null) _Note(controller.notice!),
      if (controller.completed.isNotEmpty && controller.hasDraft)
        _Note('已确认保存：${controller.completed.join('、')}。这些变更可能已生效；其余修改仍保留在本页。'),
      for (final scope in controller.served)
        if (scope.error != null ||
            scope.conflict ||
            scope.uncertain ||
            !scope.writable)
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.info_outline_rounded,
                title: webSearchSectionLabel(scope.namespace),
                subtitle: scope.uncertain
                    ? '写入结果尚未确认，不会自动重发'
                    : scope.conflict
                    ? '配置已变化，保留着本页修改'
                    : !scope.writable
                    ? '当前配置只读'
                    : '需要重新核对',
                onTap: () => _open(
                  context,
                  _ReviewPage(
                    controller: controller,
                    namespace: scope.namespace,
                  ),
                ),
              ),
            ],
          ),
    ],
  );
}

class _ReviewPage extends StatelessWidget {
  const _ReviewPage({required this.controller, required this.namespace});
  final WebSearchSettingsController controller;
  final String namespace;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final scope = controller.section(namespace);
      final conflicts = controller.conflicts(namespace);
      return PocketScaffold(
        title: const Text('核对配置'),
        body: PocketList(
          children: [
            _Note(webSearchSectionLabel(namespace)),
            if (scope.error != null) _Note(scope.error!),
            if (scope.uncertain) const _Note('服务端可能已经完成写入。刷新会核对目标值；不会自动再次保存。'),
            for (final conflict in conflicts)
              PocketSection(
                title: conflict.path.isEmpty
                    ? '配置内容'
                    : ConfigurationPresentation(namespace).title(
                        conflict.path,
                        controller.field(namespace, conflict.path.first) ??
                            ConfigurationFieldSchema(
                              ConfigurationSchema({}),
                              {},
                            ),
                      ),
                children: [
                  _Note(
                    '本页修改：${configurationStructureSummary(conflict.local)}',
                  ),
                  _Note(
                    '服务端当前值：${configurationStructureSummary(conflict.remote)}',
                  ),
                ],
              ),
            PocketSection(
              divided: true,
              children: [
                PocketRow(
                  icon: Icons.refresh_rounded,
                  title: '重新核对',
                  onTap: controller.saving || controller.loading
                      ? null
                      : controller.refresh,
                ),
                if (scope.conflict && !scope.uncertain)
                  PocketRow(
                    icon: Icons.merge_rounded,
                    title: '保留本页修改并合并',
                    subtitle: '上述冲突采用本页值，其他服务端变更保留；返回后再保存',
                    onTap: scope.fresh && !controller.saving
                        ? () {
                            if (controller.keepDraft(namespace)) {
                              Navigator.pop(context);
                            }
                          }
                        : null,
                  ),
                if (scope.latest != null)
                  PocketRow(
                    icon: Icons.cloud_done_outlined,
                    title: '采用服务端值',
                    subtitle: '放弃这个配置区的本页草稿，其他配置区的草稿保留',
                    onTap: scope.fresh && !controller.saving
                        ? () {
                            controller.useRemote(namespace);
                            Navigator.pop(context);
                          }
                        : null,
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}
