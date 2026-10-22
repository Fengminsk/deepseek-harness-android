import 'package:material_ui/material_ui.dart';

import 'ui.dart';
import 'workspace_changes.dart';

class WorkspaceChangedFileTile extends StatelessWidget {
  const WorkspaceChangedFileTile({
    required this.file,
    required this.onTap,
    this.selected = false,
    super.key,
  });
  final WorkspaceChangedFile file;
  final VoidCallback onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) => PocketTile(
    selected: selected,
    leading: Icon(
      file.binary ? Icons.insert_drive_file_outlined : Icons.code_rounded,
    ),
    title: Text(file.display, maxLines: 3, overflow: TextOverflow.ellipsis),
    subtitle: WorkspaceChangeCounts(
      added: file.added,
      deleted: file.deleted,
      binary: file.binary,
      oversized: file.oversized,
    ),
    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
    onTap: onTap,
  );
}

class WorkspaceChangeCounts extends StatelessWidget {
  const WorkspaceChangeCounts({
    required this.added,
    required this.deleted,
    this.binary = false,
    this.oversized = false,
    super.key,
  });
  final int added, deleted;
  final bool binary, oversized;
  @override
  Widget build(BuildContext context) {
    if (binary) return const Text('二进制文件');
    if (oversized) return const Text('文件过大');
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: '新增 $added 行，删除 $deleted 行',
      excludeSemantics: true,
      child: Wrap(
        spacing: 12,
        children: [
          Text(
            '+${_grouped(added)}',
            style: TextStyle(
              color: dark ? const Color(0xff8dddac) : const Color(0xff176b3b),
            ),
          ),
          Text(
            '−${_grouped(deleted)}',
            style: TextStyle(
              color: dark ? const Color(0xffffaaa7) : const Color(0xffb32b29),
            ),
          ),
        ],
      ),
    );
  }
}

String _grouped(int count) =>
    '$count'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
