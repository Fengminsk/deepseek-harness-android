import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'recovery_data.dart';
import 'confirmation.dart';
import 'runtime.dart';
import 'ui.dart';
import 'text_document_page.dart';

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

String _operationName(dynamic method) => switch (method) {
  'write' => '保存启动配置',
  'restore' => '恢复配置备份',
  'runtimeRepair' => '修复内嵌运行资源',
  _ => '其他维护操作',
};

String _recordTime(dynamic value) {
  if (value is! int || value <= 0) return '时间未记录';
  final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${date.year}-${pad(date.month)}-${pad(date.day)} '
      '${pad(date.hour)}:${pad(date.minute)}';
}

Widget _operationDetails(Json operation) => TextDocumentRow(
  title: '查看技术详情',
  icon: Icons.info_outline_rounded,
  selectable: true,
  monospace: true,
  text: [
    '操作：${_operationName(operation['method'])}',
    '状态：${_operationState(operation['state'])}',
    for (final key in [
      'method',
      'requestId',
      'fileId',
      'generation',
      'sha256',
      'backupId',
    ])
      if (operation[key] != null) '$key: ${operation[key]}',
  ].join('\n'),
);

class RecoveryPage extends StatefulWidget {
  const RecoveryPage({super.key, required this.controller});
  final RecoveryController controller;
  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  bool confirmMaintenance = false;
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
      // Native mode admission remains available when configuration inspection fails.
      final canAct = !controller.working;
      return PopScope<void>(
        canPop: !confirmMaintenance,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && confirmMaintenance) {
            setState(() => confirmMaintenance = false);
          }
        },
        child: PocketConfirmationLayer(
          confirmation: confirmMaintenance
              ? PocketConfirmation(
                  title: '进入维护模式？',
                  message: 'Agent 与 Web 将停止，当前任务会被中断。会话、凭据、文件授权和 Web 偏好会保留。',
                  secondaryLabel: '取消',
                  onSecondary: () => setState(() => confirmMaintenance = false),
                  primaryLabel: '停止并维护',
                  onPrimary: canAct
                      ? () {
                          if (!confirmMaintenance || controller.working) return;
                          setState(() => confirmMaintenance = false);
                          unawaited(controller.changeMode(enter: true));
                        }
                      : null,
                )
              : null,
          child: PocketScaffold(
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
                      _message(
                        '启动偏好读取失败：${controller.state['preferenceError']}',
                      ),
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

                PocketSection(
                  divided: true,
                  children: [
                    if (controller.state['mode'] == 'maintenance')
                      PocketRow(
                        key: const ValueKey('recovery-resume'),
                        icon: Icons.play_arrow_rounded,
                        title: '恢复运行',
                        subtitle: '启动服务并验证保存的配置',
                        onTap: canAct
                            ? () => controller.changeMode(enter: false)
                            : null,
                      )
                    else
                      PocketRow(
                        key: const ValueKey('recovery-enter'),
                        icon: Icons.build_outlined,
                        title: '进入维护模式',
                        subtitle: '停止当前工作后编辑启动配置',
                        onTap: canAct
                            ? () {
                                FocusManager.instance.primaryFocus?.unfocus();
                                setState(() => confirmMaintenance = true);
                              }
                            : null,
                      ),
                    if (controller.pendingAction != null)
                      PocketRow(
                        icon: Icons.pending_actions_rounded,
                        title: '有操作待核对',
                        subtitle:
                            '${_operationName(controller.pendingAction!['method'])} · ${_operationState(controller.pendingAction!['state'])}',
                        onTap: () => open(
                          RecoveryOperationsPage(controller: controller),
                        ),
                      ),
                  ],
                ),
                PocketSection(
                  title: '启动配置',
                  divided: true,
                  children: [
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
                        title: '启动日志',
                        subtitle: '查看最近的运行记录',
                        onTap: () => open(
                          RecoveryDocumentPage(
                            controller: controller,
                            fileId: 'runtime-log',
                          ),
                        ),
                      ),
                    const TextDocumentRow(
                      title: '配置说明',
                      text: '保存启动配置前会备份旧版本。语法或插件配置错误可能导致启动失败，可从本机备份恢复。保存不会启动服务，恢复运行后由 DSH 验证配置。',
                      icon: Icons.info_outline_rounded,
                    ),
                  ],
                ),
                PocketSection(
                  title: '维护',
                  divided: true,
                  children: [
                    PocketRow(
                      key: const ValueKey('recovery-backups'),
                      icon: Icons.history_rounded,
                      title: '配置备份',
                      subtitle: controller.current
                          ? '${controller.backups.length} 份本机备份'
                          : '备份状态待核对',
                      onTap: () =>
                          open(RecoveryBackupsPage(controller: controller)),
                    ),
                    PocketRow(
                      key: const ValueKey('recovery-resources'),
                      icon: Icons.inventory_2_outlined,
                      title: '内嵌运行资源',
                      subtitle: '检查与修复运行时缓存',
                      onTap: () =>
                          open(RecoveryResourcesPage(controller: controller)),
                    ),
                    PocketRow(
                      key: const ValueKey('recovery-operations'),
                      icon: Icons.receipt_long_outlined,
                      title: '操作记录',
                      subtitle: controller.pendingAction != null
                          ? '有操作结果待核对'
                          : '查看维护操作与结果',
                      onTap: () =>
                          open(RecoveryOperationsPage(controller: controller)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class RecoveryBackupsPage extends StatelessWidget {
  const RecoveryBackupsPage({super.key, required this.controller});
  final RecoveryController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => PocketScaffold(
      title: const Text('配置备份'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新配置备份',
        onPressed: controller.loading ? null : controller.load,
      ),
      body: PocketList(
        children: [
          _message('保存或恢复配置时，会先备份当前版本。打开一份备份核对内容后，再决定是否恢复。'),
          if (controller.readError != null) _message(controller.readError!),
          if (!controller.current) _message('当前备份列表尚未核实，请刷新后再打开。'),
          if (controller.current && controller.backups.isEmpty)
            _message('尚无配置备份。'),
          if (controller.backups.isNotEmpty)
            PocketSection(
              divided: true,
              children: [
                for (final backup in controller.backups)
                  PocketRow(
                    key: ValueKey('recovery-backup:${backup['id']}'),
                    icon: Icons.description_outlined,
                    title: _fileName('${backup['fileId']}'),
                    subtitle:
                        '${_recordTime(backup['createdAt'])} · ${backup['exists'] == true ? '包含原文件' : '原文件不存在'}',
                    onTap: !controller.current || controller.loading
                        ? null
                        : () async {
                            await Navigator.push<void>(
                              context,
                              PocketRoute<void>(
                                builder: (_) => RecoveryBackupPage(
                                  controller: controller,
                                  backupId: backup['id'] as String,
                                ),
                              ),
                            );
                            await controller.load();
                          },
                  ),
              ],
            ),
        ],
      ),
    ),
  );
}

class RecoveryOperationsPage extends StatelessWidget {
  const RecoveryOperationsPage({super.key, required this.controller});
  final RecoveryController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => PocketScaffold(
      title: const Text('操作记录'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新操作记录',
        onPressed: controller.loading ? null : controller.load,
      ),
      body: PocketList(
        children: [
          if (controller.error != null) _message(controller.error!),
          if (controller.notice != null) _message(controller.notice!),
          if (controller.readError != null) _message(controller.readError!),
          if (controller.pendingAction != null)
            PocketSection(
              title: '待核对',
              divided: true,
              children: [
                PocketTile(
                  title: Text(
                    _operationName(controller.pendingAction!['method']),
                  ),
                  subtitle: Text(
                    _operationState(controller.pendingAction!['state']),
                  ),
                ),
                PocketRow(
                  icon: Icons.sync_rounded,
                  title: '核对原请求回执',
                  onTap: controller.checkAction,
                ),
                _operationDetails(controller.pendingAction!),
                if (controller.canAcknowledgeAction) ...[
                  _message('原操作所属进程已退出。先核对实际文件状态，再接受这条未确认记录。原请求不会重发。'),
                  PocketRow(
                    icon: Icons.check_rounded,
                    title: '保留未确认记录，继续手动处理',
                    onTap: controller.acknowledgeAction,
                  ),
                ],
              ],
            ),
          if (!controller.current) _message('显示上次读取的记录，当前状态尚未核实。'),
          if (controller.current &&
              controller.operations.isEmpty &&
              controller.pendingAction == null)
            _message('尚无维护操作记录。'),
          if (controller.operations.isNotEmpty)
            PocketSection(
              title: '历史',
              divided: true,
              children: [
                for (final operation in controller.operations)
                  PocketRow(
                    key: ValueKey(
                      'recovery-operation:${operation['requestId']}',
                    ),
                    icon: Icons.receipt_long_outlined,
                    title: _operationName(operation['method']),
                    subtitle:
                        '${_operationState(operation['state'])} · ${_recordTime(operation['createdAt'])}',
                    onTap: () => Navigator.push<void>(
                      context,
                      PocketRoute<void>(
                        builder: (_) => PocketScaffold(
                          title: Text(_operationName(operation['method'])),
                          body: PocketList(
                            children: [
                              _message('此页显示打开时的记录。核对最新结果请返回刷新操作记录。'),
                              PocketSection(
                                children: [
                                  PocketTile(
                                    title: const Text('状态'),
                                    subtitle: Text(
                                      _operationState(operation['state']),
                                    ),
                                  ),
                                  PocketTile(
                                    title: const Text('时间'),
                                    subtitle: Text(
                                      _recordTime(operation['createdAt']),
                                    ),
                                  ),
                                  if (operation['fileId'] is String &&
                                      (operation['fileId'] as String)
                                          .isNotEmpty)
                                    PocketTile(
                                      title: const Text('配置文件'),
                                      subtitle: Text(
                                        _fileName(
                                          operation['fileId'] as String,
                                        ),
                                      ),
                                    ),
                                  _operationDetails(operation),
                                ],
                              ),
                            ],
                          ),
                        ),
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

class RecoveryResourcesPage extends StatefulWidget {
  const RecoveryResourcesPage({super.key, required this.controller});
  final RecoveryController controller;
  @override
  State<RecoveryResourcesPage> createState() => _RecoveryResourcesPageState();
}

class _RecoveryResourcesPageState extends State<RecoveryResourcesPage> {
  String? reviewedHash, reviewedGeneration;
  RecoveryController get controller => widget.controller;
  bool get canRepair =>
      controller.maintenance &&
      !controller.working &&
      controller.pendingAction == null &&
      !controller.hasPendingDocument &&
      controller.boot['runtimeSha256'] is String;
  bool get reviewCurrent =>
      canRepair &&
      reviewedHash == controller.boot['runtimeSha256'] &&
      reviewedGeneration == controller.generation;
  void dismiss() => setState(() {
    reviewedHash = null;
    reviewedGeneration = null;
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => PopScope<void>(
      canPop: reviewedHash == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && reviewedHash != null) dismiss();
      },
      child: PocketConfirmationLayer(
        confirmation: reviewedHash == null
            ? null
            : PocketConfirmation(
                title: '修复运行资源？',
                message: reviewCurrent
                    ? '将隔离当前内嵌运行资源缓存。恢复运行后会从已安装 APK 重新解包，会话、凭据和文件授权会保留。'
                    : '运行资源或维护状态已变化。请取消后刷新状态，重新核对。',
                secondaryLabel: '取消',
                onSecondary: dismiss,
                primaryLabel: '隔离并修复',
                onPrimary: !reviewCurrent
                    ? null
                    : () {
                        if (!reviewCurrent || reviewedHash == null) return;
                        final hash = reviewedHash;
                        dismiss();
                        unawaited(
                          controller.trackedMutation('runtimeRepair', {
                            'expectedRuntimeSha256': hash,
                          }),
                        );
                      },
              ),
        child: PocketScaffold(
          title: const Text('内嵌运行资源'),
          trailing: GlassButton(
            icon: Icons.refresh_rounded,
            label: '刷新运行资源状态',
            onPressed: controller.loading ? null : controller.load,
          ),
          body: PocketList(
            children: [
              if (controller.error != null) _message(controller.error!),
              if (controller.notice != null) _message(controller.notice!),
              if (controller.readError != null) _message(controller.readError!),
              PocketSection(
                divided: true,
                children: [
                  const TextDocumentRow(
                    title: '修复说明',
                    text: '修复仅隔离当前已解包的运行资源缓存，不重置会话、凭据、文档授权或用户配置。需要先进入维护模式；修复后返回恢复运行，由已安装 APK 重新提供运行资源。',
                    icon: Icons.info_outline_rounded,
                  ),
                  PocketRow(
                    key: const ValueKey('recovery-repair'),
                    icon: Icons.build_outlined,
                    title: '修复内嵌运行资源',
                    onTap: canRepair
                        ? () => setState(() {
                            reviewedHash =
                                controller.boot['runtimeSha256'] as String;
                            reviewedGeneration = controller.generation;
                          })
                        : null,
                  ),
                ],
              ),
              if (!controller.maintenance) _message('请先返回进入维护模式，再修复运行资源。'),
              if (controller.hasPendingDocument)
                _message('先返回编辑文件核对保存回执，再修复运行资源。'),
              if (controller.pendingAction != null)
                _message('已有维护操作结果待核对，请返回操作记录处理。'),
            ],
          ),
        ),
      ),
    ),
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
  bool loading = false;
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
        if (mounted) {
          setState(() {
            log = value;
            input.text = value['text'] as String;
          });
        }
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
                    child: TextDocumentField(
                      controller: input,
                      readOnly: true,
                      monospace: true,
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
                            onPressed:
                                controller.working || doc.requestId != null
                                ? null
                                : () => controller.useLatest(doc),
                            child: const Text('以最新版本为基准，保留我的草稿'),
                          ),
                        ],
                      ),
                    ),
                    TextDocumentRow(
                      title: '查看最新文件',
                      selectable: true,
                      text: doc.observed!['text'] as String,
                      monospace: true,
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: TextDocumentField(
                      fieldKey: const ValueKey('recovery-document-input'),
                      controller: input,
                      readOnly: !controller.maintenance,
                      monospace: true,
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
  String? error, notice, readGeneration;
  bool confirming = false, loading = false;
  RecoveryController get controller => widget.controller;
  bool get canRestore =>
      controller.maintenance &&
      !controller.working &&
      controller.pendingAction == null &&
      !controller.hasPendingDocument &&
      !loading &&
      backup != null &&
      current != null &&
      readGeneration == controller.generation;

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    final generation = controller.generation;
    setState(() {
      loading = true;
      confirming = false;
      backup = null;
      current = null;
      readGeneration = null;
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
      if (!mounted) return;
      if (generation != controller.generation) {
        setState(() => error = '服务已变化，请重新读取备份和当前文件。');
        return;
      }
      setState(() {
        backup = value;
        current = latest;
        readGeneration = generation;
        error = null;
      });
    } catch (failure) {
      if (mounted) setState(() => error = recoveryFailure(failure));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> restore() async {
    if (!confirming || !canRestore) return;
    final params = <String, dynamic>{
      'backupId': widget.backupId,
      'fileId': backup!['id'],
      'expectedSha256': current!['sha256'],
    };
    setState(() => confirming = false);
    final receipt = await controller.trackedMutation('restore', params);
    if (mounted && receipt != null) {
      setState(() {
        current = null;
        notice = '已恢复备份。返回恢复运行以验证配置。';
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => PopScope<void>(
      canPop: !confirming,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && confirming) setState(() => confirming = false);
      },
      child: PocketConfirmationLayer(
        confirmation: !confirming
            ? null
            : PocketConfirmation(
                title: backup?['exists'] == true ? '恢复这份配置？' : '移除当前配置？',
                message: !canRestore
                    ? '维护状态或文件基准已变化。请取消后重新读取，再核对恢复内容。'
                    : backup!['exists'] == true
                    ? '将用这份备份替换当前配置，并先备份当前版本。已有编辑草稿会保留，之后需要核对合并。'
                    : '此备份记录的是“不存在”状态。恢复将移除当前配置文件，并先备份当前版本。已有编辑草稿会保留。',
                secondaryLabel: '取消',
                onSecondary: () => setState(() => confirming = false),
                primaryLabel: backup?['exists'] == true ? '恢复配置' : '移除并恢复',
                onPrimary: canRestore ? restore : null,
              ),
        child: PocketScaffold(
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
                  divided: true,
                  children: [
                    _message(
                      backup!['exists'] == true
                          ? '恢复会用备份内容替换当前文件，并先备份当前版本。'
                          : '此备份表示原文件不存在。恢复将移除当前配置文件，并先备份当前版本。',
                    ),
                    if (backup!['exists'] == true)
                      TextDocumentRow(
                        title: '查看备份内容',
                        selectable: true,
                        text: backup!['text'] as String,
                        monospace: true,
                      ),
                  ],
                ),
                PocketButton(
                  key: const ValueKey('recovery-restore'),
                  onPressed: !canRestore
                      ? null
                      : () => setState(() => confirming = true),
                  child: const Text('恢复此备份'),
                ),
              ],
              if (backup != null && readGeneration != controller.generation)
                _message('服务已变化，请刷新恢复基准。'),
              if (!controller.maintenance) _message('请先进入维护模式再恢复备份。'),
              if (controller.hasPendingDocument)
                _message('先返回编辑文件核对保存回执，再恢复备份。'),
            ],
          ),
        ),
      ),
    ),
  );
}
