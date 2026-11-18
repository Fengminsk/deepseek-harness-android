import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'runtime_selection.dart';
import 'ui.dart';
import 'text_document_page.dart';
import 'files.dart';
import 'appearance.dart';
import 'configuration_editor.dart';
import 'configuration_model_destination.dart';
import 'configuration_value_row.dart';
import 'configuration_transfer.dart';
import 'metadata_artwork.dart';
import 'mcp_servers.dart';
import 'models.dart';
import 'diagnostics.dart';
import 'approvals.dart';
import 'approvals_notifications.dart';
import 'account.dart';
import 'plugins.dart';
import 'background_settings.dart';
import 'credentials.dart';
import 'recovery.dart';
import 'agent_presets.dart';
import 'auto_review_settings.dart';
import 'subagent_model_settings.dart';
import 'web_search_settings.dart';
import 'permission_policy.dart';
import 'settings_general.dart';
import 'session_log_upload_settings.dart';
import 'manual_isolated_script.dart';
import 'network_proxy_settings.dart';
import 'remote_connection.dart';
import 'remote_sync_service.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  Widget build(BuildContext context) {
    void open(Widget page) =>
        Navigator.push(context, PocketRoute<void>(builder: (_) => page));
    return PocketScaffold(
      title: const Text('设置'),
      body: RuntimeSelectionBuilder(
        runtime: runtime,
        select: () => (
          runtime.connectionGeneration,
          runtime.phase,
          runtime.forms,
          runtime.model,
          runtime.interactions.length,
          runtime.web['phase'],
        ),
        builder: (context, _) => PocketList(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 32),
              child: Row(
                children: [
                  PocketMark(size: 46),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pocket Harness',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text('随身的本地 Agent', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            PocketSection(
              title: '通用',
              children: [
                DeveloperToolsSettingsRow(runtime: runtime),
                if (runtime.ready &&
                    runtime.forms.any(
                      (form) => form['ns'] == 'session-log-deepseek',
                    ))
                  SessionLogUploadSettingsRow(runtime: runtime),
              ],
            ),
            PocketSection(
              title: '你的 Agent',
              children: [
                if (runtime.ready &&
                    runtime.forms.any(
                      (form) => form['ns'] == 'android-auto-review',
                    ))
                  PocketRow(
                    key: const ValueKey('auto-review-settings'),
                    icon: Icons.fact_check_outlined,
                    title: '自动审批',
                    subtitle: '实验性：需要审批的工具调用先由当前模型评审',
                    onTap: () =>
                        open(AutoReviewSettingsPage(runtime: runtime)),
                  ),
                PocketRow(
                  icon: Icons.hub_outlined,
                  title: '模型与连接',
                  subtitle: runtime.model,
                  onTap: () => open(ModelSettings(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.account_circle_outlined,
                  title: 'DeepSeek 账号',
                  subtitle: '登录、授权状态与退出',
                  onTap: () => open(AccountPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.key_outlined,
                  title: '凭据引用',
                  subtitle: '管理模型与工具共用的密钥',
                  onTap: () =>
                      open(CredentialsPage(controller: runtime.credentials)),
                ),
                PocketRow(
                  icon: Icons.tune_rounded,
                  title: 'Agent 与工具',
                  subtitle: '预设、Shell、联网搜索与插件',
                  onTap: () => open(ConfigurationListPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.verified_user_outlined,
                  title: '沙箱与执行权限',
                  subtitle: '脚本可写范围、联网与现有工具权限',
                  onTap: () => open(ExecutionPermissionsPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.code_rounded,
                  title: '手动隔离脚本',
                  subtitle: '选择一次运行的文件与联网范围',
                  onTap: () => open(ManualIsolatedScriptPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.extension_outlined,
                  title: '插件管理',
                  subtitle: '目录、启用、安装与移除',
                  onTap: () => open(PluginsPage(runtime: runtime)),
                ),
                PocketRow(
                  key: const ValueKey('mcp-servers-settings'),
                  icon: Icons.dns_outlined,
                  title: 'MCP 服务器',
                  subtitle: '连接状态、重启与探测',
                  onTap: () => open(McpServersPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.import_export_rounded,
                  title: '导入与导出',
                  subtitle: '预览和迁移运行设置',
                  onTap: () =>
                      open(ConfigurationTransferPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.verified_user_outlined,
                  title: '授权与提问',
                  subtitle: runtime.interactions.isEmpty
                      ? '查看 DSH 等待你处理的请求'
                      : '${runtime.interactions.length} 项等待处理',
                  onTap: () => open(ApprovalsPage(runtime: runtime)),
                ),
              ],
            ),
            PocketSection(
              title: '这台设备',
              children: [
                PocketRow(
                  icon: Icons.palette_outlined,
                  title: '外观与主题',
                  subtitle: '配色、液态玻璃与动效',
                  onTap: () => open(const AppearancePage()),
                ),
                PocketRow(
                  icon: Icons.folder_open_rounded,
                  title: '授权文件',
                  subtitle: '管理 Agent 可以读取的目录',
                  onTap: () => open(FilesPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.language_rounded,
                  title: 'Web 访问',
                  subtitle: runtime.web['phase'] == 'listening'
                      ? '已开启 · 与 App 共享运行时'
                      : '使用原版 Web 界面',
                  onTap: () => open(WebSettingsPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.vpn_key_outlined,
                  title: '网络代理',
                  subtitle: '手机 VPN、本机代理与连接测试',
                  onTap: () => open(NetworkProxyPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.notifications_outlined,
                  title: '授权通知',
                  subtitle: '系统通知、快捷授权与填写',
                  onTap: () => open(const NotificationSettingsPage()),
                ),
                PocketRow(
                  icon: Icons.battery_charging_full_rounded,
                  title: '后台执行',
                  subtitle: '后台任务与系统电池限制',
                  onTap: () => open(BackgroundSettingsPage(runtime: runtime)),
                ),
                PocketRow(
                  key: const ValueKey('remote-background-sync-settings'),
                  icon: Icons.sync_rounded,
                  title: '后台保活',
                  subtitle: '远程连接在后台继续接收任务与审批通知',
                  onTap: () => open(RemoteBackgroundSyncPage(runtime: runtime)),
                ),
              ],
            ),
            PocketSection(
              title: '帮助与诊断',
              divided: true,
              children: [
                PocketRow(
                  icon: Icons.monitor_heart_outlined,
                  title: '运行状态',
                  subtitle: runtime.ready ? '本地服务已就绪' : '查看启动状态与错误',
                  onTap: () => open(DiagnosticsPage(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.build_outlined,
                  title: '启动配置与恢复',
                  subtitle: '原始配置、备份与启动故障处理',
                  onTap: () => open(RecoveryPage(controller: runtime.recovery)),
                ),
                const _InstalledVersionRow(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InstalledVersionRow extends StatefulWidget {
  const _InstalledVersionRow();

  @override
  State<_InstalledVersionRow> createState() => _InstalledVersionRowState();
}

class _InstalledVersionRowState extends State<_InstalledVersionRow> {
  late Future<String> version = readVersion();

  Future<String> readVersion() async {
    final raw = await RuntimeController.channel
        .invokeMethod<String>('app.metadata')
        .timeout(const Duration(seconds: 10));
    final metadata = raw == null ? null : jsonDecode(raw);
    if (metadata is! Map<String, dynamic> ||
        metadata['version'] is! String ||
        (metadata['version'] as String).trim().isEmpty ||
        metadata['build'] is! int ||
        (metadata['build'] as int) < 0) {
      throw const FormatException('Invalid installed application metadata');
    }
    return '${metadata['version']} · 构建 ${metadata['build']} · 开发预览';
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: version,
    builder: (context, snapshot) => PocketRow(
      key: const ValueKey('installed-app-version'),
      icon: Icons.info_outline_rounded,
      title: 'Pocket Harness',
      subtitle: snapshot.connectionState != ConnectionState.done
          ? '正在读取版本信息…'
          : snapshot.hasError
          ? '版本信息暂不可用 · 点按重试'
          : snapshot.data,
      onTap: snapshot.hasError
          ? () => setState(() {
              version = readVersion();
            })
          : null,
    ),
  );
}

class ConfigurationListPage extends StatelessWidget {
  const ConfigurationListPage({required this.runtime, super.key});
  final RuntimeController runtime;
  static bool _sharedSearch(String namespace) => const {
    'web',
    'web-search-deepseek',
    'web-deepseek-api',
  }.contains(namespace);
  // Entry ids with a dedicated native page; the generic form list omits them.
  static bool _dedicatedPage(String namespace) =>
      namespace == 'android-auto-review';
  // Exact bundled entry IDs keep original Web-only preferences separate from
  // native App behavior. Unknown plugin forms stay reachable in their own group.
  static String _group(String ns) => switch (ns) {
    'agent-default-model' ||
    'llm-deepseek' ||
    'llm-deepseek-account' ||
    'llm-pi-ai' => '模型与连接',
    'agent-loop' ||
    'subagent' ||
    'subagent-model-selection-settings' ||
    'tool-ask-user' => 'Agent',
    'web' ||
    'web-search-deepseek' ||
    'web-deepseek-api' ||
    'web-search-exa' ||
    'web-fetch-http' => '联网工具',
    'tool-web' => '联网工具',
    'session-log-deepseek' => '会话与隐私',
    'android-runtime' || 'tool-fs' || 'tool-fs-search' => '设备工具',
    'ui-settings-account' => '高级维护',
    'ui-theme' ||
    'ui-settings' ||
    'ui-conversation' ||
    'ui-chat' => '原版 Web 界面',
    _ => '扩展设置',
  };

  Widget _entry(BuildContext context, Json form) {
    final namespace = '${form['ns']}';
    return PocketRow(
      key: ValueKey('settings-entry:$namespace'),
      icon: configurationIcon(namespace),
      leading: configurationArtwork(form),
      title: configurationNamespaceTitle(namespace),
      onTap: () => Navigator.push(
        context,
        PocketRoute<void>(
          builder: (_) => isModelConfigurationNamespace(namespace)
              ? ConfigurationModelDestination(
                  runtime: runtime,
                  namespace: namespace,
                )
              : namespace == 'subagent-model-selection-settings'
              ? SubagentModelSettingsPage(runtime: runtime)
              : ConfigPage(runtime: runtime, descriptor: form),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('Agent 与工具'),
    body: RuntimeSelectionBuilder(
      runtime: runtime,
      select: () =>
          (runtime.connectionGeneration, runtime.phase, runtime.forms),
      builder: (context, _) => PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          if (!runtime.ready) const Text('本地服务就绪后可读取配置。'),
          PocketSection(
            title: 'Agent',
            divided: true,
            children: [
              PocketRow(
                key: const ValueKey('agent-preset-settings'),
                icon: Icons.tune_rounded,
                title: 'Agent 预设',
                subtitle: '查看能力组合与默认预设',
                onTap: () => Navigator.push(
                  context,
                  PocketRoute<void>(
                    builder: (_) => AgentPresetsPage(runtime: runtime),
                  ),
                ),
              ),
              for (final form in runtime.forms.where(
                (form) =>
                    !_dedicatedPage('${form['ns']}') &&
                    _group('${form['ns']}') == 'Agent',
              ))
                _entry(context, form),
            ],
          ),
          for (final group in [
            '模型与连接',
            '联网工具',
            '会话与隐私',
            '设备工具',
            '原版 Web 界面',
            '高级维护',
            '扩展设置',
          ])
            if (runtime.forms.any(
              (form) =>
                  form['ns'] != 'agent-preset-registry' &&
                  !_dedicatedPage('${form['ns']}') &&
                  _group('${form['ns']}') == group,
            ))
              PocketSection(
                title: group,
                divided: true,
                children: [
                  if (group == '联网工具' &&
                      runtime.forms.any(
                        (form) => _sharedSearch('${form['ns']}'),
                      ))
                    PocketRow(
                      key: const ValueKey('web-search-settings'),
                      icon: Icons.travel_explore_rounded,
                      title: '网页搜索',
                      subtitle: '搜索方式、服务参数与凭据',
                      onTap: () => Navigator.push(
                        context,
                        PocketRoute<void>(
                          builder: (_) =>
                              WebSearchSettingsPage(runtime: runtime),
                        ),
                      ),
                    ),
                  for (final form in runtime.forms.where(
                    (form) =>
                        form['ns'] != 'agent-preset-registry' &&
                        !_sharedSearch('${form['ns']}') &&
                        !_dedicatedPage('${form['ns']}') &&
                        _group('${form['ns']}') == group,
                  ))
                    _entry(context, form),
                ],
              ),
        ],
      ),
    ),
  );
}

class ModelSettings extends StatelessWidget {
  const ModelSettings({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  Widget build(BuildContext context) => ModelsPage(runtime: runtime);
}

class WebSettingsPage extends StatefulWidget {
  const WebSettingsPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<WebSettingsPage> createState() => _WebSettingsPageState();
}

class _WebSettingsPageState extends State<WebSettingsPage> {
  Json? state;
  Json? observedWeb;
  String? error;
  final port = TextEditingController(text: '3080');
  bool busy = false;
  int operation = 0;
  late int observedGeneration = widget.runtime.connectionGeneration;
  late bool wasReady = widget.runtime.ready;
  bool get canWrite =>
      widget.runtime.ready &&
      !busy &&
      state != null &&
      state!['phase'] != 'unknown';
  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(changed);
    changed();
    load();
  }

  void changed() {
    if (!mounted) return;
    final runtime = widget.runtime;
    final restored = !wasReady && runtime.ready;
    final generationChanged =
        observedGeneration != runtime.connectionGeneration;
    final webChanged =
        runtime.web.isNotEmpty && !identical(observedWeb, runtime.web);
    if (wasReady == runtime.ready && !generationChanged && !webChanged) return;
    wasReady = runtime.ready;
    setState(() {
      if (!runtime.ready || generationChanged) {
        observedGeneration = runtime.connectionGeneration;
        operation++;
        busy = false;
        error = null;
      }
      if (webChanged) {
        final cleanPort = state == null || port.text == '${state!['port']}';
        observedWeb = runtime.web;
        state = runtime.web;
        if (cleanPort) port.text = '${state!['port']}';
        if (state!['phase'] != 'unknown') error = null;
      }
    });
    if (restored) unawaited(load());
  }

  @override
  void dispose() {
    widget.runtime.removeListener(changed);
    port.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final generation = widget.runtime.connectionGeneration;
    try {
      await widget.runtime.refreshWeb();
    } catch (exception) {
      if (mounted && generation == widget.runtime.connectionGeneration) {
        setState(() {
          error = 'Web 状态未确认，请刷新重试：$exception';
        });
      }
    }
  }

  Future<void> update({
    bool? enabled,
    String? scope,
    int? portNumber,
    bool rotate = false,
  }) async {
    if (!canWrite) return;
    final owner = ++operation;
    final generation = widget.runtime.connectionGeneration;
    bool current() =>
        mounted &&
        owner == operation &&
        generation == widget.runtime.connectionGeneration;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.runtime.configureWeb(
        rotate
            ? {}
            : {
                'enabled': enabled ?? state!['enabled'],
                'scope': scope ?? state!['scope'],
                'port': portNumber ?? state!['port'],
              },
        rotate: rotate,
      );
    } catch (exception) {
      if (current()) setState(() => error = 'Web 修改结果未确认，请刷新核对：$exception');
    } finally {
      if (current()) setState(() => busy = false);
    }
  }

  static String? validatePort(String text) {
    final value = int.tryParse(text);
    return value == null || value < 1024 || value > 65535
        ? '请输入 1024–65535 之间的端口。'
        : null;
  }

  Future<void> editPort() async {
    final next = await Navigator.of(context).push<String>(
      PocketRoute(
        builder: (_) => TextDocumentPage(
          title: '访问端口',
          text: port.text,
          readOnly: false,
          keyboardType: TextInputType.number,
          helperText: '可用范围 1024–65535，默认 3080。完成编辑后返回保存。',
          validate: validatePort,
        ),
      ),
    );
    if (mounted && next != null) setState(() => port.text = next);
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('Web 访问'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新 Web 状态',
      onPressed: busy ? null : load,
    ),
    body: PocketList(
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            child: SelectableText(error!),
          ),
        if (state == null && error == null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              widget.runtime.ready
                  ? '正在读取 Web 状态…'
                  : '本地服务尚未就绪，连接恢复后会重新确认 Web 状态。',
            ),
          ),
        if (state != null) ...[
          PocketSection(
            children: [
              PocketSwitchRow(
                title: const Text('开启 Web 访问'),
                subtitle: Text(
                  const {
                        'disabled': '已关闭',
                        'starting': '正在启动',
                        'listening': '正在监听',
                        'waiting-network': '等待 Wi-Fi 或以太网的局域网地址',
                        'failed': '启动失败',
                      }[state!['phase']] ??
                      '状态尚未确认',
                ),
                value: state!['enabled'] == true,
                onChanged: canWrite ? (value) => update(enabled: value) : null,
              ),
              if (state!['error'] != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                  child: SelectableText('${state!['error']}'),
                ),
            ],
          ),
          PocketSection(
            title: '允许访问的设备',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: IgnorePointer(
                  ignoring: !canWrite,
                  child: SegmentedControl<String>(
                    segments: const [('local', '仅本机'), ('lan', '局域网')],
                    value: state!['scope'] as String,
                    onChanged: canWrite
                        ? (value) => update(scope: value)
                        : null,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: Text(
                  state!['scope'] == 'lan'
                      ? '允许同一局域网中的设备访问，网络不可用时等待连接。'
                      : '只有这台手机上的浏览器能够访问。',
                ),
              ),
            ],
          ),
          if (widget.runtime.ready && state!['phase'] == 'listening')
            PocketSection(
              title: '访问原版 Web',
              divided: true,
              children: [
                PocketRow(
                  icon: Icons.open_in_browser_rounded,
                  title: '打开浏览器',
                  subtitle: '${state!['host']}:${state!['port']}',
                  onTap: () => RuntimeController.channel.invokeMethod<void>(
                    'openUrl',
                    state!['url'],
                  ),
                ),
                PocketRow(
                  icon: Icons.link_rounded,
                  title: '复制访问链接',
                  onTap: () => Clipboard.setData(
                    ClipboardData(text: '${state!['url']}'),
                  ),
                ),
                PocketDisclosure(
                  title: '二维码与完整链接',
                  child: Column(
                    children: [
                      ColoredBox(
                        color: Colors.white,
                        child: QrImageView(data: '${state!['url']}', size: 220),
                      ),
                      const SizedBox(height: 16),
                      SelectableText('${state!['url']}'),
                    ],
                  ),
                ),
                PocketRow(
                  icon: Icons.refresh_rounded,
                  title: '重置访问凭证',
                  subtitle: '旧链接和浏览器连接会失效',
                  onTap: canWrite ? () => update(rotate: true) : null,
                ),
              ],
            ),
          PocketSection(
            title: '高级设置',
            divided: true,
            children: [
              ConfigurationValueRow(
                title: '访问端口',
                summary: port.text == '${state!['port']}'
                    ? port.text
                    : '${port.text} · 未保存',
                onTap: busy ? null : editPort,
              ),
              if (port.text != '${state!['port']}')
                PocketRow(
                  icon: Icons.check_rounded,
                  title: state!['enabled'] == true ? '保存端口并重启 Web' : '保存端口',
                  onTap: canWrite
                      ? () => update(portNumber: int.parse(port.text))
                      : null,
                ),
              const TextDocumentRow(
                title: '关于 Web 访问',
                text: '浏览器与 App 共用 Agent、会话和配置。开关和访问范围会保留，每次开启生成新链接。关闭 Web 会断开浏览器，手机中的任务继续执行。',
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

/// 远程连接阶段的中文标签（后台保活页与诊断共用）。
String remoteSyncPhaseLabel(RemoteConnectionPhase? phase) => switch (phase) {
  null => '尚未建立远程连接',
  RemoteConnectionPhase.idle => '未连接（空闲）',
  RemoteConnectionPhase.connecting => '正在连接电脑',
  RemoteConnectionPhase.handshaking => '正在握手',
  RemoteConnectionPhase.ready => '连接就绪',
  RemoteConnectionPhase.reconnecting => '连接断开，正在重连',
  RemoteConnectionPhase.lost => '连接已丢失',
  RemoteConnectionPhase.failed => '连接失败',
};

/// 前台同步服务状态的中文标签；只描述原生与 Dart 侧都确认过的事实。
String remoteSyncServiceLabel(RemoteSyncDiagnostics diagnostics) {
  final service = diagnostics.service;
  if (service == null) {
    return diagnostics.serviceRequested
        ? '后台同步服务状态未确认（系统通道不可用）'
        : '后台同步服务未运行';
  }
  if (service.running) return '后台同步运行中';
  if (service.degraded || service.recoveryPending) {
    return '后台同步已中断 · 可在通知栏点按恢复';
  }
  if (service.uiAlive) return '后台同步等待连接';
  return '后台同步未运行';
}

String _remoteSyncAge(DateTime? time) {
  if (time == null) return '—';
  final delta = DateTime.now().difference(time);
  if (delta.isNegative || delta.inSeconds < 5) return '刚刚';
  if (delta.inMinutes < 1) return '${delta.inSeconds} 秒前';
  if (delta.inHours < 1) return '${delta.inMinutes} 分钟前';
  if (delta.inDays < 1) return '${delta.inHours} 小时前';
  return '${delta.inDays} 天前';
}

/// 远程后台保活设置与诊断页。
///
/// 只展示与操作手机侧策略：连接由应用级 [RemoteBackgroundSync] 持有，唤醒锁、心跳与
/// 电池优化状态来自 Kotlin 服务（`remote.sync.status`）。页面不会声称能绕过主线程
/// 无响应（ANR）或厂商（ColorOS 等）的后台清理：这些限制只能由用户手动选择放宽。
class RemoteBackgroundSyncPage extends StatefulWidget {
  const RemoteBackgroundSyncPage({required this.runtime, super.key});

  /// 本机运行时；本页不依赖它发起连接，仅用于页面上下文与既有导航约定。
  final RuntimeController runtime;

  /// 页面作为全屏目的地的稳定标识（与设置入口共用）。
  static const routeDestination = 'remote-background-sync';

  @override
  State<RemoteBackgroundSyncPage> createState() =>
      _RemoteBackgroundSyncPageState();
}

class _RemoteBackgroundSyncPageState extends State<RemoteBackgroundSyncPage>
    with WidgetsBindingObserver {
  static const _adbCommands = '''
# 进程与前台服务
adb shell pidof com.minnnng.dsh_android
adb shell dumpsys activity services com.minnnng.dsh_android | findstr RemoteSync
# 唤醒锁（PAW 为 PARTIAL_WAKE_LOCK）
adb shell dumpsys power | findstr RemoteSync
# 电池优化白名单
adb shell dumpsys deviceidle whitelist | findstr com.minnnng.dsh_android
# 服务日志（ANR 重启、降级原因）
adb logcat -s PocketRemoteSync PocketRemoteNotice flutter''';

  RemoteBackgroundSync get _sync => RemoteBackgroundSync.instance;
  RemoteSyncDiagnostics? diagnostics;
  String? error;
  String? actionMessage;
  bool loading = false;
  bool saving = false;
  bool active = true;
  int readAttempt = 0;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync.addListener(changed);
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (active) unawaited(refresh());
    });
  }

  void changed() {
    if (mounted) unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (loading || saving) return;
    final attempt = ++readAttempt;
    setState(() => loading = true);
    try {
      final next = await _sync.diagnostics();
      if (!mounted || attempt != readAttempt) return;
      setState(() {
        diagnostics = next;
        error = null;
        loading = false;
      });
    } catch (failure) {
      if (!mounted || attempt != readAttempt) return;
      setState(() {
        error = '后台同步状态未确认：$failure';
        loading = false;
      });
    }
  }

  Future<void> configure(bool enabled) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await _sync.setBackgroundSyncEnabled(enabled);
      if (!mounted) return;
      setState(() => actionMessage = enabled ? '已开启后台保持连接' : '已关闭后台保持连接');
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = '后台保活设置未保存：$failure');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> requestBatteryOptimization() async {
    try {
      final message = await _sync.requestBatteryOptimization();
      if (mounted) setState(() => actionMessage = message);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = '无法打开电池优化设置：$failure');
    }
  }

  Future<void> openOemSettings() async {
    try {
      final message = await _sync.openOemBackgroundSettings();
      if (mounted) setState(() => actionMessage = message);
    } catch (failure) {
      if (mounted) setState(() => error = '无法打开厂商后台设置：$failure');
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    _sync.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = diagnostics;
    final service = data?.service;
    final batteryIgnored = service?.batteryOptimizationsIgnored;
    return PocketScaffold(
      title: const Text('后台保活'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新状态',
        onPressed: loading || saving ? null : refresh,
      ),
      body: PocketList(
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          PocketSection(
            title: '与电脑保持同步',
            children: [
              PocketSwitchRow(
                key: const ValueKey('remote-background-sync-switch'),
                title: const Text('后台保持与电脑的连接'),
                subtitle: const Text(
                  '开启后 App 启动即连接上次的电脑，退到桌面/后台继续接收任务完成与审批通知；'
                  '关闭后只在打开远程页面时连接。',
                ),
                value: data?.backgroundSyncEnabled ?? true,
                onChanged: data == null || saving ? null : configure,
              ),
              PocketRow(
                icon: Icons.sync_rounded,
                title: remoteSyncServiceLabel(
                  data ?? RemoteSyncDiagnostics.empty,
                ),
                subtitle: service == null
                    ? '尚未读取到原生服务状态'
                    : '启动于 ${_remoteSyncAge(service.startedAt)} · '
                          '最近心跳 ${_remoteSyncAge(service.lastHeartbeatAt)} · '
                          '停止原因 ${service.lastStopReason ?? '无'}',
              ),
              if (service != null)
                PocketRow(
                  icon: Icons.battery_saver_rounded,
                  title: service.wakeLockHeld ? '正在持有 CPU 唤醒锁' : '当前未持有 CPU 唤醒锁',
                  subtitle:
                      '唤醒锁只避免 CPU 休眠后停止收帧，不能防止主线程无响应（ANR）被系统杀死；'
                      '超时后重新获取 ${service.wakeLockExpiries} 次。',
                ),
            ],
          ),
          PocketSection(
            title: '连接与诊断',
            children: [
              PocketRow(
                icon: Icons.link_rounded,
                title: remoteSyncPhaseLabel(data?.phase),
                subtitle: data?.deviceLabel == null
                    ? '已配对电脑 ${data?.pairedDeviceCount ?? 0} 台'
                    : '当前电脑「${data!.deviceLabel}」· 已配对 ${data.pairedDeviceCount} 台',
              ),
              if (data?.lastDisconnectReason != null)
                PocketRow(
                  icon: Icons.link_off_rounded,
                  title: '最后断开原因',
                  subtitle: data!.lastDisconnectReason,
                ),
              if (data?.lastError != null)
                PocketRow(
                  icon: Icons.error_outline_rounded,
                  title: '最近连接失败',
                  subtitle: [data!.lastError, data.lastErrorCode]
                      .whereType<String>()
                      .join(' · '),
                ),
              if (data?.lastServiceError != null)
                PocketRow(
                  icon: Icons.warning_amber_rounded,
                  title: '服务操作提示',
                  subtitle: data!.lastServiceError,
                ),
              if (data?.lastRestoreError != null)
                PocketRow(
                  icon: Icons.warning_amber_rounded,
                  title: '自动恢复提示',
                  subtitle: data!.lastRestoreError,
                ),
              if (service?.previousRunAbnormal == true)
                PocketRow(
                  key: const ValueKey('remote-background-previous-abnormal'),
                  icon: Icons.restart_alt_rounded,
                  title: '上次运行曾被系统中断',
                  subtitle:
                      '进程在同步期间被系统杀死（常见原因：主线程无响应 ANR、低内存或厂商后台清理）。'
                      '本轮已自动恢复连接；ANR 需要修复卡顿本身，唤醒锁与电池豁免无法避免。'
                      '上次开始于 ${_remoteSyncAge(service!.previousRunStartedAt)}。',
                ),
              if (data != null)
                PocketRow(
                  icon: Icons.monitor_heart_outlined,
                  title: 'Dart 侧服务控制',
                  subtitle:
                      '请求启动 ${data.serviceRequested ? '是' : '否'} · '
                      '心跳 ${data.heartbeatActive ? '运行中' : '未运行'} · '
                      '启动 ${data.serviceStarts} 次 / 停止 ${data.serviceStops} 次 · '
                      '页面${data.pageOpen ? '打开中' : '未打开'}',
                ),
            ],
          ),
          PocketSection(
            title: '电池与厂商设置',
            children: [
              PocketRow(
                icon: Icons.battery_charging_full_rounded,
                title: switch (batteryIgnored) {
                  true => '已获得 Android 标准电池优化豁免',
                  false => '仍受 Android 标准电池优化管理',
                  _ => '电池优化状态尚未确认',
                },
                subtitle: service == null
                    ? '刷新后读取'
                    : '后台限制${service.backgroundRestricted ? '已报告' : '未报告'} · '
                          '省电模式${service.powerSaveMode ? '开启' : '未开启'}',
              ),
              if (batteryIgnored != true)
                PocketRow(
                  key: const ValueKey('remote-background-request-battery'),
                  icon: Icons.battery_saver_rounded,
                  title: '允许电池优化豁免',
                  subtitle: '打开系统电池优化请求页，由你决定是否允许；App 不修改任何策略。',
                  onTap: requestBatteryOptimization,
                ),
              PocketRow(
                key: const ValueKey('remote-background-oem-settings'),
                icon: Icons.open_in_new_rounded,
                title: '打开厂商后台设置',
                subtitle:
                    'ColorOS/EMUI/MIUI 等系统的自启动与耗电管理入口；名称与路径随手机和系统版本变化，找不到时退回应用详情页。',
                onTap: openOemSettings,
              ),
              const PocketRow(
                icon: Icons.info_outline_rounded,
                title: '保活边界',
                subtitle:
                    '唤醒锁、电池豁免与前台服务只减少被系统回收的机会，不能绕过主线程无响应（ANR）或厂商后台清理；'
                    'ColorOS 上请同时在「耗电管理」里允许后台活动，并按需锁定最近任务。',
              ),
              if (actionMessage != null)
                PocketRow(
                  key: const ValueKey('remote-background-action-message'),
                  icon: Icons.check_circle_outline_rounded,
                  title: actionMessage!,
                ),
            ],
          ),
          PocketSection(
            title: '排查命令',
            divided: true,
            children: [
              PocketDisclosure(
                title: 'adb 检查进程 / 服务 / 唤醒锁 / 通知',
                child: SelectableText(
                  _adbCommands,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
