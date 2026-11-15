// 远程设置：查看那台电脑上的设置目录，并修改电脑的默认模型路由。
//
// 数据来自注入的 [RemoteDshSettingsSource]：生产实现是 `RemoteDshLiveSource`
// （`settings.describe` / `settings.mutate`），测试可以注入替身，因此本页不认识
// 门面方法名。可选的 [RemoteDshModelCatalogSource] 提供电脑上的模型目录，让默认
// 模型的 provider/model 变成可选项；没有实现或读取失败时退回手动填写。
//
// 门控按协议 §10.2：能力不可用时整页只显示原因。电脑返回的设置值已由宿主脱敏，
// 本页对 `secrets` 标注的槽位只显示「已配置 / 未配置」，绝不显示凭据本身。
// 唯一可写的是默认模型路由；其余各节只读展示。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'flclash/typography.dart';
import 'model_reasoning.dart';
import 'remote_dsh_live_source.dart';
import 'ui.dart';

/// 远程 DSH 的设置页。
///
/// [source] 提供设置读取与默认模型写入；[catalogSource] 可选，用于把默认模型的
/// provider/model 变成候选列表（`session.modelCatalog`）。
class RemoteDshSettingsPage extends StatefulWidget {
  const RemoteDshSettingsPage({
    super.key,
    required this.source,
    this.catalogSource,
  });

  /// 本页作为全屏目的地的标识（见 [openDestination]）。
  static const String routeDestination = 'remote-dsh-settings';

  /// 设置数据来源。
  final RemoteDshSettingsSource source;

  /// 可选的模型目录来源；没有实现时默认模型只能手动填写。
  final RemoteDshModelCatalogSource? catalogSource;

  @override
  State<RemoteDshSettingsPage> createState() => _RemoteDshSettingsPageState();
}

class _RemoteDshSettingsPageState extends State<RemoteDshSettingsPage> {
  /// 能力状态在页面打开时取一次：之后连接变化由读取失败与重试提示体现。
  late final RemoteDshCapability _capability = widget.source.settingsCapability;

  /// 最近一次读到的设置目录；为 null 表示还没读到。
  RemoteDshSettingsSnapshot? _snapshot;

  /// 读取失败的中文说明。
  String? _error;

  /// 成功或版本冲突的可见提示。
  String? _notice;

  /// 上一次提示是否为「设置已被改动」的冲突提示。
  bool _conflict = false;

  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (_capability.isAvailable) unawaited(_load());
  }

  /// 读取整份设置；[keepMessage] 为 true 时保留冲突/成功提示（冲突后重读用）。
  Future<void> _load({bool keepMessage = false}) async {
    if (!mounted || !_capability.isAvailable || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (!keepMessage) {
        _notice = null;
        _conflict = false;
      }
    });
    try {
      final snapshot = await widget.source.describeSettings();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _messageOf(error);
      });
    }
  }

  /// 打开模型选择弹层，应用成功后写回电脑。
  Future<void> _changeDefaultModel(
    RemoteDshSettingsSection section,
    RemoteDshModelRoute current,
  ) async {
    final route = await showModalBottomSheet<RemoteDshModelRoute>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .4),
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (_) => _DefaultModelSheet(
        current: current,
        catalogSource: widget.catalogSource,
      ),
    );
    if (!mounted || route == null) return;
    if (route == current) {
      _showStatus('默认模型路由没有变化。');
      return;
    }
    await _saveDefaultModel(section, route);
  }

  /// 用读取时的 revision 写回默认模型；冲突时重读并留下可重试的提示。
  Future<void> _saveDefaultModel(
    RemoteDshSettingsSection section,
    RemoteDshModelRoute route,
  ) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
      _conflict = false;
    });
    try {
      final snapshot = await widget.source.saveDefaultModel(
        route: route,
        revision: section.revision,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _saving = false;
        _conflict = false;
        _notice = '已应用新的默认模型：${route.label}';
      });
      _showStatus('已应用新的默认模型：${route.label}');
    } on PlatformException catch (failure) {
      if (!mounted) return;
      if (_isConflict(failure)) {
        setState(() {
          _saving = false;
          _conflict = true;
        });
        // 先重读最新设置：旧的 revision 已经不能再用，重试必须基于新内容。
        await _load(keepMessage: true);
        if (!mounted) return;
        setState(() {
          _notice = '设置已在电脑上被修改，已重新读取。请确认最新的默认模型后重新应用。';
        });
        return;
      }
      setState(() {
        _saving = false;
        _error = _messageOf(failure);
      });
      _showStatus('未能修改默认模型：${_messageOf(failure)}');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _messageOf(error);
      });
      _showStatus('未能修改默认模型：${_messageOf(error)}');
    }
  }

  /// 旧版本被拒绝写入的稳定错误码：协议写 `settings/conflict`，当前门面透传
  /// 设置服务的 `SETTINGS_CONFLICT`；两个都按版本冲突处理。
  static bool _isConflict(PlatformException failure) =>
      failure.code == 'settings/conflict' ||
      failure.code == 'SETTINGS_CONFLICT';

  /// 可展示的中文说明：门面失败一律是 `PlatformException`。
  static String _messageOf(Object error) {
    if (error is PlatformException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) return message;
    }
    return '读取电脑设置失败，请检查连接后重试。';
  }

  /// 显示一条可见的短提示；页面内也保留 [_notice] 供重读后仍能看到。
  void _showStatus(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('设置'),
    trailing: GlassButton(
      key: const ValueKey('remote-settings-refresh'),
      icon: Icons.refresh_rounded,
      label: '刷新电脑设置',
      onPressed: _capability.isAvailable && !_loading
          ? () => unawaited(_load())
          : null,
    ),
    body: _content(),
  );

  Widget _content() {
    final capability = _capability;
    if (!capability.isAvailable) {
      return PocketEmpty(
        child: _SettingsNotice(
          icon: Icons.settings_outlined,
          title: '这台电脑不支持远程设置',
          message: capability.reason ?? '这台电脑没有声明设置能力。',
        ),
      );
    }
    final snapshot = _snapshot;
    if (snapshot == null) {
      if (_error != null) {
        return PocketEmpty(
          child: _SettingsNotice(
            icon: Icons.cloud_off_rounded,
            title: '读取电脑设置失败',
            message: _error!,
            actionLabel: '重试',
            onAction: _loading ? null : () => unawaited(_load()),
          ),
        );
      }
      return const PocketEmpty(
        child: _SettingsNotice(
          icon: Icons.hourglass_top_rounded,
          title: '正在读取电脑设置',
          message: '设置会从这台电脑读取；电脑侧已经隐藏了凭据内容。',
        ),
      );
    }
    return PocketList(
      key: const ValueKey('remote-settings-list'),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: <Widget>[
        if (_loading) const _SettingsNote('正在重新读取电脑设置…'),
        if (_notice != null)
          _SettingsBanner(
            key: const ValueKey('remote-settings-notice'),
            message: _notice!,
            conflict: _conflict,
          ),
        if (_error != null)
          _SettingsError(
            message: _error!,
            onRetry: _loading ? null : () => unawaited(_load()),
          ),
        if (!snapshot.writable)
          const _SettingsNote('这台电脑的 profile 当前只接受读取，设置均为只读。'),
        _modelSection(snapshot),
        for (final section in snapshot.sections)
          if (!section.isDefaultModel) _readOnlySection(section),
        if (snapshot.sections.isEmpty) const _SettingsNote('电脑没有返回任何可显示的设置节。'),
      ],
    );
  }

  /// 「默认模型」置顶卡片：当前路由 + 更换入口。
  Widget _modelSection(RemoteDshSettingsSnapshot snapshot) {
    final section = snapshot.defaultModelSection;
    final route = section?.defaultModelRoute;
    return PocketSection(
      key: const ValueKey('remote-settings-model-section'),
      title: '默认模型',
      children: <Widget>[
        if (section == null || route == null)
          const PocketTile(
            leading: Icon(Icons.auto_awesome_outlined),
            title: Text('这台电脑没有提供默认模型设置'),
            subtitle: Text(
              '电脑的 profile 没有暴露 agent-default-model 这一节，只能查看其它设置。',
            ),
          )
        else ...<Widget>[
          PocketTile(
            key: const ValueKey('remote-settings-route'),
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(
              route.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '电脑上的默认模型路由'
              '${route.reasoningEffort == null ? '' : ' · 思考强度：${reasoningEffortLabel(route.reasoningEffort)}'}'
              ' · 版本 ${section.revision}',
            ),
            trailing: GlassButton(
              key: const ValueKey('remote-settings-change-model'),
              icon: Icons.edit_outlined,
              label: '更换默认模型',
              solid: true,
              onPressed:
                  _saving ||
                      _loading ||
                      !snapshot.writable ||
                      !_capability.isAvailable
                  ? null
                  : () => unawaited(_changeDefaultModel(section, route)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              _saving
                  ? '正在把新的默认模型写回电脑…'
                  : '修改会写回电脑上的设置，只影响之后新建的会话；正在进行的会话沿用各自的模型。',
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ],
    );
  }

  /// 其它各节：只读展示普通字段；凭据槽位只显示是否已配置。
  Widget _readOnlySection(RemoteDshSettingsSection section) => PocketSection(
    key: ValueKey<String>('remote-settings-section:${section.ns}'),
    title: section.title,
    children: <Widget>[
      if (section.fields.isEmpty)
        const PocketTile(
          title: Text('这一节没有可显示的普通字段'),
          subtitle: Text('由插件自己管理；这里只展示读取到的内容。'),
        ),
      for (final field in section.fields)
        PocketTile(
          key: ValueKey<String>(
            'remote-setting:${section.ns}:${field.path.join('.')}',
          ),
          leading: Icon(_fieldIcon(field.kind)),
          title: Text(field.label),
          subtitle: Text(
            field.value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
  );

  static IconData _fieldIcon(RemoteDshSettingFieldKind kind) => switch (kind) {
    RemoteDshSettingFieldKind.boolean => Icons.toggle_on_outlined,
    RemoteDshSettingFieldKind.choice => Icons.list_rounded,
    RemoteDshSettingFieldKind.text => Icons.short_text_rounded,
    RemoteDshSettingFieldKind.number => Icons.tag_rounded,
    RemoteDshSettingFieldKind.secret => Icons.lock_outline_rounded,
    RemoteDshSettingFieldKind.structured => Icons.data_object_rounded,
  };
}

/// 默认模型选择弹层：模型目录、推理强度与当前路由。
///
/// 只负责选择，不写设置：应用成功后把选中的路由交回页面，由页面带着读取时的
/// revision 调 `settings.mutate`。这样版本冲突、重读与提示都只有一处归属。
class _DefaultModelSheet extends StatefulWidget {
  const _DefaultModelSheet({required this.current, this.catalogSource});

  /// 当前路由，用于高亮与「没有变化」判断。
  final RemoteDshModelRoute current;

  /// 可选的模型目录来源；为 null 或读取失败时手动填写。
  final RemoteDshModelCatalogSource? catalogSource;

  @override
  State<_DefaultModelSheet> createState() => _DefaultModelSheetState();
}

class _DefaultModelSheetState extends State<_DefaultModelSheet> {
  final _provider = TextEditingController();
  final _model = TextEditingController();
  final _effort = TextEditingController();

  RemoteDshModelCatalog? _catalog;
  late RemoteDshModelRoute _selected = widget.current;
  bool _loading = true;
  String? _catalogError;
  String? _manualError;

  @override
  void initState() {
    super.initState();
    _provider.text = widget.current.provider;
    _model.text = widget.current.model;
    _effort.text = widget.current.reasoningEffort ?? '';
    unawaited(_loadCatalog());
  }

  @override
  void dispose() {
    _provider.dispose();
    _model.dispose();
    _effort.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    final source = widget.catalogSource;
    if (source == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _catalogError = null;
    });
    try {
      final catalog = await source.describeModelCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _catalogError = error is PlatformException
            ? (error.message?.trim().isNotEmpty == true
                  ? error.message!.trim()
                  : '读取模型目录失败。')
            : '读取模型目录失败：$error';
        _loading = false;
      });
    }
  }

  /// 当前选中模型声明的推理强度；没有目录或没选模型时为空。
  RemoteDshModelReasoning? get _selectedReasoning {
    final catalog = _catalog;
    if (catalog == null) return null;
    for (final group in catalog.groups) {
      if (group.id != _selected.provider) continue;
      for (final model in group.models) {
        if (model.id == _selected.model) return model.reasoning;
      }
    }
    return null;
  }

  bool get _canApply {
    if (_loading) return false;
    if (_catalog == null || _catalog!.isEmpty) {
      return _provider.text.trim().isNotEmpty && _model.text.trim().isNotEmpty;
    }
    return _selected != widget.current;
  }

  void _choose(RemoteDshModelGroup group, RemoteDshModel model) {
    setState(() {
      // 换模型时清掉推理强度：新模型不一定声明同一档位。
      _selected = RemoteDshModelRoute(provider: group.id, model: model.id);
    });
  }

  void _chooseEffort(String? effort) {
    setState(() {
      _selected = RemoteDshModelRoute(
        provider: _selected.provider,
        model: _selected.model,
        reasoningEffort: effort,
      );
    });
  }

  void _apply() {
    final catalog = _catalog;
    if (catalog == null || catalog.isEmpty) {
      final provider = _provider.text.trim();
      final model = _model.text.trim();
      if (provider.isEmpty || model.isEmpty) {
        setState(() => _manualError = '请填写服务商与模型。');
        return;
      }
      final effort = _effort.text.trim();
      Navigator.of(context).pop(
        RemoteDshModelRoute(
          provider: provider,
          model: model,
          reasoningEffort: effort.isEmpty ? null : effort,
        ),
      );
      return;
    }
    Navigator.of(context).pop(_selected);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.only(top: 10),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        child: GlassSurface(
          radius: AppCorner.xxl,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: 6),
              SizedBox(
                height: 48,
                child: Row(
                  children: <Widget>[
                    const SizedBox(width: 48),
                    Expanded(
                      child: Text(
                        '更换默认模型',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: AppTextStyle.headline.of(
                          context,
                          emphasized: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: GlassButton(
                        icon: Icons.close_rounded,
                        label: '关闭默认模型选择',
                        onPressed: () => Navigator.maybePop(context),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(child: _body(context)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: PocketButton(
                  key: const ValueKey('remote-settings-model-apply'),
                  onPressed: _canApply ? _apply : null,
                  child: Text(
                    _catalog == null || _catalog!.isEmpty
                        ? '应用默认模型'
                        : _selected == widget.current
                        ? '已是当前模型'
                        : '应用此模型',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final catalog = _catalog;
    if (catalog == null) {
      return _manualBody(context, note: _catalogError);
    }
    if (catalog.isEmpty) {
      return _manualBody(
        context,
        note: catalog.failures.isEmpty
            ? '这台电脑还没有可用的模型目录，可以手动填写服务端已配置的服务商与模型。'
            : null,
        failures: catalog.failures,
      );
    }
    final reasoning = _selectedReasoning;
    final efforts = reasoning?.efforts ?? const <RemoteDshReasoningLevel>[];
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: Text(
              '当前：${widget.current.label}'
              '${widget.current.reasoningEffort == null ? '' : ' · ${reasoningEffortLabel(widget.current.reasoningEffort)}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          for (final failure in catalog.failures)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(
                failure,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.error),
              ),
            ),
          for (final group in catalog.groups)
            PocketSection(
              title: group.name,
              children: <Widget>[
                for (final model in group.models) _modelTile(group, model),
              ],
            ),
          if (efforts.isNotEmpty)
            PocketSection(
              title: '思考强度',
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SegmentedControl<String?>(
                    key: const ValueKey('remote-settings-reasoning'),
                    segments: <(String?, String)>[
                      (null, '默认'),
                      for (final effort in efforts)
                        (
                          effort.id,
                          reasoningEffortLabel(
                            effort.id,
                            fallback: effort.name,
                          ),
                        ),
                    ],
                    value: _selected.reasoningEffort,
                    onChanged: _chooseEffort,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 手动填写：没有模型目录时仍然可以改路由（例如宿主的目录读取暂时失败）。
  Widget _manualBody(
    BuildContext context, {
    String? note,
    List<String> failures = const <String>[],
  }) {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                note,
                key: const ValueKey('remote-settings-catalog-note'),
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          for (final failure in failures)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                failure,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.error),
              ),
            ),
          TextField(
            key: const ValueKey('remote-settings-provider'),
            controller: _provider,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '服务商（provider）'),
            onChanged: (_) => setState(() => _manualError = null),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('remote-settings-model'),
            controller: _model,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '模型（model）'),
            onChanged: (_) => setState(() => _manualError = null),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('remote-settings-effort'),
            controller: _effort,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '思考强度（可选）'),
            onChanged: (_) => setState(() => _manualError = null),
          ),
          if (_manualError != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _manualError!,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.error),
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 14),
            child: Text(
              '填写电脑上已配置的服务商与模型 id，例如 deepseek-account / deepseek-flash。',
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelTile(RemoteDshModelGroup group, RemoteDshModel model) {
    final colors = Theme.of(context).colorScheme;
    final selected =
        _selected.provider == group.id && _selected.model == model.id;
    final current =
        widget.current.provider == group.id && widget.current.model == model.id;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: PocketTile(
        key: ValueKey<String>('remote-settings-model:${group.id}:${model.id}'),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 12,
        ),
        leading: Icon(
          selected
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          color: selected ? colors.primary : colors.outline,
        ),
        title: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: selected && !current
            ? const Text('待应用')
            : current
            ? const Text('电脑当前默认')
            : null,
        onTap: () => _choose(group, model),
      ),
    );
  }
}

/// 空态与读取失败共用的居中提示。
class _SettingsNotice extends StatelessWidget {
  const _SettingsNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final actionLabel = this.actionLabel;
    final onAction = this.onAction;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 40, color: colors.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: AppTextStyle.title3.of(context, emphasized: true),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(color: colors.onSurfaceVariant),
        ),
        if (actionLabel != null && onAction != null) ...<Widget>[
          const SizedBox(height: 20),
          PocketButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ],
    );
  }
}

/// 成功/冲突提示条；冲突用警告色标出可重试的状态。
class _SettingsBanner extends StatelessWidget {
  const _SettingsBanner({
    super.key,
    required this.message,
    required this.conflict,
  });

  final String message;
  final bool conflict;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = conflict ? colors.error : colors.primary;
    return PocketSection(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                conflict
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline_rounded,
                color: tint,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  message,
                  style: AppTextStyle.footnote.of(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 读取/写入失败提示：宿主消息原样展示，并给出重试入口。
class _SettingsError extends StatelessWidget {
  const _SettingsError({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PocketSection(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.cloud_off_rounded, color: colors.error, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  message,
                  style: AppTextStyle.footnote.of(context),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: PocketButton.tonal(
              key: const ValueKey('remote-settings-retry'),
              onPressed: onRetry,
              child: const Text('重试读取'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 一行说明文字。
class _SettingsNote extends StatelessWidget {
  const _SettingsNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    child: SelectableText(text),
  );
}
