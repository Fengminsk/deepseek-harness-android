import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'configuration_edits.dart';
import 'confirmation.dart';
import 'account.dart';
import 'models_data.dart';
import 'models_provider.dart';
import 'runtime.dart';
import 'ui.dart';

class ModelsPage extends StatefulWidget {
  const ModelsPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  late final directory = widget.runtime.models;
  ModelsSnapshot? get snapshot => directory.snapshot;
  bool get loading => directory.loading;
  String? get error => directory.error;
  @override
  void initState() {
    super.initState();
    directory.addListener(changed);
    unawaited(refresh());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> refresh() => directory.refresh();

  @override
  void dispose() {
    directory.removeListener(changed);
    super.dispose();
  }

  Future<void> openAccount() async {
    await Navigator.push(
      context,
      PocketRoute<void>(builder: (_) => AccountPage(runtime: widget.runtime)),
    );
    if (mounted) await refresh();
  }

  Future<void> open(Widget? Function(ModelsSnapshot) create) async {
    if (!directory.fresh) {
      await refresh();
      if (!mounted || !directory.fresh) return;
    }
    final current = snapshot;
    if (current == null) return;
    final page = create(current);
    if (page == null) return; // The provider may have been removed in Web.
    await Navigator.push(context, PocketRoute<void>(builder: (_) => page));
    if (mounted) await refresh();
  }

  @override
  Widget build(BuildContext context) {
    final data = snapshot;
    final custom = data?.descriptor('llm-pi-ai');
    return PocketScaffold(
      title: const Text('模型与连接'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新模型目录',
        onPressed: loading ? null : refresh,
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.account_circle_outlined,
                title: 'DeepSeek 账号',
                subtitle: '通过官方账号登录，使用账号提供的模型与额度',
                onTap: openAccount,
              ),
            ],
          ),
          if (error != null)
            ModelNotice(
              '无法刷新模型目录：$error'
              '${data == null ? '' : '\n当前显示上次读取的内容，编辑前会重新核对。'}',
            ),
          if (data == null)
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.hub_outlined,
                  title: loading ? '正在读取模型目录' : '模型目录暂不可用',
                ),
              ],
            ),
          if (data != null) ...[
            if (!data.catalogFresh)
              ModelNotice(
                '实时模型目录尚未恢复；已显示当前服务商配置和保存的默认模型。'
                '${directory.retryPending ? '稍后会自动重试。' : '请点击刷新重试。'}'
                '恢复前不能更改默认模型。',
              ),
            PocketSection(
              title: '默认模型',
              children: [
                PocketRow(
                  icon: Icons.auto_awesome_outlined,
                  title: '${data.catalog['default']?['model'] ?? '尚未选择'}',
                  subtitle:
                      '${data.catalog['default']?['provider'] ?? ''}'
                      '${data.catalog['default']?['reasoningEffort'] == null ? '' : ' · ${data.catalog['default']['reasoningEffort']}'}',
                  onTap:
                      !data.catalogFresh ||
                          data.descriptor('agent-default-model') == null
                      ? null
                      : () => open(
                          (current) =>
                              !current.catalogFresh ||
                                  current.descriptor('agent-default-model') ==
                                      null
                              ? null
                              : DefaultModelPage(
                                  runtime: widget.runtime,
                                  snapshot: current,
                                ),
                        ),
                ),
              ],
            ),
            for (final failure in data.catalog['failures'] as List? ?? [])
              ModelNotice('${failure['name']}：${failure['message']}'),
            PocketSection(
              title: '服务商',
              children: [
                for (final provider in data.providers)
                  PocketRow(
                    icon: provider.account
                        ? Icons.account_circle_outlined
                        : Icons.dns_outlined,
                    title: provider.name,
                    subtitle:
                        '${provider.id} · ${provider.active ? '已注册' : '待配置'}'
                        '${provider.entry['error'] == null ? '' : '\n${provider.entry['error']}'}',
                    onTap: provider.account
                        ? openAccount
                        : () => open((current) {
                            final matches = current.providers.where(
                              (row) => row.id == provider.id,
                            );
                            if (matches.isEmpty) return null;
                            return ProviderSettingsPage(
                              runtime: widget.runtime,
                              provider: matches.first,
                            );
                          }),
                  ),
              ],
            ),
            if (custom != null &&
                modelStringChoices(custom, [
                  'providers',
                  '\u0000probe',
                  'api',
                ]).isNotEmpty)
              PocketButton.tonal(
                onPressed: () => open((current) {
                  final descriptor = current.descriptor('llm-pi-ai');
                  if (descriptor == null) return null;
                  return CustomProviderPage(
                    runtime: widget.runtime,
                    descriptor: descriptor,
                    taken: current.providers.map((row) => row.id).toSet(),
                  );
                }),
                child: const Text('添加自定义服务商'),
              ),
            const ModelNotice('服务商、模型和凭据与 Web 共用。目录注册状态不代表模型请求已经验证成功。'),
          ],
        ],
      ),
    );
  }
}

class ModelNotice extends StatelessWidget {
  const ModelNotice(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
    child: SelectableText(text),
  );
}

/// Leaving an edited form is an explicit decision, including after a failure.
class ModelDraftGuard extends StatefulWidget {
  const ModelDraftGuard({
    required this.hasEdits,
    required this.child,
    this.busy = false,
    super.key,
  });
  final bool Function() hasEdits;
  final bool busy;
  final Widget child;
  @override
  State<ModelDraftGuard> createState() => _ModelDraftGuardState();
}

class _ModelDraftGuardState extends State<ModelDraftGuard> {
  bool leaving = false, review = false;
  void close([Object? result]) {
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: leaving,
    onPopInvokedWithResult: (didPop, result) {
      if (didPop || widget.busy) return;
      // A non-null result is the form's explicit Apply action after validation.
      if (result != null || !widget.hasEdits()) {
        close(result);
      } else {
        // Close the keyboard and selection toolbar before exposing the review.
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() => review = true);
      }
    },
    child: PocketConfirmationLayer(
      confirmation: review
          ? PocketConfirmation(
              title: '保留当前编辑？',
              message: '当前内容尚未保存。继续编辑会保留所有输入。',
              secondaryLabel: '继续编辑',
              onSecondary: () => setState(() => review = false),
              primaryLabel: '放弃编辑并返回',
              onPrimary: widget.busy ? null : close,
              scrollKey: const Key('draft-review-scroll'),
            )
          : null,
      child: widget.child,
    ),
  );
}

/// Shared presentation workflow for revisioned forms, never a settings owner.
abstract class ModelDraftState<T extends StatefulWidget> extends State<T> {
  RuntimeController get runtime;
  Json get initialDescriptor;
  late Json accepted = cloneConfiguration(initialDescriptor);
  late Json draft = cloneConfiguration(configurationObject(accepted['value']));
  Json? latest;
  final choices = <String, bool>{};
  bool busy = false;
  String? message;

  bool get dirty => !configurationEqual(accepted['value'], draft);

  void field(List<String> path, dynamic value, {bool unset = false}) {
    setState(() {
      applyConfigurationEdit(draft, {
        'op': unset ? 'unset' : 'set',
        'path': path,
        if (!unset) 'value': value,
      });
      message = null;
      choices.clear();
    });
  }

  Future<void> fetchLatest() async {
    final rows = (await runtime.call('settings.describe') as List).cast<Json>();
    final next = rows.firstWhere((row) => row['ns'] == accepted['ns']);
    if (!mounted) return;
    setState(() {
      latest = cloneConfiguration(next);
      choices.clear();
    });
  }

  Future<bool> saveDraft() async {
    if (busy || latest != null) return false;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final saved = await writeModelSettings(runtime, accepted, draft);
      if (!mounted) return false;
      setState(() {
        accepted = saved;
        draft = cloneConfiguration(configurationObject(saved['value']));
        message = '已保存。';
      });
      return true;
    } catch (failure) {
      if (mounted) setState(() => message = '未能完成保存：$failure\n当前编辑已保留。');
      try {
        await fetchLatest();
      } catch (readFailure) {
        if (mounted) {
          setState(() => message = '$message\n无法核对最新配置：$readFailure');
        }
      }
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void mergeLatest() {
    final result = rebaseConfiguration(
      accepted,
      draft,
      latest!,
      useLocal: choices,
    );
    if (result.conflicts.isNotEmpty) return;
    setState(() {
      accepted = latest!;
      latest = null;
      draft = result.value;
      choices.clear();
      message = '已合并最新配置，当前编辑仍未保存。请检查后保存。';
    });
  }

  List<Widget> review() {
    final remote = latest;
    if (remote == null) return [if (message != null) ModelNotice(message!)];
    ConfigurationRebase result;
    try {
      result = rebaseConfiguration(accepted, draft, remote, useLocal: choices);
    } on ConfigurationEditException catch (failure) {
      return [
        if (message != null) ModelNotice(message!),
        ModelNotice('最新配置不能安全合并：$failure\n当前草稿已保留，未执行任何覆盖。'),
      ];
    }
    return [
      if (message != null) ModelNotice(message!),
      PocketSection(
        title: '核对最新配置',
        children: [
          const ModelNotice('远端内容已读取；不会覆盖当前草稿。其他字段会保留最新值。'),
          for (final conflict in result.conflicts)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(configurationPathLabel(conflict.path)),
                  SelectableText(
                    '打开时：${configurationValueLabel(conflict.before)}',
                  ),
                  SelectableText(
                    '我的编辑：${configurationValueLabel(conflict.local)}',
                  ),
                  SelectableText(
                    '最新内容：${configurationValueLabel(conflict.remote)}',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      PocketButton.tonal(
                        onPressed: () =>
                            setState(() => choices[conflict.id] = true),
                        child: const Text('保留我的编辑'),
                      ),
                      PocketButton.tonal(
                        onPressed: () =>
                            setState(() => choices[conflict.id] = false),
                        child: const Text('使用最新内容'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: PocketButton(
              onPressed: result.conflicts.isEmpty ? mergeLatest : null,
              child: const Text('合并并继续检查'),
            ),
          ),
        ],
      ),
    ];
  }
}

class DefaultModelPage extends StatefulWidget {
  const DefaultModelPage({
    required this.runtime,
    required this.snapshot,
    super.key,
  });
  final RuntimeController runtime;
  final ModelsSnapshot snapshot;
  @override
  State<DefaultModelPage> createState() => _DefaultModelPageState();
}

class _DefaultModelPageState extends ModelDraftState<DefaultModelPage> {
  @override
  RuntimeController get runtime => widget.runtime;
  @override
  Json get initialDescriptor =>
      widget.snapshot.descriptor('agent-default-model')!;

  Future<void> save() async {
    if (!await saveDraft()) return;
    runtime.useModelSelection(
      provider: draft['provider'] as String,
      model: draft['model'] as String,
      reasoningEffort: draft['reasoningEffort'] as String?,
    );
    // The core refresh reads the persisted effort as well as the route/model.
    try {
      await runtime.refreshForms();
    } catch (error) {
      if (mounted) setState(() => message = '默认模型已保存，但界面刷新失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () => dirty,
    busy: busy,
    child: PocketScaffold(
      title: const Text('默认模型'),
      trailing: GlassButton(
        icon: Icons.check_rounded,
        label: busy ? '正在保存' : '保存默认模型',
        solid: true,
        onPressed: busy || latest != null || !dirty ? null : save,
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          ...review(),
          const ModelNotice('用于新建会话；已有会话可在聊天中切换模型。'),
          if (!(widget.snapshot.catalog['groups'] as List? ?? []).any(
            (group) =>
                group['id'] == draft['provider'] &&
                (group['models'] as List).any(
                  (model) => model['id'] == draft['model'],
                ),
          ))
            ModelNotice(
              '当前保存的模型暂未出现在目录中：${draft['provider']} / ${draft['model']}。',
            ),
          for (final group in widget.snapshot.catalog['groups'] as List? ?? [])
            PocketSection(
              title: '${group['name']}',
              children: [
                for (final model in group['models'] as List)
                  PocketTile(
                    title: Text('${model['name'] ?? model['id']}'),
                    subtitle: model['description'] != null
                        ? Text('${model['description']}')
                        : model['name'] != model['id']
                        ? Text('${model['id']}')
                        : null,
                    trailing:
                        draft['provider'] == group['id'] &&
                            draft['model'] == model['id']
                        ? Icon(
                            Icons.check_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    selected:
                        draft['provider'] == group['id'] &&
                        draft['model'] == model['id'],
                    onTap: busy
                        ? null
                        : () {
                            if (draft['provider'] == group['id'] &&
                                draft['model'] == model['id']) {
                              return;
                            }
                            setState(() {
                              draft['provider'] = group['id'];
                              draft['model'] = model['id'];
                              draft.remove('reasoningEffort');
                              choices.clear();
                            });
                          },
                  ),
                for (final model in group['models'] as List)
                  if (draft['provider'] == group['id'] &&
                      draft['model'] == model['id'] &&
                      (model['reasoning']?['efforts'] as List? ?? [])
                          .isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('推理强度'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              PocketChoice(
                                label: const Text('服务商默认'),
                                selected: draft['reasoningEffort'] == null,
                                onSelected: busy
                                    ? null
                                    : (_) => field(
                                        ['reasoningEffort'],
                                        null,
                                        unset: true,
                                      ),
                              ),
                              for (final effort
                                  in model['reasoning']['efforts'] as List)
                                PocketChoice(
                                  label: Text('${effort['name']}'),
                                  selected:
                                      draft['reasoningEffort'] == effort['id'],
                                  onSelected: busy
                                      ? null
                                      : (_) => field([
                                          'reasoningEffort',
                                        ], effort['id']),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          const ModelNotice('推理档位来自该模型的真实能力。更换模型会清除上一个模型的档位。'),
        ],
      ),
    ),
  );
}
