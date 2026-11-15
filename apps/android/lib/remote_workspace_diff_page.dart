// 远程「本次变更」页：把当前会话最后一轮的变更摘要与单个文件的差异搬到手机上。
//
// 数据全部来自注入的 [RemoteWorkspaceChangesSource]：生产实现由
// `RemoteConversationLiveSource.createWorkspaceChangesSource()` 提供（走
// `workspaceChanges.summary` / `.diff` / `.cancel`）；测试注入替身，因此本页
// 不直接发门面请求，也不认识 owner / requestId / 序号扫描这些线上细节。
//
// 快照定位是异步且可能降级的：宿主只为当前进程里的 `workspace/changes` 事件保留
// 快照，电脑重启后旧轮次读不到。页面因此把「正在查找 / 本轮未结束 / 找不到 /
// 读取失败」分别展示，并给每一种状态留一个重试入口；离开页面时取消在途请求。
//
// 差异渲染复用本地工作区差异的 [WorkspaceDiffBody]：懒加载行、自动换行与横向
// 滚动都和电脑端同一套行为；文件列表复用 [WorkspaceChangedFileTile]。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'flclash/typography.dart';
import 'remote_conversation_source.dart';
import 'runtime_transport.dart';
import 'ui.dart';
import 'workspace_change_widgets.dart';
import 'workspace_changes.dart';
import 'workspace_diff.dart';

/// 远程 DSH 的「本次变更」页。
///
/// [source] 由调用方创建并交给本页持有：页面在 [State.dispose] 里先取消在途
/// 请求再释放它。页面不缓存跨打开的数据，每次打开都重新定位快照。
class RemoteWorkspaceDiffPage extends StatefulWidget {
  const RemoteWorkspaceDiffPage({super.key, required this.source});

  /// 本页作为全屏目的地的标识（见 [openDestination]）。
  ///
  /// 只从会话页进入，且会话页本身已经是按会话区分的全屏目的地，因此同一层栈上
  /// 不会出现两个「本次变更」。
  static const String routeDestination = 'remote-workspace-changes';

  /// 本次变更的数据来源；本页持有并在销毁时释放。
  final RemoteWorkspaceChangesSource source;

  @override
  State<RemoteWorkspaceDiffPage> createState() =>
      _RemoteWorkspaceDiffPageState();
}

class _RemoteWorkspaceDiffPageState extends State<RemoteWorkspaceDiffPage> {
  final _scroll = ScrollController();
  final _horizontal = ScrollController();

  /// 最近一次快照查找的结果；查找期间为 null。
  RemoteWorkspaceChangesResolution? _resolution;

  /// 查找进度；宿主一次就命中时为 null。
  RemoteWorkspaceScanProgress? _progress;

  bool _resolving = true;

  /// 查找代次：重新查找或页面关闭后，旧结果不再落到页面上。
  int _generation = 0;

  /// 已定位快照对应的 `workspace/changes` 事件序号与摘要。
  int? _seq;
  WorkspaceChangesSummary? _summary;

  /// 当前打开的文件下标；null 表示停在文件列表。
  int? _index;

  WorkspaceFileDiff? _diff;
  String? _diffError;
  bool _loadingDiff = false;

  /// 差异读取代次：换文件或重新查找后，旧响应被丢弃。
  int _diffGeneration = 0;

  /// 差异行是否自动换行；长行可以改成横向滚动。
  bool _wrap = true;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void dispose() {
    _generation++;
    _diffGeneration++;
    // 取消是尽力而为：宿主侧的并发名额要尽早释放，但页面不等待它。
    unawaited(widget.source.cancelInFlight());
    widget.source.dispose();
    _scroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 快照

  /// 重新定位本轮快照，并把页面收回到文件列表。
  Future<void> _resolve() async {
    final generation = ++_generation;
    _diffGeneration++;
    unawaited(widget.source.cancelInFlight());
    setState(() {
      _resolving = true;
      _progress = null;
      _seq = null;
      _summary = null;
      _resolution = null;
      _index = null;
      _diff = null;
      _diffError = null;
      _loadingDiff = false;
    });
    final resolution = await widget.source.resolveSnapshot(
      onProgress: (progress) {
        if (!mounted || generation != _generation) return;
        setState(() => _progress = progress);
      },
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _resolving = false;
      _progress = null;
      _resolution = resolution;
      if (resolution is RemoteWorkspaceChangesFound) {
        _seq = resolution.seq;
        _summary = resolution.summary;
      }
    });
  }

  // ------------------------------------------------------------------ 差异

  /// 打开第 [index] 个文件的差异；成功后停在差异视图。
  Future<void> _select(int index) async {
    final summary = _summary;
    final seq = _seq;
    if (summary == null || seq == null) return;
    if (index < 0 || index >= summary.files.length) return;
    final generation = ++_diffGeneration;
    setState(() {
      _index = index;
      _loadingDiff = true;
      _diff = null;
      _diffError = null;
    });
    try {
      final diff = await widget.source.loadDiff(seq, index);
      if (!mounted || generation != _diffGeneration) return;
      setState(() {
        _loadingDiff = false;
        // 摘要与差异必须描述同一个文件；不一致时不展示另一份内容。
        if (diff.path != summary.files[index].path) {
          _diffError = '电脑返回的差异与所选文件不一致。';
        } else {
          _diff = diff;
        }
      });
    } on RuntimeTransportFailure catch (failure) {
      if (!mounted || generation != _diffGeneration) return;
      setState(() {
        _loadingDiff = false;
        _diffError = failure.message;
      });
    } on Object catch (error) {
      if (!mounted || generation != _diffGeneration) return;
      setState(() {
        _loadingDiff = false;
        _diffError = '读取文件差异失败：$error';
      });
    }
  }

  /// 回到文件列表；在途差异响应由代次丢弃。
  void _backToFiles() {
    if (_index == null) return;
    _diffGeneration++;
    setState(() {
      _index = null;
      _diff = null;
      _diffError = null;
      _loadingDiff = false;
    });
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final inDiff = _index != null;
    return PocketScaffold(
      title: const Text('本次变更'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inDiff) ...[
            GlassButton(
              key: const ValueKey('remote-changes-wrap'),
              icon: _wrap ? Icons.wrap_text_rounded : Icons.notes_rounded,
              label: _wrap ? '关闭自动换行' : '自动换行',
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
            const SizedBox(width: 6),
          ],
          GlassButton(
            key: const ValueKey('remote-changes-refresh'),
            icon: Icons.refresh_rounded,
            label: '刷新本次变更',
            onPressed: _resolving ? null : () => unawaited(_resolve()),
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_resolving) {
      final progress = _progress;
      return PocketEmpty(
        key: const ValueKey('remote-changes-resolving'),
        child: _ChangesNotice(
          icon: Icons.hourglass_top_rounded,
          title: '正在读取本次变更',
          message: progress == null || progress.limit <= 1
              ? '正在查找这台电脑上这一轮的变更快照。'
              : '正在查找变更快照…（第 ${progress.attempt}/${progress.limit} 步）',
        ),
      );
    }
    switch (_resolution) {
      case RemoteWorkspaceChangesPendingTurn():
        return PocketEmpty(
          key: const ValueKey('remote-changes-pending-turn'),
          child: _ChangesNotice(
            icon: Icons.pending_outlined,
            title: '本轮结束后可查看变更',
            message: '这台电脑在轮次结束后才记录文件变更；等这一轮结束再回来刷新。',
            actionLabel: '刷新',
            onAction: () => unawaited(_resolve()),
          ),
        );
      case RemoteWorkspaceChangesUnavailable(:final announced):
        return PocketEmpty(
          key: const ValueKey('remote-changes-unavailable'),
          child: _ChangesNotice(
            icon: Icons.inbox_outlined,
            title: announced ? '这轮改动的内容已不可用' : '本次没有可查看的文件变更',
            message: announced
                ? '变更快照只保留在电脑当前运行的 DSH 进程里；电脑重启或宿主重启后，'
                      '旧轮次的内容就读不到了。'
                : '这台电脑还没有记录到文件变更，或当前会话窗口里没有变更记录。'
                      '先在电脑上跑一轮会修改文件的任务，再回来刷新。',
            actionLabel: '刷新',
            onAction: () => unawaited(_resolve()),
          ),
        );
      case RemoteWorkspaceChangesFailure(:final message):
        return PocketEmpty(
          key: const ValueKey('remote-changes-failed'),
          child: _ChangesNotice(
            icon: Icons.cloud_off_rounded,
            title: '读取本次变更失败',
            message: message,
            actionLabel: '重试',
            onAction: () => unawaited(_resolve()),
          ),
        );
      case RemoteWorkspaceChangesFound():
      case null:
        break;
    }
    final summary = _summary;
    if (summary == null) {
      return const PocketEmpty(
        child: _ChangesNotice(
          icon: Icons.inbox_outlined,
          title: '本次没有可查看的文件变更',
          message: '这台电脑没有返回变更摘要。',
        ),
      );
    }
    if (summary.files.isEmpty) {
      return PocketEmpty(
        key: const ValueKey('remote-changes-empty'),
        child: _ChangesNotice(
          icon: Icons.check_circle_outline_rounded,
          title: '这一轮没有文件变更',
          message: '第 ${summary.turn} 轮结束时没有检测到文件改动。',
          actionLabel: '刷新',
          onAction: () => unawaited(_resolve()),
        ),
      );
    }
    final index = _index;
    if (index == null || index >= summary.files.length) {
      return _fileList(summary);
    }
    return _diffBody(summary, index);
  }

  /// 变更文件列表：点一行读取该文件的差异。
  Widget _fileList(WorkspaceChangesSummary summary) {
    final files = summary.files;
    return PocketList(
      key: const ValueKey('remote-changes-files'),
      children: [
        PocketSection(
          title: '第 ${summary.turn} 轮 · ${summary.total} 个文件',
          divided: true,
          children: [
            for (var index = 0; index < files.length; index++)
              WorkspaceChangedFileTile(
                key: ValueKey('remote-changes-file-$index'),
                file: files[index],
                onTap: () => unawaited(_select(index)),
              ),
          ],
        ),
        if (summary.total > files.length)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              '显示 ${files.length} 个文件，共 ${summary.total} 个。',
              style: AppTextStyle.footnote.of(context),
            ),
          ),
      ],
    );
  }

  /// 单个文件的差异视图；顶部文件条点按回到文件列表。
  Widget _diffBody(WorkspaceChangesSummary summary, int index) {
    final file = summary.files[index];
    final error = _diffError;
    final WorkspaceRead<WorkspaceFileDiff> state = _loadingDiff
        ? const WorkspaceRead(WorkspaceReadPhase.loading)
        : error != null
        ? const WorkspaceRead(WorkspaceReadPhase.error)
        : _diff != null
        ? WorkspaceRead(WorkspaceReadPhase.ready, _diff)
        : const WorkspaceRead(WorkspaceReadPhase.idle);
    return WorkspaceDiffBody(
      key: const ValueKey('remote-changes-diff'),
      state: state,
      wrap: _wrap,
      controller: _scroll,
      horizontalController: _horizontal,
      header: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PocketSection(
            children: [
              PocketTile(
                key: const ValueKey('remote-changes-diff-header'),
                leading: const Icon(Icons.difference_outlined),
                title: Text(
                  file.display,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: WorkspaceChangeCounts(
                  added: file.added,
                  deleted: file.deleted,
                  binary: file.binary,
                  oversized: file.oversized,
                ),
                trailing: const Icon(Icons.unfold_more_rounded),
                onTap: _backToFiles,
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(
                '读取差异失败：$error',
                key: const ValueKey('remote-changes-diff-error'),
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      retry: () => unawaited(_select(index)),
    );
  }
}

/// 加载、降级与读取失败共用的居中提示：图标、标题、说明与可选动作。
///
/// 与远程首页、已归档任务页的提示保持同一套排版；文字按当前字号缩放换行，
/// 放大字体时仍能完整读到。
class _ChangesNotice extends StatelessWidget {
  const _ChangesNotice({
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
