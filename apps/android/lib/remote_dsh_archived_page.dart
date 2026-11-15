// 已归档任务页：列出那台电脑上已归档的会话，恢复它们或直接打开。
//
// 数据全部来自注入的 [RemoteDshArchiveSource]：生产实现是
// `RemoteDshLiveSource`（读 `library.catalog`、写 `library.sessionArchive`），
// 测试可以注入替身，因此本页不直接发网络请求，也不认识门面方法名。
//
// 归档动作由电脑上的 DSH 发起（Web、桌面 App 或会话菜单）；本页只做「查看 +
// 取消归档」，空态因此说明归档是在电脑上完成的。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'flclash/typography.dart';
import 'ui.dart';

/// 已归档任务页的数据来源。
///
/// 页面只调用两个方法：读取已归档会话与取消归档。两者失败都应抛
/// `PlatformException`，`message` 已是可直接展示的中文。
abstract class RemoteDshArchiveSource {
  /// 读取那台电脑上已归档的会话（标题取自 `library.catalog`）。
  Future<List<RemoteDshArchivedSession>> listArchivedSessions();

  /// 取消归档 [sessionId]（`library.sessionArchive` 的 `archived: false`）。
  Future<void> restoreSession(String sessionId);
}

/// 一条已归档的会话，只承载展示字段。
class RemoteDshArchivedSession {
  const RemoteDshArchivedSession({
    required this.id,
    required this.title,
    this.projectName = '',
  });

  /// 会话标识，用于打开会话与发起恢复。
  final String id;

  /// 会话标题；没有标题时是占位文案。
  final String title;

  /// 所属项目名；电脑没有给出目录时为空字符串。
  final String projectName;
}

/// 远程 DSH 的已归档任务页。
///
/// [onOpen] 由打开本页的首页提供：归档页不自己构造会话数据源，点按一行时把
/// 选中的会话交回调用方，由它按和首页会话行完全相同的方式打开会话。
class RemoteDshArchivedPage extends StatefulWidget {
  const RemoteDshArchivedPage({super.key, required this.source, this.onOpen});

  /// 本页作为全屏目的地的标识（见 [openDestination]）。
  static const String routeDestination = 'remote-dsh-archived';

  /// 已归档会话的数据来源。
  final RemoteDshArchiveSource source;

  /// 打开一条已归档会话；为 null 时行不可点。
  final ValueChanged<RemoteDshArchivedSession>? onOpen;

  @override
  State<RemoteDshArchivedPage> createState() => _RemoteDshArchivedPageState();
}

class _RemoteDshArchivedPageState extends State<RemoteDshArchivedPage> {
  List<RemoteDshArchivedSession> _sessions = const [];
  String? _error;
  bool _loading = true;

  /// 正在恢复的会话标识；对应行的按钮显示「恢复中」并不可点。
  final Set<String> _restoring = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 读取已归档会话；失败时保留可重试的错误说明。
  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await widget.source.listArchivedSessions();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _messageOf(error);
        _loading = false;
      });
    }
  }

  /// 恢复一条已归档会话：回写电脑成功后重读列表，会话离开本页。
  Future<void> _restore(RemoteDshArchivedSession session) async {
    if (_restoring.contains(session.id)) return;
    setState(() => _restoring.add(session.id));
    try {
      await widget.source.restoreSession(session.id);
      if (!mounted) return;
      // 重读而不是本地删行：电脑上的归档集合才是事实，失败时也要能看到真实状态。
      await _load();
      if (!mounted) return;
      _notice('已恢复「${session.title}」，它会回到项目列表。');
    } catch (error) {
      if (!mounted) return;
      _notice('恢复失败：${_messageOf(error)}');
    } finally {
      if (mounted) setState(() => _restoring.remove(session.id));
    }
  }

  /// 可展示的中文说明：门面失败一律是 `PlatformException`。
  static String _messageOf(Object error) {
    if (error is PlatformException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) return message;
    }
    return '请检查与电脑的连接后重试。';
  }

  void _notice(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return PocketScaffold(
      title: const Text('已归档任务'),
      trailing: GlassButton(
        key: const ValueKey('remote-archived-refresh'),
        icon: Icons.refresh_rounded,
        label: '刷新已归档任务',
        onPressed: _loading ? null : () => unawaited(_load()),
      ),
      body: _content(),
    );
  }

  Widget _content() {
    final error = _error;
    if (error != null) {
      return PocketEmpty(
        child: _ArchivedNotice(
          icon: Icons.cloud_off_rounded,
          title: '读取已归档任务失败',
          message: error,
          actionLabel: '重试',
          onAction: () => unawaited(_load()),
        ),
      );
    }
    if (_loading) {
      return const PocketEmpty(
        child: _ArchivedNotice(
          icon: Icons.hourglass_top_rounded,
          title: '正在读取已归档任务',
          message: '正在从电脑读取已归档的会话。',
        ),
      );
    }
    if (_sessions.isEmpty) {
      return PocketEmpty(
        child: _ArchivedNotice(
          icon: Icons.archive_outlined,
          title: '没有已归档的任务',
          message: '在电脑上的 DSH 里归档的会话会显示在这里。恢复后会回到项目与会话列表。',
          actionLabel: '刷新',
          onAction: () => unawaited(_load()),
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    return PocketList(
      key: const ValueKey('remote-archived-list'),
      children: [
        PocketSection(
          title: '共 ${_sessions.length} 个已归档会话',
          divided: true,
          children: [
            for (final session in _sessions)
              PocketTile(
                key: ValueKey('remote-archived-${session.id}'),
                leading: const Icon(Icons.archive_outlined),
                title: Text(
                  session.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: session.projectName.trim().isEmpty
                    ? null
                    : Text(
                        session.projectName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: _restoring.contains(session.id)
                    ? SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary,
                        ),
                      )
                    : TextButton(
                        key: ValueKey('remote-archived-restore-${session.id}'),
                        onPressed: () => unawaited(_restore(session)),
                        child: const Text('恢复'),
                      ),
                onTap: widget.onOpen == null
                    ? null
                    : () => widget.onOpen!(session),
              ),
          ],
        ),
      ],
    );
  }
}

/// 空态、加载与读取失败共用的居中提示：图标、标题、说明与可选动作。
///
/// 与远程首页的提示保持同一套排版；文字按当前字号缩放换行，放大字体时仍能
/// 完整读到。
class _ArchivedNotice extends StatelessWidget {
  const _ArchivedNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  /// 顶部图标，取自当前主题的前景色。
  final IconData icon;

  /// 提示标题。
  final String title;

  /// 一段说明，不写营销语。
  final String message;

  /// 动作按钮文案；为空时不显示按钮。
  final String? actionLabel;

  /// 动作回调；为空时按钮同样不显示。
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final actionLabel = this.actionLabel;
    final onAction = this.onAction;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: colors.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: AppTextStyle.title3.of(context, emphasized: true),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(color: colors.onSurfaceVariant),
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 20),
          PocketButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ],
    );
  }
}
