import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

/// A display snapshot prepared by native App code. Dart cannot submit a scope.
class IsolatedApprovalReview {
  const IsolatedApprovalReview({
    required this.requestId,
    required this.challenge,
    required this.runId,
    required this.sessionId,
    required this.expiresAtMillis,
    required this.active,
    required this.workspacePath,
    required this.readablePaths,
    required this.writablePaths,
    required this.exactHosts,
    required this.fileCallLimit,
    required this.networkCallLimit,
    required this.leaseMillis,
    required this.program,
    required this.programSha256,
    required this.snapshotSha256,
  });

  final String requestId, challenge, runId, sessionId;
  final int expiresAtMillis, fileCallLimit, networkCallLimit, leaseMillis;
  final bool active;
  final String? workspacePath;
  final List<String> readablePaths, writablePaths, exactHosts;
  final String? program;
  final String programSha256, snapshotSha256;

  factory IsolatedApprovalReview.parse(
    Object? raw, {
    bool requireProgram = false,
  }) {
    if (raw is! Map) throw const FormatException('授权请求格式无效');
    List<String> paths(String key) {
      final value = raw[key];
      if (value is! List || value.any((item) => item is! String)) {
        throw const FormatException('授权范围格式无效');
      }
      return List<String>.unmodifiable(value.cast<String>());
    }

    String text(String key) {
      final value = raw[key];
      if (value is! String || value.length < 8) {
        throw const FormatException('授权标识无效');
      }
      return value;
    }

    int count(String key) {
      final value = raw[key];
      if (value is! int || value < 0) throw const FormatException('授权额度无效');
      return value;
    }

    if (raw['active'] is! bool ||
        (raw['workspacePath'] != null && raw['workspacePath'] is! String)) {
      throw const FormatException('授权状态无效');
    }
    final program = raw['program'];
    final programSha256 = raw['programSha256'];
    final snapshotSha256 = raw['snapshotSha256'];
    final sha256 = RegExp(r'^[0-9a-f]{64}$');
    if ((requireProgram && program is! String) ||
        (program != null &&
            (program is! String ||
                program.trim().isEmpty ||
                utf8.encode(program).length > 64 * 1024)) ||
        programSha256 is! String ||
        !sha256.hasMatch(programSha256) ||
        snapshotSha256 is! String ||
        !sha256.hasMatch(snapshotSha256)) {
      throw const FormatException('执行程序审阅内容无效');
    }
    return IsolatedApprovalReview(
      requestId: text('requestId'),
      challenge: text('challenge'),
      runId: text('runId'),
      sessionId: text('sessionId'),
      expiresAtMillis: count('expiresAtMillis'),
      active: raw['active'] as bool,
      workspacePath: raw['workspacePath'] as String?,
      readablePaths: paths('readablePaths'),
      writablePaths: paths('writablePaths'),
      exactHosts: paths('exactHosts'),
      fileCallLimit: count('fileCallLimit'),
      networkCallLimit: count('networkCallLimit'),
      leaseMillis: count('leaseMillis'),
      program: program as String?,
      programSha256: programSha256,
      snapshotSha256: snapshotSha256,
    );
  }

  String get summary => active ? '已授权，可随时撤销' : '等待你确认';
}

class IsolatedApprovalInboxPage extends StatefulWidget {
  const IsolatedApprovalInboxPage({required this.runtime, super.key});
  final RuntimeController runtime;

  @override
  State<IsolatedApprovalInboxPage> createState() =>
      _IsolatedApprovalInboxPageState();
}

class _IsolatedApprovalInboxPageState extends State<IsolatedApprovalInboxPage>
    with WidgetsBindingObserver {
  List<IsolatedApprovalReview> reviews = const [];
  String? error;
  bool loading = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> refresh() async {
    final current = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final response = await widget.runtime.call(
        'runtime.isolatedApprovals.list',
      );
      if (response is! List) throw const FormatException('授权列表格式无效');
      final next = response
          .map(IsolatedApprovalReview.parse)
          .toList(growable: false);
      if (mounted && current == generation) setState(() => reviews = next);
    } catch (_) {
      if (mounted && current == generation) {
        setState(() {
          reviews = const [];
          error = '无法确认隔离脚本授权状态，请重试';
        });
      }
    } finally {
      if (mounted && current == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('隔离脚本授权'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新授权请求',
      onPressed: loading ? null : refresh,
    ),
    body: PocketList(
      children: [
        if (error != null)
          PocketSection(
            children: [
              PocketRow(icon: Icons.error_outline_rounded, title: error!),
            ],
          ),
        if (reviews.isEmpty && error == null)
          PocketSection(
            children: [
              PocketRow(
                icon: loading
                    ? Icons.hourglass_top_rounded
                    : Icons.lock_outline_rounded,
                title: loading ? '正在读取授权请求' : '没有待处理的授权请求',
                subtitle: '默认不能访问文件或网络；仅内部预先登记的单次请求可审阅。',
              ),
            ],
          ),
        if (reviews.isNotEmpty)
          PocketSection(
            title: '仅对指定运行生效',
            divided: true,
            children: [
              for (final review in reviews)
                PocketRow(
                  icon: review.active
                      ? Icons.verified_user_outlined
                      : Icons.shield_outlined,
                  title: review.workspacePath == null ? '网络访问' : '文件访问',
                  subtitle:
                      '${review.workspacePath ?? '仅限指定域名'} · ${review.summary}',
                  onTap: () async {
                    await Navigator.push(
                      context,
                      PocketRoute<void>(
                        builder: (_) => IsolatedApprovalDetailPage(
                          runtime: widget.runtime,
                          review: review,
                        ),
                      ),
                    );
                    if (mounted) unawaited(refresh());
                  },
                ),
            ],
          ),
      ],
    ),
  );
}

class IsolatedApprovalDetailPage extends StatefulWidget {
  const IsolatedApprovalDetailPage({
    required this.runtime,
    required this.review,
    super.key,
  });
  final RuntimeController runtime;
  final IsolatedApprovalReview review;

  @override
  State<IsolatedApprovalDetailPage> createState() =>
      _IsolatedApprovalDetailPageState();
}

class _IsolatedApprovalDetailPageState
    extends State<IsolatedApprovalDetailPage> {
  bool busy = false;
  String? error;
  IsolatedApprovalReview? detailedReview;

  @override
  void initState() {
    super.initState();
    unawaited(loadDetail());
  }

  Future<void> loadDetail() async {
    try {
      final raw = await widget.runtime.call(
        'runtime.isolatedApprovals.detail',
        {'requestId': widget.review.requestId},
      );
      final detail = IsolatedApprovalReview.parse(raw, requireProgram: true);
      if (detail.requestId != widget.review.requestId ||
          detail.challenge != widget.review.challenge ||
          detail.snapshotSha256 != widget.review.snapshotSha256 ||
          detail.active != widget.review.active) {
        throw const FormatException('授权请求已变化');
      }
      if (mounted) setState(() => detailedReview = detail);
    } catch (_) {
      if (mounted) setState(() => error = '授权请求已变化，请返回列表刷新后核对');
    }
  }

  Future<void> decide({required bool allow}) async {
    if (busy || (allow && detailedReview == null)) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (allow) {
        // Native Binder replies use the existing JSON-RPC string envelope;
        // dismissing the Android dialog returns a direct false boolean.
        final receipt = await RuntimeController.channel.invokeMethod<Object?>(
          'isolatedApproval.review',
          {
            'requestId': detailedReview!.requestId,
            'snapshotSha256': detailedReview!.snapshotSha256,
          },
        );
        if (receipt == false) return;
        if (receipt != 'true') throw const FormatException('授权回执无效');
      } else {
        await widget.runtime.call('runtime.isolatedApprovals.deny', {
          'requestId': widget.review.requestId,
          'challenge': widget.review.challenge,
        });
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => error = '授权状态未确认，请返回列表刷新后核对');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget scope(
    String title,
    IconData icon,
    List<String> values, {
    bool files = false,
  }) => PocketSection(
    title: title,
    divided: true,
    children: values.isEmpty
        ? [PocketRow(icon: icon, title: '无')]
        : [
            for (final value in values)
              PocketRow(
                icon: files && value.endsWith('/')
                    ? Icons.folder_outlined
                    : icon,
                title: value,
                subtitle: files
                    ? (value.endsWith('/') ? '此目录及其下文件' : '单个文件')
                    : null,
              ),
          ],
  );

  @override
  Widget build(BuildContext context) {
    final review = detailedReview ?? widget.review;
    return PocketScaffold(
      title: const Text('审阅本次运行'),
      body: PocketList(
        children: [
          PocketSection(
            title: '将要执行',
            children: [
              PocketRow(
                icon: Icons.code_rounded,
                title: '执行代码',
                subtitle: detailedReview == null
                    ? '正在读取完整程序'
                    : '查看完整程序和 SHA-256 摘要',
                onTap: detailedReview == null
                    ? null
                    : () => Navigator.push(
                        context,
                        PocketRoute<void>(
                          builder: (_) => IsolatedApprovalProgramPage(
                            review: detailedReview!,
                          ),
                        ),
                      ),
              ),
            ],
          ),
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.folder_outlined,
                title: review.workspacePath == null
                    ? '不访问工作区'
                    : review.workspacePath!,
                subtitle: '本次运行 ${review.runId.substring(0, 8)}',
              ),
            ],
          ),
          scope(
            '允许读取',
            Icons.visibility_outlined,
            review.readablePaths,
            files: true,
          ),
          scope('允许写入', Icons.edit_outlined, review.writablePaths, files: true),
          scope('允许联网的域名', Icons.public_rounded, review.exactHosts),
          PocketSection(
            title: '使用限制',
            divided: true,
            children: [
              PocketRow(
                icon: Icons.folder_copy_outlined,
                title: '文件调用 ${review.fileCallLimit} 次',
              ),
              PocketRow(
                icon: Icons.wifi_outlined,
                title: '网络调用 ${review.networkCallLimit} 次',
              ),
              PocketRow(
                icon: Icons.timer_outlined,
                title: '运行租期 ${review.leaseMillis ~/ 1000} 秒',
              ),
            ],
          ),
          if (error != null)
            PocketSection(
              children: [
                PocketRow(icon: Icons.error_outline_rounded, title: error!),
              ],
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!review.active)
                  PocketButton(
                    onPressed: busy || detailedReview == null
                        ? null
                        : () => decide(allow: true),
                    child: const Text('检查后允许这次运行'),
                  ),
                PocketButton.tonal(
                  onPressed: busy ? null : () => decide(allow: false),
                  child: Text(review.active ? '撤销授权' : '拒绝'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full, read-only code review. It never offers an editor, selection or copy action.
class IsolatedApprovalProgramPage extends StatelessWidget {
  const IsolatedApprovalProgramPage({required this.review, super.key});

  final IsolatedApprovalReview review;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return PocketScaffold(
      title: const Text('执行代码'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本次运行的完整程序', style: textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(
              review.program!,
              softWrap: true,
              style: textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                height: 1.45,
              ),
            ),
            const SizedBox(height: 28),
            Text('程序 SHA-256', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              review.programSha256,
              softWrap: true,
              style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 18),
            Text('授权快照 SHA-256', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              review.snapshotSha256,
              softWrap: true,
              style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}
