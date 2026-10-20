import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
import 'configuration_editor.dart';
import 'models.dart';
import 'models_data.dart';
import 'models_editor.dart';
import 'runtime.dart';
import 'ui.dart';

class ProviderSettingsPage extends StatefulWidget {
  const ProviderSettingsPage({
    required this.runtime,
    required this.provider,
    super.key,
  });
  final RuntimeController runtime;
  final ModelProvider provider;
  @override
  State<ProviderSettingsPage> createState() => _ProviderSettingsPageState();
}

class _ProviderSettingsPageState extends ModelDraftState<ProviderSettingsPage> {
  @override
  RuntimeController get runtime => widget.runtime;
  @override
  Json get initialDescriptor =>
      widget.provider.descriptor ??
      {'ns': '', 'revision': 0, 'value': <String, dynamic>{}, 'secrets': []};
  List<String> get path => widget.provider.path;
  Json get profile => modelObjectAt(draft, path);
  bool removeReview = false;

  Future<void> openCredentials() async {
    await Navigator.push(
      context,
      PocketRoute<void>(
        builder: (_) => ModelCredentialPage(
          runtime: runtime,
          provider: ModelProvider(widget.provider.entry, accepted),
        ),
      ),
    );
    if (mounted) {
      try {
        await fetchLatest();
      } catch (error) {
        if (mounted) setState(() => message = '无法刷新配置：$error');
      }
    }
  }

  Future<void> editModels() async {
    final value = profile['models'];
    final models = value is List ? value.cast<Json>() : <Json>[];
    final next = await Navigator.push<List<Json>>(
      context,
      PocketRoute(
        builder: (_) => ModelListPage(
          runtime: runtime,
          settingsNs: accepted['ns'] as String,
          provider: widget.provider.id,
          initial: models,
          endpoint:
              profile['baseURL'] as String? ??
              widget.provider.entry['defaultBaseURL'] as String?,
          protocol: profile['api'] as String?,
          reasoningLevels: widget.provider.entry['declared'] == true
              ? modelReasoningLevels(accepted, path)
              : const [],
          supportsInput: ConfigurationSchema(accepted['schema'])
              .nodesAt([...path, 'models', '0', 'input'])
              .isNotEmpty,
        ),
      ),
    );
    if (next != null && mounted) field([...path, 'models'], next);
  }

  Future<void> remove() async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final current = ModelProvider(widget.provider.entry, accepted);
      if (!current.removable) throw const FormatException('该配置属于基础配置，不能删除。');
      await runtime.call('settings.mutate', {
        'ns': accepted['ns'],
        'revision': accepted['revision'],
        'ops': [
          {'op': 'unset', 'path': path},
        ],
      });
      if (!mounted) return;
      setState(() => busy = false);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => message = '未能删除服务商：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    final exists = provider.descriptor != null;
    final schema = ConfigurationSchema(accepted['schema']);
    final protocols = modelStringChoices(accepted, [...path, 'api']);
    final removable = ModelProvider(provider.entry, accepted).removable;
    return ModelDraftGuard(
      hasEdits: () => dirty,
      busy: busy,
      child: PocketScaffold(
        title: Text(provider.name),
        bottom: exists && !provider.account
            ? PocketButton(
                onPressed: busy || latest != null || !dirty ? null : saveDraft,
                child: Text(busy ? '正在保存' : '保存配置'),
              )
            : null,
        body: PocketList(
          padding: const EdgeInsets.all(20),
          children: [
            ...review(),
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.dns_outlined,
                  title: provider.id,
                  subtitle: provider.active ? '已注册 · 模型可用性以实际请求为准' : '尚未注册到运行时',
                ),
                if (provider.entry['error'] != null)
                  ModelNotice('${provider.entry['error']}'),
                if (provider.account)
                  const ModelNotice('此服务商使用 DeepSeek 账号授权，凭据由账号功能管理。'),
                if (!exists) const ModelNotice('服务商没有声明可编辑的配置入口。'),
                if (exists && !provider.account)
                  PocketRow(
                    icon: Icons.key_rounded,
                    title: 'API Key',
                    subtitle: '设置或撤销凭据，现有密钥不会显示',
                    onTap: busy || dirty ? null : openCredentials,
                  ),
                if (dirty) const ModelNotice('先保存当前配置，再管理凭据或高级设置。'),
              ],
            ),
            if (exists && !provider.account) ...[
              PocketSection(
                title: '连接设置',
                children: [
                  if (schema.nodesAt([...path, 'baseURL']).isNotEmpty)
                    ModelTextField(
                      key: ValueKey('endpoint:${accepted['revision']}'),
                      label: '接口地址',
                      initial: profile['baseURL'] as String? ?? '',
                      hint: provider.entry['defaultBaseURL'] as String?,
                      enabled: !busy,
                      onChanged: (value) => field(
                        [...path, 'baseURL'],
                        value.trim(),
                        unset: value.trim().isEmpty,
                      ),
                    ),
                  if (provider.entry['declared'] == true) ...[
                    ModelTextField(
                      key: ValueKey('name:${accepted['revision']}'),
                      label: '显示名称',
                      initial: profile['displayName'] as String? ?? '',
                      enabled: !busy,
                      onChanged: (value) => field(
                        [...path, 'displayName'],
                        value,
                        unset: value.isEmpty,
                      ),
                    ),
                    if (protocols.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final protocol in protocols)
                              PocketChoice(
                                label: Text(protocol),
                                selected: profile['api'] == protocol,
                                onSelected: busy
                                    ? null
                                    : (_) => field([...path, 'api'], protocol),
                              ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
              if (schema.nodesAt([...path, 'models']).isNotEmpty)
                PocketSection(
                  title: '模型',
                  children: [
                    PocketRow(
                      icon: Icons.list_alt_rounded,
                      title: '编辑模型列表',
                      subtitle: profile['models'] is List
                          ? '${(profile['models'] as List).length} 个模型 · 发现、添加与编辑'
                          : '使用服务商目录',
                      onTap: busy ? null : editModels,
                    ),
                  ],
                ),
              PocketSection(
                title: '高级',
                children: [
                  PocketRow(
                    icon: Icons.tune_rounded,
                    title: '完整服务商配置',
                    subtitle: '更多字段、继承值与安全重置',
                    onTap: busy || dirty
                        ? null
                        : () async {
                            await Navigator.push(
                              context,
                              PocketRoute<void>(
                                builder: (_) => ConfigPage(
                                  runtime: runtime,
                                  descriptor: accepted,
                                ),
                              ),
                            );
                            if (mounted) {
                              try {
                                await fetchLatest();
                              } catch (error) {
                                if (mounted) setState(() => message = '$error');
                              }
                            }
                          },
                  ),
                  if (removable && !dirty)
                    PocketRow(
                      icon: Icons.delete_outline_rounded,
                      title: '删除此服务商配置',
                      subtitle: '保留凭据，避免影响共用同一凭据的其他连接',
                      onTap: busy
                          ? null
                          : () => setState(() => removeReview = true),
                    ),
                ],
              ),
              if (removeReview)
                PocketSection(
                  title: '确认删除 ${provider.name}',
                  children: [
                    const ModelNotice('将移除此服务商的用户配置。凭据仍可从凭据页单独撤销。'),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          PocketButton.tonal(
                            onPressed: busy
                                ? null
                                : () => setState(() => removeReview = false),
                            child: const Text('保留'),
                          ),
                          PocketButton(
                            onPressed: busy ? null : remove,
                            child: const Text('确认删除配置'),
                          ),
                        ],
                      ),
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

class ModelCredentialPage extends StatefulWidget {
  const ModelCredentialPage({
    required this.runtime,
    required this.provider,
    super.key,
  });
  final RuntimeController runtime;
  final ModelProvider provider;
  @override
  State<ModelCredentialPage> createState() => _ModelCredentialPageState();
}

class _ModelCredentialPageState extends State<ModelCredentialPage> {
  late Json accepted = cloneConfiguration(widget.provider.descriptor!);
  late String reference = widget.provider.credentialRef;
  final input = TextEditingController();
  Json? status;
  Json? latestBinding;
  String? error;
  bool busy = false, reveal = false, revokeReview = false;
  bool bindingCommitted = false;
  @override
  void initState() {
    super.initState();
    unawaited(read());
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> read() async {
    try {
      final result = await widget.runtime.call('credentials.describe', {
        'ref': reference,
      }) as Json;
      if (mounted) setState(() => status = result);
    } catch (failure) {
      if (mounted) {
        setState(() {
          status = null;
          error = '无法核对凭据状态：$failure';
        });
      }
    }
  }

  Future<void> store() async {
    if (busy || latestBinding != null) return;
    final value = input.text.trim();
    if (!RegExp(r'^[\x21-\x7e]+$').hasMatch(value)) {
      setState(() => error = '请输入 API Key，不应包含空格或不可见字符。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final provider = widget.provider;
      final profile = modelObjectAt(accepted['value'], provider.path);
      if (profile['apiKeyEnv'] is! String ||
          (profile['apiKeyEnv'] as String).isEmpty) {
        if (accepted['ns'] != 'llm-pi-ai') {
          throw const FormatException('此服务商未声明可绑定的凭据字段，请在完整配置中核对。');
        }
        final next = cloneConfiguration(configurationObject(accepted['value']));
        applyConfigurationEdit(next, {
          'op': 'set',
          'path': [...provider.path, 'apiKeyEnv'],
          'value': reference,
        });
        accepted = await writeModelSettings(widget.runtime, accepted, next);
        bindingCommitted = true;
      }
      await widget.runtime.call('credentials.set', {
        'ref': reference,
        'value': value,
      });
      if (!mounted) return;
      input.clear();
      setState(() => error = '凭据已保存。');
      await read();
    } catch (failure) {
      if (mounted) {
        setState(
          () => error =
              '${bindingCommitted ? '凭据引用已绑定，但密钥尚未确认保存。' : '未能保存凭据。'}\n$failure\n输入已保留。',
        );
      }
      try {
        final rows = (await widget.runtime.call('settings.describe') as List)
            .cast<Json>();
        final latest = rows.firstWhere((row) => row['ns'] == accepted['ns']);
        if (mounted && latest['revision'] != accepted['revision']) {
          setState(() => latestBinding = cloneConfiguration(latest));
        }
      } catch (readFailure) {
        if (mounted) setState(() => error = '$error\n无法核对凭据引用：$readFailure');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> revoke() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.runtime.call('credentials.unset', {'ref': reference});
      if (!mounted) return;
      setState(() {
        revokeReview = false;
        error = '已撤销保存的凭据。';
      });
      await read();
    } catch (failure) {
      if (mounted) setState(() => error = '无法撤销凭据：$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () => input.text.isNotEmpty,
    busy: busy,
    child: PocketScaffold(
      title: const Text('API Key'),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          if (error != null) ModelNotice(error!),
          if (latestBinding != null)
            PocketSection(
              title: '核对凭据引用',
              children: [
                ModelNotice(
                  '打开时：$reference\n最新配置：${ModelProvider(widget.provider.entry, latestBinding!).credentialRef}\n密钥输入已保留；请明确确认写入目标。',
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: PocketButton.tonal(
                    onPressed: busy
                        ? null
                        : () async {
                            setState(() {
                              accepted = latestBinding!;
                              reference = ModelProvider(
                                widget.provider.entry,
                                accepted,
                              ).credentialRef;
                              latestBinding = null;
                              status = null;
                              revokeReview = false;
                            });
                            await read();
                          },
                    child: const Text('采用最新引用，保留密钥输入'),
                  ),
                ),
              ],
            ),
          PocketSection(
            title: widget.provider.name,
            children: [
              PocketRow(
                icon: Icons.key_rounded,
                title: reference,
                subtitle: status == null
                    ? '状态尚未核对'
                    : status!['configured'] == true
                    ? '已有凭据 · 来源 ${status!['source'] ?? '运行时'}'
                    : '尚未配置凭据',
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  key: const Key('model-key-input'),
                  controller: input,
                  enabled: !busy,
                  obscureText: !reveal,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '新的 API Key',
                    hintText: '仅输入新密钥，留空不会更改已有凭据',
                  ),
                ),
              ),
              PocketSwitchRow(
                title: const Text('显示本次输入'),
                value: reveal,
                onChanged: busy
                    ? null
                    : (value) => setState(() => reveal = value),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: PocketButton(
                  onPressed:
                      busy ||
                          latestBinding != null ||
                          status?['writable'] != true
                      ? null
                      : store,
                  child: Text(busy ? '正在处理' : '保存 API Key'),
                ),
              ),
              if (status?['writable'] == false)
                const ModelNotice('当前凭据来源不接受写入。'),
              PocketRow(
                icon: Icons.refresh_rounded,
                title: '重新核对状态',
                onTap: busy ? null : read,
              ),
              if (status?['configured'] == true && status?['writable'] == true)
                PocketRow(
                  icon: Icons.delete_outline_rounded,
                  title: '撤销保存的 API Key',
                  onTap: busy
                      ? null
                      : () => setState(() => revokeReview = true),
                ),
            ],
          ),
          if (revokeReview)
            PocketSection(
              title: '确认撤销凭据',
              children: [
                ModelNotice('将撤销 $reference。共用此引用的连接也会受影响；环境等其他来源仍可能提供凭据。'),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      PocketButton.tonal(
                        onPressed: busy
                            ? null
                            : () => setState(() => revokeReview = false),
                        child: const Text('保留凭据'),
                      ),
                      PocketButton(
                        onPressed: busy ? null : revoke,
                        child: const Text('确认撤销'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    ),
  );
}

class CustomProviderPage extends StatefulWidget {
  const CustomProviderPage({
    required this.runtime,
    required this.descriptor,
    required this.taken,
    super.key,
  });
  final RuntimeController runtime;
  final Json descriptor;
  final Set<String> taken;
  @override
  State<CustomProviderPage> createState() => _CustomProviderPageState();
}

class _CustomProviderPageState extends State<CustomProviderPage> {
  final route = TextEditingController(),
      name = TextEditingController(),
      endpoint = TextEditingController();
  late final protocols = modelStringChoices(widget.descriptor, [
    'providers',
    '\u0000probe',
    'api',
  ]);
  String? protocol;
  late Json accepted = cloneConfiguration(widget.descriptor);
  late Set<String> taken = {...widget.taken};
  ModelsSnapshot? latest;
  List<Json> models = [];
  String? error;
  bool busy = false, created = false;
  @override
  void dispose() {
    route.dispose();
    name.dispose();
    endpoint.dispose();
    super.dispose();
  }

  Future<void> edit() async {
    final next = await Navigator.push<List<Json>>(
      context,
      PocketRoute(
        builder: (_) => ModelListPage(
          runtime: widget.runtime,
          settingsNs: 'llm-pi-ai',
          initial: models,
          endpoint: endpoint.text.trim(),
          protocol: protocol,
          reasoningLevels: modelReasoningLevels(widget.descriptor, [
            'providers',
            '\u0000probe',
          ]),
          supportsInput: true,
        ),
      ),
    );
    if (next != null && mounted) setState(() => models = next);
  }

  Future<void> create() async {
    if (busy || latest != null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final id = route.text.trim();
      validateCustomProvider(
        id,
        endpoint.text.trim(),
        protocol ?? '',
        protocols,
        models,
        taken,
      );
      final profile = <String, dynamic>{
        if (name.text.trim().isNotEmpty) 'displayName': name.text.trim(),
        'baseURL': endpoint.text.trim(),
        'api': protocol,
        'models': models,
      };
      await widget.runtime.call('settings.mutate', {
        'ns': accepted['ns'],
        'revision': accepted['revision'],
        'ops': [
          {
            'op': 'set',
            'path': ['providers', id],
            'value': profile,
          },
        ],
      });
      created = true;
      if (!mounted) return;
      setState(() => busy = false);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) {
        setState(() => error = '未能确认创建服务商：$failure\n当前输入已保留。');
      }
      try {
        final snapshot = await ModelsSnapshot.read(widget.runtime);
        final next = snapshot.descriptor(accepted['ns'] as String);
        if (mounted &&
            next != null &&
            next['revision'] != accepted['revision']) {
          setState(() => latest = snapshot);
        }
      } catch (readFailure) {
        if (mounted) setState(() => error = '$error\n无法核对最新目录：$readFailure');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () =>
        !created &&
        (route.text.isNotEmpty ||
            name.text.isNotEmpty ||
            endpoint.text.isNotEmpty ||
            protocol != null ||
            models.isNotEmpty),
    busy: busy,
    child: PocketScaffold(
      title: const Text('添加自定义服务商'),
      bottom: PocketButton(
        onPressed: busy || latest != null ? null : create,
        child: const Text('创建服务商'),
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          if (error != null) ModelNotice(error!),
          if (latest != null)
            PocketSection(
              title: '目录已发生变化',
              children: [
                ModelNotice(
                  latest!.providers.any((row) => row.id == route.text.trim())
                      ? '当前服务商 ID 已存在，不能覆盖。采用最新目录后，请修改 ID；如果这是上次已创建的连接，可返回目录查看。'
                      : '最新版本 ${latest!.descriptor(accepted['ns'] as String)!['revision']}，当前表单仍保留。',
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: PocketButton.tonal(
                    onPressed: () => setState(() {
                      accepted = cloneConfiguration(
                        latest!.descriptor(accepted['ns'] as String)!,
                      );
                      taken = latest!.providers.map((row) => row.id).toSet();
                      latest = null;
                    }),
                    child: const Text('采用最新目录，继续编辑'),
                  ),
                ),
              ],
            ),
          PocketSection(
            title: '连接',
            children: [
              for (final (controller, label) in [
                (route, '服务商 ID'),
                (name, '显示名称'),
                (endpoint, '接口地址'),
              ])
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: controller,
                    enabled: !busy,
                    decoration: InputDecoration(labelText: label),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in protocols)
                      PocketChoice(
                        label: Text(item),
                        selected: protocol == item,
                        onSelected: busy
                            ? null
                            : (_) => setState(() => protocol = item),
                      ),
                  ],
                ),
              ),
              PocketRow(
                icon: Icons.list_alt_rounded,
                title: '模型列表',
                subtitle: '${models.length} 个模型',
                onTap: busy ? null : edit,
              ),
            ],
          ),
          const ModelNotice('创建后可在服务商页面设置 API Key。未设置密钥时保留服务商原生认证方式。'),
        ],
      ),
    ),
  );
}

class ModelTextField extends StatefulWidget {
  const ModelTextField({
    required this.label,
    required this.initial,
    required this.enabled,
    required this.onChanged,
    this.hint,
    super.key,
  });
  final String label, initial;
  final String? hint;
  final bool enabled;
  final ValueChanged<String> onChanged;
  @override
  State<ModelTextField> createState() => _ModelTextFieldState();
}

class _ModelTextFieldState extends State<ModelTextField> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void didUpdateWidget(ModelTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initial != controller.text &&
        widget.initial != oldWidget.initial) {
      controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: TextField(
      controller: controller,
      enabled: widget.enabled,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
      ),
      onChanged: widget.onChanged,
    ),
  );
}
