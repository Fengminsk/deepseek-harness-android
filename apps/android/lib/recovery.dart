import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'recovery_data.dart';
import 'runtime.dart';
import 'ui.dart';

Widget _message(String text) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
  child: Text(text),
);

String _fileName(String id) => switch (id) {
  'profile-patch' => 'Android 配置补丁',
  'home-patch' => '全局配置补丁',
  'profile-manifest' => 'Android 插件清单',
  'runtime-log' => '启动日志',
  _ => id,
};

String _operationState(dynamic state) => switch (state) {
  'saved' => '已保存',
  'quarantined' => '已隔离',
  'pending' => '处理中',
  'unconfirmed' => '结果未确认',
  'unknown' => '结果未确认',
  'failed' => '未完成',
  'rejected' => '已拒绝',
  _ => '结果未确认',
};

class RecoveryPage extends StatefulWidget {
  const RecoveryPage({super.key, required this.controller});
  final RecoveryController controller;
  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  bool confirmMaintenance = false, confirmRepair = false;
  RecoveryController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(controller.load());
  }

  Future<void> open(Widget page) async {
    await Navigator.push<void>(
      context,
      PocketRoute<void>(builder: (_) => page),
    );
    if (mounted) await controller.load();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      // Native transition admission is independent of inspecting damaged files.
      // Only configuration writes require a fresh, writable maintenance snapshot.
      final canAct = !controller.working;
      return PocketScaffold(
        title: const Text('启动配置与恢复'),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '刷新恢复状态',
          onPressed: controller.loading ? null : controller.load,
        ),
        body: PocketList(
          children: [
            PocketSection(
              title: '服务状态',
              children: [
                PocketRow(
                  icon: Icons.build_outlined,
                  title: !controller.current
                      ? '状态尚未确认'
                      : controller.state['mode'] == 'maintenance'
                      ? (controller.maintenance ? '维护模式' : '维护条件尚未确认')
                      : '正常运行模式',
                  subtitle: controller.maintenance
                      ? 'Agent 与 Web 已停止，可以编辑启动配置。'
                      : controller.state['mode'] == 'maintenance'
                      ? '修改已禁用。请查看诊断并重新检查维护条件。'
                      : '维护前会停止 Agent 与 Web，当前任务将被中断。',
                ),
                if (controller.boot['stage'] != null)
                  _message('启动阶段：${controller.boot['stage']}'),
                if (controller.boot['error'] != null)
                  _message('启动错误：${controller.boot['error']}'),
                if (controller.state['preferenceError'] != null)
                  _message('启动偏好读取失败：${controller.state['preferenceError']}'),
                if (controller.state['preferredMode'] != null &&
                    controller.state['preferredMode'] !=
                        controller.state['mode'])
                  _message(
                    '下次服务启动偏好与当前模式不同：'
                    '${controller.state['preferredMode'] == 'maintenance' ? '维护模式' : '正常运行模式'}。'
                    '请重新选择运行模式以确认。',
                  ),
                if (controller.readError != null)
                  _message(controller.readError!),
                if (controller.error != null) _message(controller.error!),
                if (controller.notice != null) _message(controller.notice!),
                if (controller.loading) _message('正在读取原生服务状态…'),
                if (controller.working) _message('正在等待原生操作回执…'),
                if (controller.awaitingReady)
                  _message('等待 DSH 加载配置；进程已启动不代表配置已通过验证。'),
              ],
            ),
            if (controller.pendingAction != null)
              PocketSection(
                title: '待核对的操作',
                children: [
                  _message(
                    '${controller.pendingAction!['method']} · '
                    '${_operationState(controller.pendingAction!['state'])}\n'
                    '请求：${controller.pendingAction!['requestId']}',
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: PocketButton.tonal(
                      onPressed: controller.checkAction,
                      child: const Text('核对原请求回执'),
                    ),
                  ),
                  if (controller.canAcknowledgeAction) ...[
                    _message(
                      '原操作所属进程已退出。确认接受这条未确认记录后，可继续其他操作；原请求不会重发。请先核对实际文件状态。',
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: PocketButton.tonal(
                        onPressed: controller.acknowledgeAction,
                        child: const Text('保留未确认记录，继续手动处理'),
                      ),
                    ),
                  ],
                ],
              ),
            PocketSection(
              title: '运行模式',
              children: [
                if (controller.state['mode'] == 'maintenance')
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: PocketButton(
                      key: const ValueKey('recovery-resume'),
                      onPressed: canAct
                          ? () => controller.changeMode(enter: false)
                          : null,
                      child: const Text('恢复运行并验证配置'),
                    ),
                  ),
                if (!controller.maintenance && confirmMaintenance) ...[
                  _message('确定停止服务并进入维护模式？当前任务会被中断。会话、凭据、文件授权和 Web 偏好会保留。'),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        PocketButton.tonal(
                          onPressed: controller.working
                              ? null
                              : () =>
                                    setState(() => confirmMaintenance = false),
                          child: const Text('取消'),
                        ),
                        PocketButton(
                          key: const ValueKey('recovery-confirm-enter'),
                          onPressed: canAct
                              ? () async {
                                  setState(() => confirmMaintenance = false);
                                  await controller.changeMode(enter: true);
                                }
                              : null,
                          child: const Text('确认停止并维护'),
                        ),
                      ],
                    ),
                  ),
                ] else if (!controller.maintenance)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: PocketButton.tonal(
                      key: const ValueKey('recovery-enter'),
                      onPressed: canAct
                          ? () => setState(() => confirmMaintenance = true)
                          : null,
                      child: const Text('进入维护模式'),
                    ),
                  ),
              ],
            ),
            PocketSection(
              title: '原始启动配置',
              children: [
                _message(
                  '编辑原 DSH 配置文件。保存前自动保留旧版本，配置内容只在本机处理。语法或插件配置错误可能导致启动失败，可在此恢复备份。',
                ),
                for (final file in controller.files)
                  PocketRow(
                    icon: file['id'] == 'runtime-log'
                        ? Icons.article_outlined
                        : Icons.description_outlined,
                    title: '${file['label'] ?? _fileName('${file['id']}')}',
                    subtitle: file['exists'] == true
                        ? '${file['bytes']} 字节'
                        : '尚未创建',
                    onTap: () => open(
                      RecoveryDocumentPage(
                        controller: controller,
                        fileId: file['id'] as String,
                      ),
                    ),
                  ),
                if (!controller.files.any(
                  (file) => file['id'] == 'runtime-log',
                ))
                  PocketRow(
                    icon: Icons.article_outlined,
                    title: '查看启动日志',
                    subtitle: '最近 64 KiB，仅在打开后读取',
                    onTap: () => open(
                      RecoveryDocumentPage(
                        controller: controller,
                        fileId: 'runtime-log',
                      ),
                    ),
                  ),
              ],
            ),
            PocketSection(
              title: '本机备份',
              children: [
                if (controller.backups.isEmpty)
                  _message('尚无配置备份。保存或恢复配置时，会先备份当前版本。'),
                for (final backup in controller.backups.reversed)
                  PocketRow(
                    icon: Icons.history_rounded,
                    title: _fileName('${backup['fileId']}'),
                    subtitle:
                        '${backup['createdAt']}\n'
                        '${backup['exists'] == true ? '${backup['bytes']} 字节' : '原文件不存在'}',
                    onTap: () => open(
                      RecoveryBackupPage(
                        controller: controller,
                        backupId: backup['id'] as String,
                      ),
                    ),
                  ),
              ],
            ),
            PocketSection(
              title: '内嵌运行资源',
              children: [
                _message(
                  '若安装包内的运行资源解包损坏，可隔离当前缓存，再从当前安装包重新解包。不会移除会话、配置、凭据和文件授权。',
                ),
                if (confirmRepair)
                  _message('确认隔离当前运行资源缓存？此操作只在维护模式执行，随后需要恢复运行。'),
                if (controller.hasPendingDocument)
                  _message('先返回编辑文件核对保存回执，再修复运行资源。'),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (confirmRepair)
                        PocketButton.tonal(
                          onPressed: controller.working
                              ? null
                              : () => setState(() => confirmRepair = false),
                          child: const Text('取消'),
                        ),
                      PocketButton.tonal(
                        key: const ValueKey('recovery-repair'),
                        onPressed:
                            !canAct ||
                                !controller.maintenance ||
                                controller.pendingAction != null ||
                                controller.hasPendingDocument ||
                                controller.boot['runtimeSha256'] is! String
                            ? null
                            : () async {
                                if (!confirmRepair) {
                                  setState(() => confirmRepair = true);
                                  return;
                                }
                                setState(() => confirmRepair = false);
                                await controller.trackedMutation(
                                  'runtimeRepair',
                                  {
                                    'expectedRuntimeSha256':
                                        controller.boot['runtimeSha256'],
                                  },
                                );
                              },
                        child: Text(confirmRepair ? '确认隔离资源' : '修复内嵌运行资源'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (controller.operations.isNotEmpty)
              PocketSection(
                title: '操作记录',
                children: [
                  for (final operation in controller.operations.reversed)
                    PocketRow(
                      icon: Icons.receipt_long_outlined,
                      title:
                          '${operation['method']} · '
                          '${_operationState(operation['state'])}',
                      subtitle:
                          '${operation['createdAt']}\n'
                          '${operation['requestId']}',
                    ),
                ],
              ),
          ],
        ),
      );
    },
  );
}

class RecoveryDocumentPage extends StatefulWidget {
  const RecoveryDocumentPage({
    super.key,
    required this.controller,
    required this.fileId,
  });
  final RecoveryController controller;
  final String fileId;
  @override
  State<RecoveryDocumentPage> createState() => _RecoveryDocumentPageState();
}

class _RecoveryDocumentPageState extends State<RecoveryDocumentPage> {
  final input = TextEditingController();
  RecoveryDocument? document;
  Json? log;
  bool loading = false, showLatest = false;
  String? error;
  bool get isLog => widget.fileId == 'runtime-log';
  RecoveryController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    input.addListener(() {
      if (document != null) document!.draft = input.text;
    });
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      if (isLog) {
        final value = await controller.read(widget.fileId);
        if (mounted) setState(() => log = value);
      } else {
        final value = await controller.open(widget.fileId);
        if (mounted) {
          document = value;
          if (input.text != value.draft) input.text = value.draft;
        }
      }
      if (mounted) setState(() => error = null);
    } catch (failure) {
      if (mounted) setState(() => error = recoveryFailure(failure));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final doc = document;
      return PocketScaffold(
        title: Text(_fileName(widget.fileId)),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '读取最新版本',
          onPressed: loading ? null : refresh,
        ),
        body: PocketList(
          children: [
            if (loading) _message('正在读取…'),
            if (error != null) _message(error!),
            if (isLog && log != null)
              PocketSection(
                children: [
                  _message(
                    '日志可能包含路径、工具参数或敏感配置，仅在本机查看。'
                    '${log!['truncated'] == true ? '这里只显示末尾 64 KiB。' : ''}',
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: SelectableText(
                      log!['text'] as String,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            if (doc != null) ...[
              PocketSection(
                children: [
                  _message(
                    controller.maintenance
                        ? '修改原始文件并保留本机备份。保存不会启动服务；请返回恢复运行，交由 DSH 验证配置。'
                        : '当前只能查看。请返回进入维护模式后编辑。',
                  ),
                  if (!doc.existed) _message('此文件尚不存在。首次保存将创建它。'),
                  if (doc.error != null) _message(doc.error!),
                  if (controller.notice != null) _message(controller.notice!),
                  if (doc.requestId != null) ...[
                    _message('保存回执尚未确认：${doc.requestId}\n草稿已保留，不会自动重复提交。'),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: PocketButton.tonal(
                        onPressed: doc.checking
                            ? null
                            : () => controller.checkReceipt(doc),
                        child: const Text('核对保存回执'),
                      ),
                    ),
                    if (controller.canResolveDocument(doc))
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: PocketButton.tonal(
                          onPressed: () => controller.resolveDocument(doc),
                          child: const Text('原进程已退出：以当前文件为新基准，保留草稿'),
                        ),
                      ),
                  ],
                  if (doc.conflict) ...[
                    _message('文件已发生变化。你的草稿保留，保存已暂停。先核对最新文件再决定如何合并。'),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          PocketButton.tonal(
                            onPressed: () =>
                                setState(() => showLatest = !showLatest),
                            child: Text(showLatest ? '收起最新文件' : '查看最新文件'),
                          ),
                          PocketButton.tonal(
                            onPressed:
                                controller.working || doc.requestId != null
                                ? null
                                : () => controller.useLatest(doc),
                            child: const Text('以最新版本为基准，保留我的草稿'),
                          ),
                        ],
                      ),
                    ),
                    if (showLatest)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: SelectableText(doc.observed!['text'] as String),
                      ),
                  ],
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: TextField(
                      key: const ValueKey('recovery-document-input'),
                      controller: input,
                      readOnly: !controller.maintenance,
                      autocorrect: false,
                      enableSuggestions: false,
                      minLines: 12,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(labelText: '配置原文'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              PocketButton(
                key: const ValueKey('recovery-save'),
                onPressed:
                    !controller.maintenance ||
                        controller.working ||
                        controller.pendingAction != null ||
                        doc.requestId != null ||
                        doc.conflict ||
                        !doc.dirty
                    ? null
                    : () => controller.save(doc),
                child: const Text('保存并备份旧版本'),
              ),
              _message('草稿仅在本次 App 进程中保留。已保存的文件和备份保留在应用私有目录。'),
            ],
          ],
        ),
      );
    },
  );
}

class RecoveryBackupPage extends StatefulWidget {
  const RecoveryBackupPage({
    super.key,
    required this.controller,
    required this.backupId,
  });
  final RecoveryController controller;
  final String backupId;
  @override
  State<RecoveryBackupPage> createState() => _RecoveryBackupPageState();
}

class _RecoveryBackupPageState extends State<RecoveryBackupPage> {
  Json? backup, current;
  String? error, notice;
  bool confirming = false, loading = false;
  RecoveryController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    setState(() {
      loading = true;
      confirming = false;
      current = null;
    });
    try {
      final value = await controller.call('readBackup', {
        'backupId': widget.backupId,
      });
      if (value['id'] is! String ||
          value['text'] is! String ||
          value['sha256'] is! String ||
          value['exists'] is! bool) {
        throw const FormatException('Invalid backup');
      }
      final latest = await controller.read(value['id'] as String);
      if (mounted) {
        setState(() {
          backup = value;
          current = latest;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = recoveryFailure(failure));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => PocketScaffold(
      title: const Text('预览配置备份'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新恢复基准',
        onPressed: loading ? null : refresh,
      ),
      body: PocketList(
        children: [
          if (loading) _message('正在读取备份和当前版本…'),
          if (error != null) _message(error!),
          if (controller.error != null) _message(controller.error!),
          if (notice != null) _message(notice!),
          if (backup != null) ...[
            PocketSection(
              title: _fileName(backup!['id'] as String),
              children: [
                _message(
                  backup!['exists'] == true
                      ? '恢复会用下面的备份内容替换当前文件，并先备份当前版本。'
                      : '此备份表示原文件不存在。恢复将移除当前配置文件，并先备份当前版本。',
                ),
                if (backup!['exists'] == true)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: SelectableText(
                      backup!['text'] as String,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ),
                if (confirming)
                  _message(
                    backup!['exists'] == true
                        ? '确认替换当前配置？已有编辑草稿会保留，之后需要核对合并。'
                        : '确认移除当前配置以还原“不存在”的状态？已有编辑草稿会保留。',
                  ),
              ],
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (confirming)
                  PocketButton.tonal(
                    onPressed: controller.working
                        ? null
                        : () => setState(() => confirming = false),
                    child: const Text('取消'),
                  ),
                PocketButton(
                  key: const ValueKey('recovery-restore'),
                  onPressed:
                      !controller.maintenance ||
                          controller.working ||
                          controller.pendingAction != null ||
                          controller.hasPendingDocument ||
                          current == null
                      ? null
                      : () async {
                          if (!confirming) {
                            setState(() => confirming = true);
                            return;
                          }
                          setState(() => confirming = false);
                          final receipt = await controller.trackedMutation(
                            'restore',
                            {
                              'backupId': widget.backupId,
                              'fileId': backup!['id'],
                              'expectedSha256': current!['sha256'],
                            },
                          );
                          if (mounted && receipt != null) {
                            setState(() {
                              current = null;
                              notice = '已恢复备份。返回恢复运行以验证配置。';
                            });
                          }
                        },
                  child: Text(confirming ? '确认恢复' : '恢复此备份'),
                ),
              ],
            ),
            if (!controller.maintenance) _message('请先进入维护模式再恢复备份。'),
            if (controller.hasPendingDocument) _message('先返回编辑文件核对保存回执，再恢复备份。'),
          ],
        ],
      ),
    ),
  );
}
