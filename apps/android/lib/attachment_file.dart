import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'attachment_file_data.dart';
import 'runtime.dart';
import 'ui.dart';

Future<void> showPocketSessionFile(
  BuildContext context,
  RuntimeController runtime,
  String sessionId,
  Json attachment,
) async {
  final reference = AttachmentFileReference.fromMessage(sessionId, attachment);
  await Navigator.of(context).push(
    PocketRoute<void>(
      builder: (_) =>
          AttachmentFilePage(runtime: runtime, reference: reference),
    ),
  );
}

/// Views a verified copy of a file attached to this conversation. No local path
/// or model-authored link can be opened through this page.
class AttachmentFilePage extends StatefulWidget {
  const AttachmentFilePage({
    super.key,
    required this.runtime,
    required this.reference,
  });
  final RuntimeController runtime;
  final AttachmentFileReference reference;

  @override
  State<AttachmentFilePage> createState() => _AttachmentFilePageState();
}

class _AttachmentFilePageState extends State<AttachmentFilePage> {
  late final state = AttachmentFileController(widget.runtime, widget.reference);
  final scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(state.prepare());
  }

  @override
  void dispose() {
    state.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _move(Future<void> Function() move) async {
    final previous = state.page;
    await move();
    if (mounted && !identical(previous, state.page) && scroll.hasClients) {
      scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => PocketScaffold(
      title: Text(widget.reference.name),
      trailing: GlassButton(
        key: const ValueKey('attachment-file-save'),
        icon: Icons.save_alt_rounded,
        label: '保存附件',
        solid: true,
        onPressed: state.canSave ? state.save : null,
      ),
      bottom: state.page == null
          ? null
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PocketButton.tonal(
                  key: const ValueKey('attachment-file-previous'),
                  glass: true,
                  onPressed: state.canPrevious
                      ? () => _move(state.previous)
                      : null,
                  child: const Text('上一段'),
                ),
                const SizedBox(width: 12),
                PocketButton(
                  key: const ValueKey('attachment-file-next'),
                  glass: true,
                  onPressed: state.canNext ? () => _move(state.next) : null,
                  child: const Text('下一段'),
                ),
              ],
            ),
      body: PocketList(
        controller: scroll,
        children: [
          if (state.preparing || state.saving || state.cleaning)
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.hourglass_top_rounded,
                  title: state.saving
                      ? '正在保存附件'
                      : state.cleaning
                      ? '正在结束读取'
                      : '正在读取附件',
                  subtitle: state.saving
                      ? '请在系统选择器中选择保存位置。'
                      : state.cleaning
                      ? '正在释放本次临时副本。'
                      : '校验完整文件后即可查看或保存。',
                ),
                if (state.hasRequest)
                  PocketRow(
                    icon: Icons.close_rounded,
                    title: state.saving ? '取消保存' : '取消读取',
                    onTap: state.cleaning ? null : state.cancel,
                  ),
              ],
            ),
          if (state.message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
              child: Text(state.message!),
            ),
          if (state.error != null)
            PocketSection(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(state.error!),
                ),
                PocketRow(
                  icon: Icons.refresh_rounded,
                  title: switch (state.failureKind) {
                    AttachmentFileFailure.save => '重新选择保存位置',
                    AttachmentFileFailure.read => '重试读取',
                    _ => '重新读取附件',
                  },
                  onTap: switch (state.failureKind) {
                    AttachmentFileFailure.save =>
                      state.canSave ? state.save : null,
                    AttachmentFileFailure.read =>
                      state.canRead ? state.retryRead : null,
                    _ => state.canPrepare ? state.prepare : null,
                  },
                ),
              ],
            ),
          if (state.cleanupError != null)
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.cleaning_services_outlined,
                  title: '清理临时副本',
                  subtitle: state.cleanupError,
                  onTap: state.cleaning || !widget.runtime.ready
                      ? null
                      : state.retryCleanup,
                ),
              ],
            ),
          if (!state.hasRequest && state.error == null && !state.preparing)
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.description_outlined,
                  title: '读取会话附件',
                  subtitle: widget.runtime.ready
                      ? '读取不会启动 Agent 或修改会话。'
                      : '等待本地服务恢复后，可重新读取。',
                  onTap: state.canPrepare ? state.prepare : null,
                ),
              ],
            ),
          if (state.file != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
              child: Text(
                '${_size(state.file!.size)} · '
                '${state.current ? '会话附件' : '上次读取，尚未核实'}',
              ),
            ),
            if (!state.file!.isText)
              const PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.insert_drive_file_outlined,
                    title: '此格式不支持文本预览',
                    subtitle: '可以使用右上角按钮保存完整附件。',
                  ),
                ],
              ),
          ],
          if (state.reading)
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 16),
              child: Text('正在读取这一段…'),
            ),
          if (state.page != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              child: Text(
                '第 ${state.pageIndex + 1} 段'
                '${state.page!.eof ? ' · 文件末尾' : ''}',
              ),
            ),
            PocketSection(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    state.page!.text.isEmpty ? '文件为空。' : state.page!.text,
                    key: const ValueKey('attachment-file-content'),
                    style: const TextStyle(fontSize: 15, height: 1.55),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

String _size(int value) {
  if (value < 1024) return '$value 字节';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
