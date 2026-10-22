import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';
import 'text_document_page.dart';
import 'recovery.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  bool confirming = false, dispatching = false, awaitingReady = false;
  String? lastFailure, actionError, notice;
  bool checkingIsolation = false;
  String? isolationNotice;
  Json? isolationEvidence;
  int isolationAttempt = 0;
  late int observedConnection;
  RuntimeController get runtime => widget.runtime;

  @override
  void initState() {
    super.initState();
    lastFailure = runtime.error;
    observedConnection = runtime.connectionGeneration;
    runtime.addListener(changed);
  }

  void changed() {
    if (!mounted) return;
    setState(() {
      if (observedConnection != runtime.connectionGeneration) {
        observedConnection = runtime.connectionGeneration;
        isolationAttempt++;
        checkingIsolation = false;
        isolationEvidence = null;
        isolationNotice = '连接已变化，请重新验证隔离进程。';
      }
      if (runtime.error != null) lastFailure = runtime.error;
      if (awaitingReady && runtime.ready) {
        awaitingReady = false;
        notice = '本地服务已重新就绪。';
      } else if (awaitingReady && runtime.phase == 'failed') {
        awaitingReady = false;
        actionError = runtime.error ?? '服务恢复失败，请查看诊断详情后重试。';
      }
    });
  }

  Future<void> restart() async {
    if (dispatching || awaitingReady) return;
    setState(() {
      dispatching = true;
      awaitingReady = true;
      confirming = false;
      notice = null;
      actionError = null;
    });
    try {
      await runtime.restart();
    } catch (failure) {
      if (mounted) {
        setState(() {
          awaitingReady = false;
          actionError = '未能恢复本地服务：$failure';
        });
      }
    } finally {
      if (mounted) setState(() => dispatching = false);
    }
  }

  Future<void> copy() async {
    try {
      await Clipboard.setData(
        ClipboardData(
          text: const JsonEncoder.withIndent('  ').convert({
            'phase': runtime.phase,
            'error': runtime.error,
            'lastFailure': lastFailure,
            'environment': runtime.info,
            'observations': runtime.observationDiagnostics,
            'isolation': isolationEvidence,
          }),
        ),
      );
      if (mounted) setState(() => notice = '已复制运行诊断。');
    } catch (failure) {
      if (mounted) setState(() => actionError = '无法复制诊断：$failure');
    }
  }

  Future<void> checkIsolation() async {
    if (!runtime.ready || checkingIsolation) return;
    final attempt = ++isolationAttempt;
    final connection = runtime.connectionGeneration;
    bool current() =>
        mounted &&
        attempt == isolationAttempt &&
        connection == runtime.connectionGeneration;
    setState(() {
      checkingIsolation = true;
      isolationEvidence = null;
      isolationNotice = null;
    });
    try {
      final raw = await runtime
          .call('runtime.isolation.probe')
          .timeout(const Duration(seconds: 10));
      if (raw is! Json ||
          raw['workerUid'] is! int ||
          raw['hostUid'] is! int ||
          raw['workerUid'] == raw['hostUid'] ||
          raw['privateReadDenied'] != true ||
          raw['grantReadVerified'] != true ||
          raw['bytes'] is! int ||
          raw['bytes'] <= 0 ||
          raw['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['sha256'] as String)) {
        throw const FormatException('隔离验证回执不完整');
      }
      if (current()) {
        setState(() {
          isolationEvidence = raw;
          isolationNotice = '独立进程、私有文件拒绝与授权文本读取已通过本次检查。';
        });
      }
    } catch (_) {
      if (current()) {
        setState(() => isolationNotice = '隔离验证未通过或结果未确认。程序化工具仍不可用，请稍后重试。');
      }
    } finally {
      if (current()) setState(() => checkingIsolation = false);
    }
  }

  @override
  void dispose() {
    runtime.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final observations = runtime.observationDiagnostics;
    final busy = dispatching || awaitingReady || runtime.phase == 'restarting';
    final phase = switch (runtime.phase) {
      'ready' => '运行中',
      'starting' => '正在启动',
      'restarting' => '正在重启',
      'failed' => '服务异常',
      'maintenance' => '维护模式',
      'maintenance-checking' => '正在检查维护条件',
      'maintenance-blocked' => '维护条件未确认',
      _ => runtime.phase,
    };
    return PocketScaffold(
      title: const Text('运行状态'),
      trailing: GlassButton(
        icon: Icons.copy_rounded,
        label: '复制运行诊断',
        onPressed: copy,
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          PocketSection(
            title: 'Pocket Harness',
            children: [
              PocketRow(
                icon: Icons.memory_rounded,
                title: '内嵌运行时',
                subtitle: runtime.info['node'] as String? ?? '尚未就绪',
                trailing: Text(phase),
              ),
              PocketRow(
                icon: Icons.smartphone_rounded,
                title: '应用权限',
                subtitle: '普通应用 UID：${runtime.info['uid'] ?? '尚未就绪'}',
              ),
            ],
          ),
          PocketSection(
            title: '恢复服务',
            children: [
              PocketRow(
                icon: Icons.build_outlined,
                title: '启动配置与恢复',
                subtitle: '即使 Agent 未就绪，也可进入维护模式修正配置',
                onTap: () => Navigator.push<void>(
                  context,
                  PocketRoute<void>(
                    builder: (_) => RecoveryPage(controller: runtime.recovery),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 18, 22, 8),
                child: Text('重启会中断当前任务。已保存的会话、配置、凭据与文件授权会保留；Web 按已保存的设置恢复。'),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (runtime.nativeMode == 'maintenance')
                      const Text('当前处于维护模式，请在“启动配置与恢复”中恢复运行。')
                    else if (busy)
                      const Text('正在恢复本地服务，等待内嵌运行时就绪……')
                    else if (confirming) ...[
                      const Text('确定中断当前任务并重启服务？'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        children: [
                          PocketButton.tonal(
                            onPressed: () => setState(() => confirming = false),
                            child: const Text('取消'),
                          ),
                          PocketButton(
                            onPressed: restart,
                            child: const Text('确认重启'),
                          ),
                        ],
                      ),
                    ] else
                      PocketButton.tonal(
                        onPressed: () => setState(() => confirming = true),
                        child: const Text('重启本地服务'),
                      ),
                  ],
                ),
              ),
            ],
          ),
          for (final message in [actionError, notice])
            if (message != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(message),
              ),
          if (lastFailure != null)
            PocketSection(
              title: runtime.error != null ? '错误详情' : '上次错误',
              children: [
                TextDocumentRow(
                  title: '查看错误详情',
                  selectable: true,
                  text: lastFailure!,
                  monospace: true,
                ),
              ],
            ),
          PocketSection(
            title: '观察链',
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 8, 22, 12),
                child: Text('当前 App 的活动订阅。序号属于当前连接，重新连接后从 0 开始；已接收不代表业务操作已完成。'),
              ),
              if (observations.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(22, 0, 22, 12),
                  child: Text('当前没有活动订阅。'),
                ),
              for (final observation in observations)
                PocketRow(
                  icon: Icons.sync_alt_rounded,
                  title: '${observation['namespace']}.${observation['method']}',
                  subtitle:
                      '${observationStage(observation['state'] as String)} · 已接收序号 ${observation['sequence']}',
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 14),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: PocketButton.tonal(
                    onPressed: () => setState(() {}),
                    child: const Text('刷新观察状态'),
                  ),
                ),
              ),
            ],
          ),
          if (runtime.info.isNotEmpty)
            PocketSection(
              title: runtime.ready ? '运行环境' : '上次运行环境',
              children: [
                TextDocumentRow(
                  title: '查看运行环境',
                  selectable: true,
                  text: const JsonEncoder.withIndent('  ')
                      .convert(runtime.info),
                  monospace: true,
                ),
              ],
            ),
          PocketSection(
            title: '隔离运行环境',
            children: [
              PocketRow(
                icon: Icons.security_rounded,
                title: '检查独立进程',
                subtitle: '核对独立 UID、私有文件拒绝与授权文本回传',
                trailing: checkingIsolation
                    ? const Text('检查中…')
                    : const Icon(Icons.chevron_right_rounded),
                onTap: runtime.ready && !checkingIsolation
                    ? checkIsolation
                    : null,
              ),
              if (isolationNotice != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 12),
                  child: Text(isolationNotice!),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 0, 22, 14),
                child: Text('这项检查仅验证隔离基础；程序化工具与工作流尚未启用。'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String observationStage(String state) => switch (state) {
  'waiting-service' => '等待服务就绪',
  'subscribing' => '正在发起订阅',
  'waiting-first-frame' => '等待首帧',
  'received' => '已接收',
  'disconnected' => '已断开，等待重连',
  _ => '未知阶段',
};
