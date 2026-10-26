import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

/// Read-only projection of the App-private capability journal. It cannot
/// dismiss an uncertain write or alter the broker's admission decision.
class CapabilityAuditPage extends StatefulWidget {
  const CapabilityAuditPage({required this.runtime, super.key});

  final RuntimeController runtime;

  @override
  State<CapabilityAuditPage> createState() => _CapabilityAuditPageState();
}

class _CapabilityAuditPageState extends State<CapabilityAuditPage>
    with WidgetsBindingObserver {
  Json? snapshot;
  final runs = <Json>[];
  int? nextOffset;
  String? error;
  bool loading = false;
  int request = 0;
  late int connection;

  @override
  void initState() {
    super.initState();
    connection = widget.runtime.connectionGeneration;
    widget.runtime.addListener(runtimeChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
  }

  void runtimeChanged() {
    final next = widget.runtime.connectionGeneration;
    if (connection == next) return;
    connection = next;
    request++;
    setState(() {
      snapshot = null;
      runs.clear();
      nextOffset = null;
      loading = false;
      error = '服务已更换，正在重读审计记录。';
    });
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh({bool more = false}) async {
    if (loading || (more && nextOffset == null)) return;
    final token = ++request;
    final owner = widget.runtime.connectionGeneration;
    bool current() =>
        mounted &&
        request == token &&
        owner == widget.runtime.connectionGeneration;
    setState(() => loading = true);
    try {
      final params = <String, dynamic>{};
      if (more) {
        params['offset'] = nextOffset;
        params['expectedBytes'] = snapshot?['bytes'];
      }
      final value = await widget.runtime.call(
        'runtime.capabilityAudit',
        params,
      );
      if (value is! Json ||
          value['state'] is! String ||
          value['runs'] is! List ||
          value['runs'].any((item) => item is! Map) ||
          (value['nextOffset'] != null && value['nextOffset'] is! int)) {
        throw const FormatException('审计状态格式无法确认');
      }
      if (!current()) return;
      setState(() {
        snapshot = value;
        if (!more) runs.clear();
        runs.addAll((value['runs'] as List).cast<Json>());
        nextOffset = value['nextOffset'] as int?;
        error = null;
      });
    } catch (_) {
      if (current()) setState(() => error = '审计记录未确认；文件授权仍由原生层阻止，请刷新后核对。');
    } finally {
      if (current()) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    request++;
    widget.runtime.removeListener(runtimeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = snapshot?['state'];
    final title = switch (state) {
      'ready' => '审计正常',
      'review' => '有执行结果需要核对',
      'blocked' => '文件授权已暂停',
      'unavailable' => '审计记录无法读取',
      _ => '审计状态待确认',
    };
    return PocketScaffold(
      title: const Text('隔离执行审计'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新审计',
        onPressed: loading ? null : refresh,
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
            title: '状态',
            children: [
              PocketRow(
                icon: state == 'ready'
                    ? Icons.verified_outlined
                    : Icons.report_problem_outlined,
                title: title,
                subtitle: switch (state) {
                  'ready' => '当前日志完整；没有需要人工核对的文件操作。',
                  'review' => '遗留执行或写入结果尚未确认。原生层不接纳新的文件授权。',
                  'blocked' => '审计容量或持久化结果尚未确认。原生层不接纳新的文件授权。',
                  'unavailable' => '原生日志读取失败；新的文件授权保持关闭。',
                  _ => loading ? '正在读取 App 私有审计日志。' : '刷新以核对实际日志状态。',
                },
              ),
              if (snapshot?['damaged'] == true ||
                  snapshot?['truncated'] == true)
                const PocketRow(
                  icon: Icons.broken_image_outlined,
                  title: '审计记录不完整',
                  subtitle: '保留原始日志，停止重复写入；需要人工检查设备上的文件和日志。',
                ),
              if (snapshot?['capacityReached'] == true)
                const PocketRow(
                  icon: Icons.storage_outlined,
                  title: '审计日志已满',
                  subtitle: '先核对全部执行记录。未确认日志不会自动清空或归档。',
                ),
            ],
          ),
          if (runs.isNotEmpty)
            PocketSection(
              title: '留存的执行记录',
              children: [
                for (final run in runs)
                  PocketRow(
                    icon: Icons.rule_folder_outlined,
                    title: '${run['ownerId'] ?? '未知任务'}',
                    subtitle:
                        '${run['unfinished'] == true ? '执行未结束' : '执行已结束'} · '
                        '${run['callCount'] ?? 0} 项审计调用'
                        '${run['auditUncertain'] == true ? ' · 写入结果待核对' : ''}',
                    onTap: snapshot?['bytes'] is int && run['runId'] is String
                        ? () => Navigator.push(
                            context,
                            PocketRoute<void>(
                              builder: (_) => CapabilityAuditRunPage(
                                runtime: widget.runtime,
                                runId: run['runId'] as String,
                                bytes: snapshot!['bytes'] as int,
                              ),
                            ),
                          )
                        : null,
                  ),
                if (nextOffset != null)
                  PocketRow(
                    icon: Icons.expand_more_rounded,
                    title: loading ? '正在读取更多记录' : '显示更多执行',
                    onTap: loading ? null : () => refresh(more: true),
                  ),
              ],
            ),
          if (state == 'review' || state == 'blocked' || state == 'unavailable')
            const PocketSection(
              title: '核对办法',
              children: [
                PocketRow(
                  icon: Icons.info_outline_rounded,
                  title: '先检查实际文件，再决定下一步',
                  subtitle:
                      '打开相应工作区，对照下方目标路径及版本查看当前内容。写入可能已发生，不能仅凭错误提示重试。'
                      '记录会跨重启保留；此页不会自动重放、清除或标记为已恢复。',
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class CapabilityAuditRunPage extends StatefulWidget {
  const CapabilityAuditRunPage({
    required this.runtime,
    required this.runId,
    required this.bytes,
    super.key,
  });
  final RuntimeController runtime;
  final String runId;
  final int bytes;

  @override
  State<CapabilityAuditRunPage> createState() => _CapabilityAuditRunPageState();
}

class _CapabilityAuditRunPageState extends State<CapabilityAuditRunPage> {
  final calls = <Json>[];
  int? nextOffset;
  String? error;
  bool loading = false;
  int request = 0;
  late int connection;

  @override
  void initState() {
    super.initState();
    connection = widget.runtime.connectionGeneration;
    widget.runtime.addListener(runtimeChanged);
    unawaited(load());
  }

  void runtimeChanged() {
    final next = widget.runtime.connectionGeneration;
    if (connection == next) return;
    connection = next;
    request++;
    setState(() {
      calls.clear();
      nextOffset = null;
      loading = false;
      error = '服务已更换，返回上页重读审计记录。';
    });
  }

  Future<void> load({bool more = false}) async {
    if (loading || (more && nextOffset == null)) return;
    final token = ++request;
    final connection = widget.runtime.connectionGeneration;
    bool current() =>
        mounted &&
        request == token &&
        connection == widget.runtime.connectionGeneration;
    setState(() => loading = true);
    try {
      final value = await widget.runtime.call('runtime.capabilityAudit', {
        'runId': widget.runId,
        'expectedBytes': widget.bytes,
        if (more) 'offset': nextOffset,
      });
      if (value is! Json ||
          value['calls'] is! List ||
          value['calls'].any((item) => item is! Map) ||
          (value['nextOffset'] != null && value['nextOffset'] is! int)) {
        throw const FormatException('调用记录格式无法确认');
      }
      if (!current()) return;
      setState(() {
        if (!more) calls.clear();
        calls.addAll((value['calls'] as List).cast<Json>());
        nextOffset = value['nextOffset'] as int?;
        error = null;
      });
    } catch (_) {
      if (current()) setState(() => error = '审计日志已变化或无法读取；返回上页刷新，不要重复执行写入。');
    } finally {
      if (current()) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    request++;
    widget.runtime.removeListener(runtimeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('执行核对'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '重读记录',
      onPressed: loading ? null : load,
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
          title: '审计身份',
          children: [
            PocketRow(
              icon: Icons.fingerprint_rounded,
              title: widget.runId,
              subtitle: '原生执行标识。此页面只显示持久化事实，不提供确认完成或清除操作。',
            ),
          ],
        ),
        if (calls.isNotEmpty)
          PocketSection(
            title: '文件调用',
            children: [
              for (final call in calls)
                PocketRow(
                  icon: call['action'] == 'EDIT' || call['action'] == 'WRITE'
                      ? Icons.edit_outlined
                      : Icons.description_outlined,
                  title:
                      '${call['action'] ?? '调用'} · ${call['target'] ?? '未知路径'}',
                  subtitle:
                      '${call['reason'] ?? '结果待确认'}'
                      '${call['expectedRevision'] is String ? '\n操作前版本：${call['expectedRevision']}' : ''}'
                      '${call['resultRevision'] is String ? '\n记录的结果版本：${call['resultRevision']}' : ''}',
                ),
              if (nextOffset != null)
                PocketRow(
                  icon: Icons.expand_more_rounded,
                  title: loading ? '正在读取更多调用' : '显示更多调用',
                  onTap: loading ? null : () => load(more: true),
                ),
            ],
          ),
      ],
    ),
  );
}
