import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'plugins_data.dart';
import 'metadata_artwork.dart';
import 'runtime.dart';
import 'text_document_page.dart';
import 'ui.dart';

PluginsController pluginsFor(RuntimeController runtime) => runtime.plugins;

class PluginsPage extends StatefulWidget {
  const PluginsPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> with WidgetsBindingObserver {
  late final controller = pluginsFor(widget.runtime);
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.attach();
    unawaited(controller.load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(controller.load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.detach();
    scroll.dispose();
    super.dispose();
  }

  Future<void> open(Widget page) async {
    await Navigator.push(context, PocketRoute<void>(builder: (_) => page));
    if (mounted && !controller.fresh) await controller.load();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final selected = controller.bundles
          .where((bundle) => bundle['enabled'] == true)
          .toList();
      final available = controller.bundles.length - selected.length;
      final presets = controller.inventory?['agentPresets'] as List? ?? [];
      return PocketScaffold(
        title: const Text('插件管理'),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '刷新插件',
          onPressed: controller.loading ? null : controller.load,
        ),
        body: PocketList(
          key: const PageStorageKey('plugins-overview'),
          controller: scroll,
          padding: const EdgeInsets.all(20),
          children: [
            _PluginReadStatus(controller: controller),
            if (controller.managementAvailable)
              PocketSection(
                children: [
                  PocketRow(
                    icon: controller.pending
                        ? Icons.downloading_rounded
                        : Icons.add_rounded,
                    title: controller.pending ? '查看进行中的安装' : '安装插件包',
                    subtitle: controller.pending
                        ? '安装仍在继续，可查看进度或取消'
                        : controller.installError != null
                        ? '上次安装需要处理，点按查看'
                        : controller.installResult != null
                        ? '查看上次安装结果或安装新插件'
                        : '从包名、Git 地址或设备文件安装',
                    onTap: () =>
                        open(PluginInstallPage(controller: controller)),
                  ),
                  PocketRow(
                    icon: Icons.extension_outlined,
                    title: '可用插件包',
                    subtitle: '$available 个未选用的插件包',
                    onTap: () =>
                        open(PluginCatalogPage(controller: controller)),
                  ),
                  PocketRow(
                    icon: Icons.tune_rounded,
                    title: '运行时条目与预设',
                    subtitle:
                        '${controller.entries.length} 个条目 · ${presets.length} 个预设',
                    onTap: () =>
                        open(PluginRuntimePage(controller: controller)),
                  ),
                ],
              ),
            if (controller.inventory == null)
              PluginNotice(controller.loading ? '正在读取插件清单。' : '暂时无法读取插件清单。'),
            if (controller.inventory != null && !controller.managementAvailable)
              const PluginNotice('当前运行时没有提供持久化插件管理。以下为真实运行清单，不能在此切换。'),
            if (controller.managementAvailable)
              PocketSection(
                key: const ValueKey('selected-bundles'),
                title: '已选用 · ${selected.length}',
                divided: true,
                children: [
                  for (final bundle in selected)
                    _PluginBundleRow(
                      key: ValueKey<String>(bundle['name'] as String),
                      bundle: bundle,
                      onTap: () => open(
                        PluginBundlePage(
                          controller: controller,
                          name: bundle['name'] as String,
                        ),
                      ),
                    ),
                  if (selected.isEmpty)
                    const PocketRow(
                      icon: Icons.extension_outlined,
                      title: '尚未选用插件包',
                      subtitle: '可在“可用插件包”中查看并启用',
                    ),
                ],
              ),
            if (!controller.managementAvailable)
              _PluginRuntimeSections(controller: controller),
          ],
        ),
      );
    },
  );
}

class _PluginBundleRow extends StatelessWidget {
  const _PluginBundleRow({
    required this.bundle,
    required this.onTap,
    super.key,
  });
  final Json bundle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => PocketRow(
    icon: Icons.inventory_2_outlined,
    leading: pluginArtwork(bundle),
    title: pluginName(bundle),
    subtitle: [
      _bundleAvailability(bundle),
      if (bundle['version'] != null) '${bundle['version']}',
      if (bundle['error'] != null) '需要处理',
    ].join(' · '),
    onTap: onTap,
  );
}

String _bundleAvailability(Json bundle) => switch (bundle['availability']) {
  'installation' => '随应用提供',
  'profile' => '已在设备上',
  'missing' => bundle['installed'] == true ? '安装文件缺失' : '尚未安装',
  _ => '${bundle['availability']}',
};

class PluginCatalogPage extends StatelessWidget {
  const PluginCatalogPage({required this.controller, super.key});
  final PluginsController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final available = controller.bundles
          .where((bundle) => bundle['enabled'] != true)
          .toList();
      final bundled = available
          .where((bundle) => bundle['availability'] == 'installation')
          .toList();
      final installed = available
          .where(
            (bundle) =>
                bundle['availability'] != 'installation' &&
                bundle['installed'] == true,
          )
          .toList();
      final other = available
          .where(
            (bundle) =>
                bundle['availability'] != 'installation' &&
                bundle['installed'] != true,
          )
          .toList();
      return PocketScaffold(
        title: const Text('可用插件包'),
        body: PocketList(
          key: const PageStorageKey('plugin-catalog'),
          padding: const EdgeInsets.all(20),
          children: [
            _PluginReadStatus(controller: controller),
            if (available.isEmpty) const PluginNotice('没有未选用的插件包。'),
            for (final group in [
              (title: '随应用提供', bundles: bundled),
              (title: '已添加到配置', bundles: installed),
              (title: '其他插件包', bundles: other),
            ])
              if (group.bundles.isNotEmpty)
                PocketSection(
                  key: ValueKey(group.title),
                  title: '${group.title} · ${group.bundles.length}',
                  divided: true,
                  children: [
                    for (final bundle in group.bundles)
                      _PluginBundleRow(
                        key: ValueKey(bundle['name']),
                        bundle: bundle,
                        onTap: () => Navigator.push(
                          context,
                          PocketRoute<void>(
                            builder: (_) => PluginBundlePage(
                              controller: controller,
                              name: bundle['name'] as String,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
          ],
        ),
      );
    },
  );
}

class PluginRuntimePage extends StatelessWidget {
  const PluginRuntimePage({required this.controller, super.key});
  final PluginsController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => PocketScaffold(
      title: const Text('运行时条目与预设'),
      body: PocketList(
        key: const PageStorageKey('plugin-runtime-entries'),
        padding: const EdgeInsets.all(20),
        children: [
          _PluginReadStatus(controller: controller),
          _PluginRuntimeSections(controller: controller),
        ],
      ),
    ),
  );
}

class _PluginRuntimeSections extends StatelessWidget {
  const _PluginRuntimeSections({required this.controller});
  final PluginsController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PocketSection(
        key: const ValueKey('runtime-entries'),
        title: '运行时条目',
        divided: true,
        children: [
          for (final entry in controller.entries)
            PluginEntryRow(
              key: ValueKey<String>(entry['entryId'] as String),
              controller: controller,
              entry: entry,
            ),
        ],
      ),
      for (final preset in controller.inventory?['agentPresets'] as List? ?? [])
        PocketSection(
          key: ValueKey('preset:${preset['id'] ?? preset['name']}'),
          title: '预设 · ${preset['name'] ?? preset['id']}',
          children: [
            if (preset['broken'] != null) PluginNotice('${preset['broken']}'),
            for (final entry in preset['rows'] as List? ?? [])
              PocketRow(
                icon: Icons.extension_outlined,
                leading: pluginArtwork(entry as Json),
                title: pluginName(entry),
                subtitle:
                    '${entry['moduleName']}\n'
                    '${entry['enabled'] == 'conditional'
                        ? '按条件启用'
                        : entry['enabled'] == true
                        ? '启用'
                        : '停用'}'
                    ' · ${entry['fiberPhase'] ?? '未加载'}',
              ),
          ],
        ),
    ],
  );
}

class PluginEntryRow extends StatelessWidget {
  const PluginEntryRow({
    required this.controller,
    required this.entry,
    super.key,
  });
  final PluginsController controller;
  final Json entry;
  @override
  Widget build(BuildContext context) {
    final id = entry['entryId'] as String;
    final writable =
        controller.managementAvailable && entry['readOnlyReason'] == null;
    final action = controller.actionFor(id);
    return ListenableBuilder(
      listenable: action,
      builder: (context, _) => PocketSwitchRow(
        leading: pluginArtwork(entry),
        title: Text(pluginName(entry)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${entry['moduleName']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            _PluginActionStatus(
              controller: controller,
              target: id,
              idle: entry['readOnlyReason'] == null
                  ? '$id · ${entry['fiberPhase'] ?? '未加载'}'
                  : '${entry['readOnlyReason']}',
            ),
          ],
        ),
        value: entry['enabled'] == true,
        onChanged: !writable || !controller.canChange(id)
            ? null
            : (value) => controller.change(id, 'setPluginEnabled', {
                'id': id,
                'enabled': value,
              }),
      ),
    );
  }
}

class PluginBundlePage extends StatefulWidget {
  const PluginBundlePage({
    required this.controller,
    required this.name,
    super.key,
  });
  final PluginsController controller;
  final String name;
  @override
  State<PluginBundlePage> createState() => _PluginBundlePageState();
}

class _PluginBundlePageState extends State<PluginBundlePage> {
  bool removeReview = false;
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller,
      widget.controller.actionFor(widget.name),
    ]),
    builder: (context, _) {
      Json? bundle;
      for (final item in widget.controller.bundles) {
        if (item['name'] == widget.name) {
          bundle = item;
          break;
        }
      }
      final current = bundle;
      final busy = !widget.controller.canChange(widget.name);
      return PocketScaffold(
        title: Text(current == null ? widget.name : pluginName(current)),
        body: PocketList(
          key: PageStorageKey('plugin-bundle:${widget.name}'),
          controller: scroll,
          padding: const EdgeInsets.all(20),
          children: [
            _PluginReadStatus(controller: widget.controller),
            if (current == null) const PluginNotice('此插件包已不在最新目录中。'),
            if (current != null) ...[
              PocketSection(
                key: const ValueKey('bundle-controls'),
                title: '插件包',
                children: [
                  PocketRow(
                    icon: Icons.inventory_2_outlined,
                    leading: pluginArtwork(current, size: 36),
                    title: pluginName(current),
                    subtitle:
                        '${_bundleAvailability(current)} · 版本 ${current['version'] ?? '未声明'}',
                  ),
                  if (pluginText(
                    current['meta']?['description'],
                    current['description'] as String? ?? '',
                  ).isNotEmpty)
                    PluginNotice(
                      pluginText(
                        current['meta']?['description'],
                        current['description'] as String? ?? '',
                      ),
                    ),
                  PocketSwitchRow(
                    title: const Text('启用插件包'),
                    subtitle: _PluginActionStatus(
                      controller: widget.controller,
                      target: widget.name,
                      idle: current['readOnlyReason'] == null
                          ? '保存后由 DSH 应用变更'
                          : '${current['readOnlyReason']}',
                    ),
                    value: current['enabled'] == true,
                    onChanged:
                        busy ||
                            current['readOnlyReason'] != null ||
                            current['availability'] == 'missing' ||
                            !widget.controller.managementAvailable
                        ? null
                        : (enabled) => widget.controller.change(
                            widget.name,
                            'setBundleEnabled',
                            {'name': widget.name, 'enabled': enabled},
                          ),
                  ),
                  if (current['error'] != null)
                    const PluginNotice('此插件包需要处理，请查看下方诊断。'),
                  if (current['installTarget'] != null)
                    PocketRow(
                      icon: Icons.download_outlined,
                      title: '核对核心提供的安装版本',
                      subtitle: '${current['installTarget']['version']}',
                      onTap:
                          widget.controller.pending ||
                              widget.controller.checking ||
                              !widget.controller.managementAvailable ||
                              current['readOnlyReason'] != null
                          ? null
                          : () {
                              final spec =
                                  current['installTarget']['spec'] as String;
                              widget.controller.editSpec(
                                spec,
                                exact: !spec.startsWith('link:'),
                              );
                              Navigator.push(
                                context,
                                PocketRoute<void>(
                                  builder: (_) => PluginInstallPage(
                                    controller: widget.controller,
                                  ),
                                ),
                              );
                            },
                    ),
                  if (current['removable'] == true)
                    PocketRow(
                      icon: Icons.delete_outline_rounded,
                      title: '卸载插件包',
                      onTap: busy
                          ? null
                          : () => setState(() => removeReview = true),
                    ),
                ],
              ),
              PocketSection(
                key: const ValueKey('bundle-entries'),
                title: '包含条目',
                divided: true,
                children: [
                  for (final row in current['rows'] as List? ?? [])
                    Builder(
                      key: ValueKey(row['entryId'] ?? row['rowId']),
                      builder: (context) {
                        Json? live;
                        for (final entry in widget.controller.entries) {
                          if (entry['entryId'] == row['entryId']) {
                            live = entry;
                            break;
                          }
                        }
                        return live == null
                            ? PocketRow(
                                icon: Icons.extension_outlined,
                                leading: pluginArtwork(row as Json),
                                title: pluginName(row),
                                subtitle: '${row['rowId']} · 尚未加载',
                              )
                            : PluginEntryRow(
                                controller: widget.controller,
                                entry: live,
                              );
                      },
                    ),
                ],
              ),
              if ((current['overrides'] as List? ?? []).isNotEmpty)
                PluginNotice(
                  '此包还修改以下已有条目：\n${(current['overrides'] as List).join('\n')}',
                ),
              TextDocumentRow(
                title: '插件包信息与诊断',
                text: [
                  '包名：${widget.name}',
                  '位置：${current['availability']}',
                  if (current['source'] != null) '来源：${current['source']}',
                  if (current['error'] != null)
                    const JsonEncoder.withIndent('  ')
                        .convert(current['error']),
                ].join('\n'),
                monospace: true,
              ),
              if (removeReview)
                PocketSection(
                  title: '确认卸载 ${pluginName(current)}',
                  children: [
                    const PluginNotice(
                      '将请求 DSH 移除该插件包。正在使用、受保护或需要先停止服务的插件由核心拒绝并说明原因。',
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          PocketButton.tonal(
                            onPressed: busy
                                ? null
                                : () => setState(() => removeReview = false),
                            child: const Text('保留插件'),
                          ),
                          PocketButton(
                            onPressed: busy
                                ? null
                                : () async {
                                    await widget.controller.change(
                                      widget.name,
                                      'removeBundle',
                                      {'name': widget.name},
                                    );
                                    if (mounted) {
                                      setState(() => removeReview = false);
                                    }
                                  },
                            child: const Text('确认卸载'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ],
        ),
      );
    },
  );
}

class PluginInstallPage extends StatefulWidget {
  const PluginInstallPage({required this.controller, super.key});
  final PluginsController controller;
  @override
  State<PluginInstallPage> createState() => _PluginInstallPageState();
}

class _PluginInstallPageState extends State<PluginInstallPage> {
  late final input = TextEditingController(text: widget.controller.spec);
  late final registry = TextEditingController(text: widget.controller.registry);
  final approved = <String>{};
  @override
  void dispose() {
    input.dispose();
    registry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final disabled = controller.pending || controller.checking;
      final result = controller.installResult;
      final pendingBuilds = (result?['pendingBuilds'] as List? ?? [])
          .cast<String>();
      final inspection = controller.inspection;
      return PocketScaffold(
        title: const Text('安装插件包'),
        body: PocketList(
          padding: const EdgeInsets.all(20),
          children: [
            if (controller.installError != null)
              PluginNotice(controller.installError!),
            if (controller.pending)
              PocketSection(
                title: '安装进行中',
                children: [
                  const PluginNotice('关闭此页不会取消安装，可稍后返回查看结果。'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        PocketButton.tonal(
                          onPressed: controller.cancelling
                              ? null
                              : controller.cancel,
                          child: Text(
                            controller.cancelling ? '正在请求取消' : '取消本次安装',
                          ),
                        ),
                        PocketButton.tonal(
                          onPressed: controller.recovering
                              ? null
                              : controller.recover,
                          child: Text(
                            controller.recovering ? '等待原请求结果' : '核对原请求结果',
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextDocumentRow(
                    title: '安装请求详情',
                    text:
                        '核心阶段：${controller.installPhase}\n请求：${controller.requestId}',
                  ),
                ],
              ),
            if (result != null)
              PocketSection(
                title: '操作结果',
                children: [
                  PluginNotice(pluginChangeSummary(result)),
                  if (result['warnings'] != null)
                    PluginNotice((result['warnings'] as List).join('\n')),
                  if (pendingBuilds.isNotEmpty) ...[
                    const PluginNotice('以下依赖的构建脚本被核心阻止。只有你选择并确认的包会获准运行脚本。'),
                    for (final name in pendingBuilds)
                      PocketSwitchRow(
                        title: Text(name),
                        value: approved.contains(name),
                        onChanged: disabled
                            ? null
                            : (selected) => setState(() {
                                if (selected) {
                                  approved.add(name);
                                } else {
                                  approved.remove(name);
                                }
                              }),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: PocketButton(
                        onPressed: !controller.canInstall || approved.isEmpty
                            ? null
                            : () => controller.install(
                                approvedBuilds: approved
                                    .where(pendingBuilds.contains)
                                    .toList(),
                              ),
                        child: const Text('允许选定脚本并重试'),
                      ),
                    ),
                  ],
                  if (result['packageResult'] != null)
                    TextDocumentRow(
                      title: '安装诊断',
                      text: const JsonEncoder.withIndent('  ')
                          .convert(result['packageResult']),
                      monospace: true,
                    ),
                ],
              ),
            PocketSection(
              title: '安装来源',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: input,
                    enabled: !disabled,
                    onChanged: controller.editSpec,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '包名、Git 地址或设备本地路径',
                    ),
                  ),
                ),
                PocketSwitchRow(
                  title: const Text('安装成功后启用'),
                  value: controller.enableAfterInstall,
                  onChanged: disabled
                      ? null
                      : (value) => setState(
                          () => controller.enableAfterInstall = value,
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: PocketButton.tonal(
                    onPressed: disabled
                        ? null
                        : () async {
                            approved.clear();
                            await controller.inspect();
                          },
                    child: Text(controller.checking ? '正在核对来源' : '核对安装来源'),
                  ),
                ),
                PocketDisclosure(
                  title: controller.registry.isEmpty
                      ? '安装选项'
                      : '安装选项 · 已指定 Registry',
                  child: TextField(
                    controller: registry,
                    enabled: !disabled,
                    onChanged: controller.editRegistry,
                    decoration: const InputDecoration(
                      labelText: 'Registry（可选）',
                      hintText: '留空使用 DSH 配置',
                    ),
                  ),
                ),
              ],
            ),
            if (inspection?['status'] == 'accepted')
              PocketSection(
                title: '来源核对结果',
                children: [
                  PluginNotice(
                    '${inspection!['name'] ?? controller.inspectedSpec}\n'
                    '版本：${inspection['version'] ?? '下载后确定'}\n'
                    '类型：${inspection['kind']} · 插件包：${inspection['bundle'] ?? '尚未确定'}'
                    '${inspection['description'] == null ? '' : '\n${inspection['description']}'}',
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: PocketButton(
                      onPressed: controller.canInstall && pendingBuilds.isEmpty
                          ? controller.install
                          : null,
                      child: const Text('确认安装'),
                    ),
                  ),
                ],
              ),
            if (controller.logs.isNotEmpty)
              TextDocumentRow(
                title: '本次安装输出',
                text:
                    '${controller.logTruncated ? '只显示最近的输出；完整结果见安装诊断。\n' : ''}'
                    '${controller.logs.map((chunk) => chunk['text']).join()}',
                monospace: true,
                helperText: '此页显示打开时的输出，返回安装页可查看最新进度。',
              ),
            if (!controller.pending)
              const PluginNotice('插件的依赖、启停及安装结果由 DSH 管理。'),
          ],
        ),
      );
    },
  );
}

/// These single-line slots exist before, during and after a request. Feedback
/// changes text, never inserts a banner above the scroll position or the switch.
class _PluginReadStatus extends StatelessWidget {
  const _PluginReadStatus({required this.controller});
  final PluginsController controller;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
    child: _PluginStatusLink(
      label: controller.loading
          ? '正在核对插件状态…'
          : controller.fresh
          ? '已读取当前插件状态'
          : '当前状态待核对 · 查看详情',
      onTap: controller.fresh && controller.error == null
          ? null
          : () => _openPluginStatus(context, controller),
    ),
  );
}

class _PluginActionStatus extends StatelessWidget {
  const _PluginActionStatus({
    required this.controller,
    required this.target,
    required this.idle,
  });
  final PluginsController controller;
  final String target, idle;
  @override
  Widget build(BuildContext context) {
    final action = controller.actionFor(target);
    final label = action.running
        ? (action.verifying ? '正在核对当前状态…' : '正在应用变更…')
        : action.awaitingRefresh
        ? '当前状态待核对 · 查看详情'
        : action.unknown
        ? '回执未确认，已核对当前状态 · 详情'
        : action.message != null
        ? '${switch (action.result?['application']) {
            'applied' => action.result?['changed'] == true ? '变更已应用' : '当前配置无需更改',
            'restart-required' => '配置已保存，重启后生效',
            'overridden' => '配置被更高优先级覆盖',
            'failed' => '操作失败',
            _ => '查看操作结果',
          }} · 详情'
        : idle;
    return _PluginStatusLink(
      label: label,
      onTap: action.message == null && !action.awaitingRefresh
          ? null
          : () => _openPluginStatus(context, controller, target: target),
    );
  }
}

class _PluginStatusLink extends StatelessWidget {
  const _PluginStatusLink({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: onTap == null
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

Future<void> _openPluginStatus(
  BuildContext context,
  PluginsController controller, {
  String? target,
}) => Navigator.of(context).push<void>(
  PocketRoute(
    builder: (_) => _PluginStatusPage(controller: controller, target: target),
  ),
);

class _PluginStatusPage extends StatelessWidget {
  const _PluginStatusPage({required this.controller, this.target});
  final PluginsController controller;
  final String? target;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      controller,
      if (target != null) controller.actionFor(target!),
    ]),
    builder: (context, _) {
      final action = target == null ? null : controller.actionFor(target!);
      Json? current;
      if (target != null) {
        for (final row in [...controller.bundles, ...controller.entries]) {
          if (row['name'] == target || row['entryId'] == target) {
            current = row;
            break;
          }
        }
      }
      return PocketScaffold(
        title: Text(target == null ? '插件状态' : '插件操作'),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '核对当前状态',
          onPressed: controller.loading || action?.running == true
              ? null
              : controller.load,
        ),
        body: PocketList(
          children: [
            if (target != null)
              PocketSection(
                title: '插件',
                children: [
                  PocketRow(
                    icon: Icons.extension_rounded,
                    title: current == null ? target! : pluginName(current),
                    subtitle: target,
                  ),
                ],
              ),
            PocketSection(
              title: controller.fresh ? '当前核心状态' : '上次读取的状态',
              children: [
                PluginNotice(
                  target == null
                      ? (controller.fresh ? '插件清单已重新读取。' : '尚未确认当前插件清单。')
                      : current == null
                      ? '此条目已不在最近读取的清单中。'
                      : '配置：${current['enabled'] == true
                                ? '启用'
                                : current['enabled'] == 'conditional'
                                ? '按条件启用'
                                : '停用'}'
                            '${current['fiberPhase'] == null ? '' : '\n运行阶段：${current['fiberPhase']}'}',
                ),
                if (controller.error != null) PluginNotice(controller.error!),
              ],
            ),
            if (action != null)
              PocketSection(
                title: '本次操作',
                children: [
                  PluginNotice(action.message ?? '正在等待核心返回结果。'),
                  if (action.unknown)
                    const PluginNotice('上次操作回执没有得到确认。这里显示当前核心状态，不会自动重发操作。'),
                ],
              ),
          ],
        ),
      );
    },
  );
}

class PluginNotice extends StatelessWidget {
  const PluginNotice(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
    child: SelectableText(text),
  );
}
