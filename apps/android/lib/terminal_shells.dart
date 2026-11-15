import 'runtime.dart';
import 'terminal_runtime.dart';

/// Android's user terminal launches only a fixed system-shell identity.
enum TerminalShell {
  systemSh('system-sh', '系统 Shell'),
  systemMksh('system-mksh', 'mksh'),
  systemBash('system-bash', 'Bash');

  const TerminalShell(this.id, this.label);
  final String id, label;

  static TerminalShell? fromId(Object? value) {
    for (final shell in values) {
      if (shell.id == value) return shell;
    }
    return null;
  }

  /// 本枚举对应的 Shell 选项（页面只认宿主无关的 [TerminalShellOption]）。
  TerminalShellOption get option => TerminalShellOption(id: id, label: label);
}

/// Separates installed-shell discovery from the App-private remembered choice.
/// Both are rechecked when a terminal is created; neither carries a path.
///
/// 本类是 Android 本地的 [TerminalShellSource]：发现走宿主的 `terminal.shells`，
/// 偏好存在 App 私有的 MethodChannel 里，选项仍由 [TerminalShell] 枚举校验。
class TerminalShellCatalog implements TerminalShellSource {
  const TerminalShellCatalog(this.runtime);
  final TerminalCallSurface runtime;

  @override
  Future<List<TerminalShellOption>> discover() async {
    final reply = await runtime
        .call('terminal.shells')
        .timeout(const Duration(seconds: 8));
    if (reply is! List || reply.length > TerminalShell.values.length) {
      throw const FormatException('Invalid terminal shell list');
    }
    final shells = <TerminalShellOption>[];
    for (final row in reply) {
      if (row is! Map) throw const FormatException('Invalid terminal shell');
      final shell = TerminalShell.fromId(row['id']);
      if (shell == null ||
          row['label'] != shell.label ||
          shells.contains(shell.option)) {
        throw const FormatException('Invalid terminal shell');
      }
      shells.add(shell.option);
    }
    return List.unmodifiable(shells);
  }

  @override
  Future<TerminalShellOption?> preferred() async {
    final id = await RuntimeController.channel.invokeMethod<String>(
      'terminal.shell.load',
    );
    return (TerminalShell.fromId(id) ?? TerminalShell.systemSh).option;
  }

  @override
  Future<void> remember(TerminalShellOption shell) => RuntimeController.channel
      .invokeMethod<void>('terminal.shell.save', shell.id);
}
