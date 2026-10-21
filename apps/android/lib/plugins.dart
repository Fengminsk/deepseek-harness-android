import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'plugins_data.dart';
import 'metadata_artwork.dart';
import 'runtime.dart';
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
    super.dispose();
  }

  Future<void> open(Widget page) async {
    await Navigator.push(context, PocketRoute<void>(builder: (_) => page));
    if (mounted) await controller.load();
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
          padding: const EdgeInsets.all(20),
          children: [
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
            if (controller.error != null) PluginNotice(controller.error!),
            if (controller.actionMessage != null)
              PluginNotice(controller.actionMessage!),
            if (controller.inventory == null)
              PluginNotice(controller.loading ? '正在读取插件清单。' : '暂时无法读取插件清单。'),
            if (controller.inventory != null && !controller.managementAvailable)
              const PluginNotice('当前运行时没有提供持久化插件管理。以下为真实运行清单，不能在此切换。'),
            if (controller.managementAvailable)
              PocketSection(
                title: '已选用 · ${selected.length}',
                divided: true,
                children: [
                  for (final bundle in selected)
                    _PluginBundleRow(
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
  const _PluginBundleRow({required this.bundle, required this.onTap});
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
          padding: const EdgeInsets.all(20),
          children: [
            if (controller.error != null) PluginNotice(controller.error!),
            if (available.isEmpty) const PluginNotice('没有未选用的插件包。'),
            for (final group in [
              (title: '随应用提供', bundles: bundled),
              (title: '已添加到配置', bundles: installed),
              (title: '其他插件包', bundles: other),
            ])
              if (group.bundles.isNotEmpty)
                PocketSection(
                  title: '${group.title} · ${group.bundles.length}',
                  divided: true,
                  children: [
                    for (final bundle in group.bundles)
                      _PluginBundleRow(
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
        padding: const EdgeInsets.all(20),
        children: [
          if (controller.error != null) PluginNotice(controller.error!),
          if (controller.actionMessage != null)
            PluginNotice(controller.actionMessage!),
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
        title: '运行时条目',
        divided: true,
        children: [
          for (final entry in controller.entries)
            PluginEntryRow(controller: controller, entry: entry),
        ],
      ),
      for (final preset in controller.inventory?['agentPresets'] as List? ?? [])
        PocketSection(
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
    return PocketSwitchRow(
      leading: pluginArtwork(entry),
      title: Text(pluginName(entry)),
      subtitle: Text(
        '${entry['moduleName']}\n$id · ${entry['fiberPhase'] ?? '未加载'}'
        '${entry['readOnlyReason'] == null ? '' : '\n${entry['readOnlyReason']}'}',
      ),
      value: entry['enabled'] == true,
      onChanged: !writable || controller.actions.contains(id)
          ? null
          : (value) => controller.change(id, 'setPluginEnabled', {
              'id': id,
              'enabled': value,
            }),
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
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      Json? bundle;
      for (final item in widget.controller.bundles) {
        if (item['name'] == widget.name) {
          bundle = item;
          break;
        }
      }
      final current = bundle;
      final busy = widget.controller.actions.contains(widget.name);
      return PocketScaffold(
        title: Text(current == null ? widget.name : pluginName(current)),
        body: PocketList(
          padding: const EdgeInsets.all(20),
          children: [
            if (widget.controller.error != null)
              PluginNotice(widget.controller.error!),
            if (widget.controller.actionMessage != null)
              PluginNotice(widget.controller.actionMessage!),
            if (current == null) const PluginNotice('此插件包已不在最新目录中。'),
            if (current != null) ...[
              PocketSection(
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
                    subtitle: Text(
                      current['readOnlyReason'] == null
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
                title: '包含条目',
                divided: true,
                children: [
                  for (final row in current['rows'] as List? ?? [])
                    Builder(
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
              PocketDisclosure(
                title: '插件包信息与诊断',
                child: SelectableText(
                  [
                    '包名：${widget.name}',
                    '位置：${current['availability']}',
                    if (current['source'] != null) '来源：${current['source']}',
                    if (current['error'] != null)
                      const JsonEncoder.withIndent('  ')
                          .convert(current['error']),
                  ].join('\n'),
                ),
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
                  PocketDisclosure(
                    title: '安装请求详情',
                    child: SelectableText(
                      '核心阶段：${controller.installPhase}\n请求：${controller.requestId}',
                    ),
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
                    PocketDisclosure(
                      title: '安装诊断',
                      child: SelectableText(
                        const JsonEncoder.withIndent('  ')
                            .convert(result['packageResult']),
                      ),
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
              PocketDisclosure(
                title: '本次安装输出',
                child: SelectableText(
                  '${controller.logTruncated ? '只显示最近的输出；完整结果见安装诊断。\n' : ''}'
                  '${controller.logs.map((chunk) => chunk['text']).join()}',
                ),
              ),
            if (!controller.pending)
              const PluginNotice('插件的依赖、启停及安装结果由 DSH 管理。'),
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
