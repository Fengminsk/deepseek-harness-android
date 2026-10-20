import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';
import 'files.dart';
import 'appearance.dart';
import 'configuration_editor.dart';
import 'configuration_edits.dart';
import 'approvals.dart';
import 'approvals_notifications.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  Widget build(BuildContext context) {
    void open(Widget page) =>
        Navigator.push(context, PocketRoute<void>(builder: (_) => page));
    return PocketScaffold(
      title: const Text('设置'),
      body: ListenableBuilder(
        listenable: runtime,
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
              title: '你的 Agent',
              children: [
                PocketRow(
                  icon: Icons.hub_outlined,
                  title: '模型与连接',
                  subtitle: runtime.model,
                  onTap: () => open(ModelSettings(runtime: runtime)),
                ),
                PocketRow(
                  icon: Icons.tune_rounded,
                  title: 'Agent 与工具',
                  subtitle: '预设、Shell、联网搜索与插件',
                  onTap: () => open(ConfigurationListPage(runtime: runtime)),
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
                  icon: Icons.notifications_outlined,
                  title: '授权通知',
                  subtitle: '系统通知、快捷授权与填写',
                  onTap: () => open(const NotificationSettingsPage()),
                ),
              ],
            ),
            PocketSection(
              title: '帮助与诊断',
              children: [
                PocketRow(
                  icon: Icons.monitor_heart_outlined,
                  title: '运行状态',
                  subtitle: runtime.ready ? '本地服务已就绪' : '查看启动状态与错误',
                  onTap: () => open(DiagnosticsPage(runtime: runtime)),
                ),
                const PocketRow(
                  icon: Icons.info_outline_rounded,
                  title: 'Pocket Harness',
                  subtitle: '0.1.0 · 构建 5 · 开发预览',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ConfigurationListPage extends StatelessWidget {
  const ConfigurationListPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('Agent 与工具'),
    body: ListenableBuilder(
      listenable: runtime,
      builder: (context, _) => PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 24),
            child: Text(
              '按运行时配置提供原生字段表单。复杂结构可在 App 内高级编辑，凭据保持隐藏。',
              style: TextStyle(fontSize: 13),
            ),
          ),
          if (!runtime.ready) const Text('本地服务就绪后可读取配置。'),
          PocketSection(
            children: [
              for (final form in runtime.forms)
                PocketRow(
                  icon: Icons.tune_rounded,
                  title: configurationNamespaceTitle('${form['ns']}'),
                  subtitle: '${form['ns']}',
                  onTap: () => Navigator.push(
                    context,
                    PocketRoute<void>(
                      builder: (_) =>
                          ConfigPage(runtime: runtime, descriptor: form),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('运行状态'),
    body: ListenableBuilder(
      listenable: runtime,
      builder: (context, _) => PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          PocketSection(
            title: 'Pocket Harness',
            children: [
              PocketRow(
                icon: Icons.memory_rounded,
                title: '内嵌运行时',
                subtitle: runtime.info['node'] as String? ?? '尚未就绪',
                trailing: Text(runtime.ready ? '运行中' : runtime.phase),
              ),
              PocketRow(
                icon: Icons.smartphone_rounded,
                title: '应用权限',
                subtitle: '普通应用 UID：${runtime.info['uid'] ?? '尚未就绪'}',
              ),
            ],
          ),
          if (runtime.error != null)
            PocketSection(
              title: '错误详情',
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    runtime.error!,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          if (runtime.info.isNotEmpty)
            PocketSection(
              title: '运行环境',
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(runtime.info),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
        ],
      ),
    ),
  );
}

class ModelSettings extends StatefulWidget {
  const ModelSettings({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<ModelSettings> createState() => _ModelSettingsState();
}

class _ModelSettingsState extends State<ModelSettings> {
  final keyInput = TextEditingController();
  late final model = TextEditingController(text: widget.runtime.model);
  Json? modelDescriptor;
  bool configured = false, busy = false, reveal = false;
  String? message;
  @override
  void initState() {
    super.initState();
    for (final form in widget.runtime.forms) {
      if (form['ns'] == 'agent-default-model') {
        modelDescriptor = cloneConfiguration(form);
        break;
      }
    }
    readStatus();
  }

  Future<void> readStatus() async {
    try {
      final result = await widget.runtime.call('credentials.describe', {
        'ref': 'DEEPSEEK_API_KEY',
      }) as Json;
      if (mounted) setState(() => configured = result['configured'] == true);
    } catch (error) {
      if (mounted) setState(() => message = '$error');
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      message = null;
    });
    var credentialSaved = false;
    try {
      if (model.text.trim().isEmpty) throw const FormatException('请输入模型 ID');
      if (modelDescriptor == null) {
        throw const ConfigurationEditException('尚未读取默认模型配置。请等待本地服务就绪后重新打开此页。');
      }
      final descriptor = modelDescriptor!;
      final value = configurationObject(descriptor['value']);
      final next = cloneConfiguration(value)
        ..['provider'] = widget.runtime.provider
        ..['model'] = model.text.trim();
      final operations = configurationEdits(descriptor, next);
      if (keyInput.text.trim().isNotEmpty) {
        await widget.runtime.call('credentials.set', {
          'ref': 'DEEPSEEK_API_KEY',
          'value': keyInput.text.trim(),
        });
        keyInput.clear();
        configured = true;
        credentialSaved = true;
      }
      if (operations.isNotEmpty) {
        final saved = (await widget.runtime.call('settings.mutate', {
          'ns': descriptor['ns'],
          'revision': descriptor['revision'],
          'ops': operations,
        }) as List).cast<Json>();
        modelDescriptor = cloneConfiguration(
          saved.firstWhere((form) => form['ns'] == descriptor['ns']),
        );
      }
      widget.runtime.model = model.text.trim();
      if (mounted) {
        setState(
          () => message = credentialSaved
              ? 'API Key 与默认模型已保存。'
              : '默认模型已保存；现有 API Key 未改变。',
        );
      }
      try {
        await widget.runtime.refreshForms();
      } catch (error) {
        if (mounted) {
          setState(() => message = '配置已保存，设置列表刷新失败：$error');
        }
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => message =
              '${credentialSaved ? 'API Key 已保存，但默认模型尚未保存。' : '未能保存。'}'
              '\n$error\n模型输入已保留。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    keyInput.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('模型与连接'),
    body: PocketList(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'DeepSeek',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          configured
              ? 'API Key 已配置；留空会保留现有凭据。'
              : '配置 API Key 后，即可在手机上发起 Agent 任务。',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: keyInput,
          enabled: !busy,
          obscureText: !reveal,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'API Key',

            suffixIcon: GlassButton(
              label: reveal ? '隐藏' : '显示',
              onPressed: () => setState(() => reveal = !reveal),
              icon: reveal ? Icons.visibility_off : Icons.visibility,
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: model,
          enabled: !busy,
          decoration: const InputDecoration(labelText: '模型 ID'),
        ),
        const SizedBox(height: 24),
        PocketButton(
          onPressed: busy ? null : save,
          child: Text(busy ? '正在保存' : '保存'),
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SelectableText(message!),
          ),
        for (final form in widget.runtime.forms.where(
          (item) => '${item['ns']}'.startsWith('llm'),
        ))
          PocketTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('服务地址与模型参数'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              PocketRoute<void>(
                builder: (_) =>
                    ConfigPage(runtime: widget.runtime, descriptor: form),
              ),
            ),
          ),
      ],
    ),
  );
}

class WebSettingsPage extends StatefulWidget {
  const WebSettingsPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<WebSettingsPage> createState() => _WebSettingsPageState();
}

class _WebSettingsPageState extends State<WebSettingsPage> {
  Json? state;
  String? error;
  final port = TextEditingController(text: '3080');
  bool busy = false;
  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(changed);
    load();
  }

  void changed() {
    if (mounted && widget.runtime.web.isNotEmpty) {
      setState(() => state = widget.runtime.web);
    }
  }

  @override
  void dispose() {
    widget.runtime.removeListener(changed);
    port.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final value = await widget.runtime.call('web.status') as Json;
      if (mounted) {
        setState(() {
          state = value;
          port.text = '${value['port']}';
        });
      }
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
    }
  }

  Future<void> update({
    bool? enabled,
    String? scope,
    bool rotate = false,
  }) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await widget.runtime.call(
        rotate ? 'web.rotate' : 'web.configure',
        rotate
            ? {}
            : {
                'enabled': enabled ?? state!['enabled'],
                'scope': scope ?? state!['scope'],
                'port': int.parse(port.text),
              },
      ) as Json;
      if (mounted) setState(() => state = value);
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('Web 访问'),
    body: PocketList(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '原版 Web',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const Text('浏览器与 App 使用同一个 Agent、会话和配置。'),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: SelectableText(error!),
          ),
        if (state != null) ...[
          const SizedBox(height: 24),
          PocketSwitchRow(
            contentPadding: EdgeInsets.zero,
            title: const Text('开启 Web 访问'),
            subtitle: const Text('记住开关和访问范围；每次开启生成新的访问链接'),
            value: state!['enabled'] == true,
            onChanged: busy ? null : (value) => update(enabled: value),
          ),
          const SizedBox(height: 16),
          IgnorePointer(
            ignoring: busy,
            child: SegmentedControl<String>(
              segments: const [('local', '仅本机'), ('lan', '局域网')],
              value: state!['scope'] as String,
              onChanged: (value) => update(scope: value),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '端口',
              helperText: '1024–65535，默认 3080',
            ),
          ),
          const SizedBox(height: 16),
          PocketButton.tonal(
            onPressed: busy ? null : update,
            child: const Text('应用端口并重启 Web'),
          ),
          const SizedBox(height: 24),
          Text(
            const {
                  'disabled': '已关闭',
                  'starting': '正在启动',
                  'listening': '正在监听',
                  'waiting-network': '等待 Wi-Fi 或以太网的局域网地址',
                  'failed': '启动失败',
                }[state!['phase']] ??
                '${state!['phase']}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (state!['error'] != null) SelectableText('${state!['error']}'),
          if (state!['phase'] == 'listening') ...[
            const SizedBox(height: 8),
            SelectableText('监听地址：${state!['host']}:${state!['port']}'),
            const SizedBox(height: 16),
            SelectableText('${state!['url']}'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: PocketButton(
                    onPressed: () => RuntimeController.channel
                        .invokeMethod<void>('openUrl', state!['url']),
                    child: const Text('打开浏览器'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PocketButton.tonal(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: '${state!['url']}'),
                    ),
                    child: const Text('复制链接'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: ColoredBox(
                color: Colors.white,
                child: QrImageView(data: '${state!['url']}', size: 230),
              ),
            ),
            PocketButton.tonal(
              onPressed: busy ? null : () => update(rotate: true),
              child: const Text('重置访问凭证'),
            ),
          ],
          const SizedBox(height: 16),
          const Text('关闭会立即断开浏览器连接，手机中的任务继续执行。局域网模式只绑定当前本地网络地址。'),
        ],
      ],
    ),
  );
}
