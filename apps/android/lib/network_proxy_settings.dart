import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'network_proxy.dart';
import 'network_proxy_tool_icon.dart';
import 'design/popup.dart';
import 'runtime.dart';
import 'ui.dart';

class NetworkProxyPage extends StatefulWidget {
  const NetworkProxyPage({
    super.key,
    required this.runtime,
    this.platform = const NetworkProxyPlatform(),
  });
  final RuntimeController runtime;
  final NetworkProxyPlatform platform;
  @override
  State<NetworkProxyPage> createState() => _NetworkProxyPageState();
}

class _NetworkProxyPageState extends State<NetworkProxyPage>
    with WidgetsBindingObserver {
  final port = TextEditingController(text: '7890');
  NetworkProxyConfiguration? saved;
  NetworkProxyRoute? applied;
  String mode = 'system', tool = '';
  String? error, notice, testResult;
  bool loading = true, saving = false, testing = false, applying = false;
  int generation = 0;
  late (int, String) connection;
  bool get busy => saving || applying;
  bool get pending =>
      saved != null && applied?.identity != saved!.route.identity;
  int get phonePort {
    final value = int.tryParse(port.text.trim());
    return value != null && value >= 1 && value <= 65535
        ? value
        : saved?.port ?? 7890;
  }

  bool get hasDraft =>
      saved == null ||
      mode != saved!.mode ||
      (mode == 'local' ? int.tryParse(port.text.trim()) : phonePort) !=
          saved!.port ||
      tool != saved!.tool;
  Json get draft => {
    'mode': mode,
    'port': mode == 'local' ? checkedProxyPort(port.text) : phonePort,
    'tool': tool,
  };

  @override
  void initState() {
    super.initState();
    connection = (widget.runtime.connectionGeneration, widget.runtime.phase);
    widget.runtime.addListener(runtimeChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  void runtimeChanged() {
    final next = (widget.runtime.connectionGeneration, widget.runtime.phase);
    if (next == connection) return;
    connection = next;
    if (widget.runtime.ready && !busy) {
      unawaited(load());
    } else if (!widget.runtime.ready && mounted) {
      setState(() => applied = null);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) unawaited(load());
  }

  Future<NetworkProxyRoute?> readApplied() async {
    if (!widget.runtime.ready) {
      return null;
    }
    final expected = widget.runtime.connectionGeneration;
    try {
      final value =
          await widget.runtime
                  .call('runtime.proxy.status')
                  .timeout(const Duration(seconds: 5))
              as Json;
      if (!mounted || expected != widget.runtime.connectionGeneration) {
        return null;
      }
      return value['phase'] == 'ready' && value['configuration'] is Json
          ? NetworkProxyConfiguration(value['configuration'] as Json).route
          : null;
    } catch (failure) {
      // A failed observation leaves current-process application unconfirmed.
      return null;
    }
  }

  Future<void> load({bool adoptSaved = false}) async {
    final current = ++generation;
    final before = (mode, port.text, tool);
    final adopt = adoptSaved || saved == null || !hasDraft;
    try {
      final value = await widget.platform.read();
      if (!mounted || current != generation) return;
      saved = value;
      if (adopt && before == (mode, port.text, tool)) {
        mode = value.mode;
        port.text = '${value.port}';
        tool = value.tool;
      }
      final observed = await readApplied();
      if (!mounted || current != generation) return;
      setState(() {
        applied = observed;
        loading = false;
        error = null;
      });
    } catch (failure) {
      if (mounted && current == generation) {
        setState(() {
          loading = false;
          error = '无法读取代理配置：${message(failure)}';
        });
      }
    }
  }

  String message(Object failure) => failure is PlatformException
      ? failure.message ?? '操作未完成，请重试'
      : failure is FormatException
      ? failure.message
      : '$failure';

  void edited(VoidCallback change) => setState(() {
    change();
    notice = null;
    testResult = null;
  });

  Future<void> save() async {
    if (busy || testing) return;
    Json value;
    try {
      value = draft;
    } catch (failure) {
      setState(() => error = message(failure));
      return;
    }
    final current = ++generation;
    setState(() {
      saving = true;
      error = null;
      notice = null;
    });
    try {
      final confirmed = await widget.platform.save(value);
      if (!mounted || current != generation) return;
      if (!mapEquals(confirmed.value, value)) {
        throw StateError('保存结果与选择不一致，请重新读取');
      }
      saved = confirmed;
      port.text = '${confirmed.port}';
      final observed = await readApplied();
      if (!mounted || current != generation) return;
      applied = observed;
      if (mounted) {
        setState(() => notice = pending ? '已保存。任务结束后，点按应用使 Agent 生效。' : '已保存');
      }
    } catch (failure) {
      if (mounted) setState(() => error = '保存未确认，请重新读取后核对：${message(failure)}');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> apply() async {
    if (busy || testing || saved == null || hasDraft) return;
    final current = ++generation;
    setState(() {
      applying = true;
      error = null;
      notice = null;
    });
    try {
      await widget.platform.apply();
      if (!mounted) return;
      final observed = await readApplied();
      if (!mounted || current != generation) return;
      applied = observed;
      if (mounted) {
        setState(() => notice = pending ? '服务正在恢复，生效状态待确认' : 'Agent 已应用代理配置');
      }
    } catch (failure) {
      if (mounted) setState(() => error = '配置已保存，未切换服务：${message(failure)}');
    } finally {
      if (mounted) setState(() => applying = false);
    }
  }

  Future<void> test() async {
    if (busy || testing) return;
    Json value;
    try {
      value = draft;
    } catch (failure) {
      setState(() => error = message(failure));
      return;
    }
    setState(() {
      testing = true;
      testResult = null;
      error = null;
    });
    try {
      final result = await widget.platform.test(value);
      if (mounted) {
        setState(
          () => testResult =
              'HTTPS 测试通过 · ${result['milliseconds']} ms\n${result['host']}',
        );
      }
    } catch (failure) {
      if (mounted) setState(() => testResult = '连接测试失败：${message(failure)}');
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  Future<void> openTool() async {
    try {
      await widget.platform.openTool(tool);
    } catch (failure) {
      if (mounted) setState(() => error = message(failure));
    }
  }

  @override
  void dispose() {
    generation++;
    widget.runtime.removeListener(runtimeChanged);
    WidgetsBinding.instance.removeObserver(this);
    port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tools = saved?.tools ?? const <Json>[];
    final selectedTool = tools
        .where((entry) => entry['id'] == tool)
        .firstOrNull;
    return PocketScaffold(
      title: const Text('网络代理'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '重新读取代理配置',
        onPressed: busy || testing ? null : () => load(adoptSaved: true),
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          if (loading)
            const Padding(padding: EdgeInsets.all(16), child: Text('正在读取配置…')),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (notice != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(notice!)),
          PocketSection(
            title: '连接方式',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: SegmentedControl<String>(
                  segments: const [('system', '手机网络 / VPN'), ('local', '本机代理')],
                  value: mode,
                  onChanged: loading || busy || testing
                      ? null
                      : (value) => edited(() => mode = value),
                ),
              ),
              if (mode == 'local')
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: TextField(
                    key: const ValueKey('proxy-port'),
                    controller: port,
                    enabled: !busy && !testing,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => edited(() {}),
                    decoration: const InputDecoration(
                      labelText: 'HTTP / 混合端口',
                      prefixText: '127.0.0.1 : ',
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Text(
                  mode == 'local'
                      ? '填写手机代理工具中的 HTTP 或混合端口。'
                      : '不指定 HTTP 代理，使用手机网络及已开启的 VPN。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          PocketSection(
            title: '代理工具',
            children: [
              Row(
                children: [
                  Expanded(
                    child: CommonPopupBox(
                      key: const ValueKey('proxy-tool'),
                      placement: PopupPlacement.overAnchorStart,
                      onOpen: () => FocusScope.of(context).unfocus(),
                      popupBuilder: (_) => CommonPopupMenu(
                        maxVisibleItems: 5,
                        items: [
                          CommonPopupMenuItem(
                            label: '系统 VPN 设置',
                            glyph: Icons.vpn_key_outlined,
                            checked: tool.isEmpty,
                            onPressed: () => edited(() => tool = ''),
                          ),
                          for (final entry in tools)
                            CommonPopupMenuItem(
                              label: entry['name'] as String,
                              leading: NetworkProxyToolIcon(
                                base64: entry['icon'] as String?,
                                size: 20,
                              ),
                              checked: entry['id'] == tool,
                              onPressed: () =>
                                  edited(() => tool = entry['id'] as String),
                            ),
                        ],
                      ),
                      targetBuilder: (open) => PocketTile(
                        key: const ValueKey('proxy-tool-select'),
                        title: Text(
                          selectedTool?['name'] as String? ??
                              (tool.isEmpty ? '系统 VPN 设置' : '所选工具已卸载或不可用'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        leading: NetworkProxyToolIcon(
                          base64: selectedTool?['icon'] as String?,
                        ),
                        trailing: const Icon(
                          Icons.unfold_more_rounded,
                          size: 20,
                        ),
                        contentPadding: const EdgeInsets.fromLTRB(
                          20,
                          16,
                          8,
                          16,
                        ),
                        onTap: loading || busy || testing ? null : open,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: GlassButton(
                      key: const ValueKey('proxy-tool-open'),
                      icon: Icons.open_in_new_rounded,
                      label: '打开代理工具',
                      onPressed: loading || busy || testing ? null : openTool,
                    ),
                  ),
                ],
              ),
            ],
          ),
          PocketButton.tonal(
            key: const ValueKey('proxy-test'),
            onPressed: busy || testing ? null : test,
            child: Text(testing ? '正在测试 HTTPS…' : '测试此配置'),
          ),
          if (testResult != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                testResult!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          PocketButton(
            key: const ValueKey('proxy-save'),
            onPressed: loading || busy || testing ? null : save,
            child: Text(saving ? '正在保存…' : '保存配置'),
          ),
          if (saved != null && pending) ...[
            const SizedBox(height: 12),
            PocketButton.tonal(
              key: const ValueKey('proxy-apply'),
              onPressed: busy || testing || hasDraft ? null : apply,
              child: Text(
                applying
                    ? '正在应用…'
                    : hasDraft
                    ? '请先保存配置'
                    : '应用到 Agent',
              ),
            ),
          ],
          if (saved != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Text(
                hasDraft
                    ? '更改尚未保存'
                    : applied == null
                    ? 'Agent 生效状态待确认'
                    : pending
                    ? 'Agent 仍使用上次配置'
                    : 'Agent 已生效',
                key: const ValueKey('proxy-applied-state'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
            child: Text(
              'App 新请求使用已保存配置；Agent 应用时会重启服务，有任务执行时不会中断。外部浏览器跟随手机网络。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
