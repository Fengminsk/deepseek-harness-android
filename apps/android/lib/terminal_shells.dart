import 'runtime.dart';

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
}

/// Separates installed-shell discovery from the App-private remembered choice.
/// Both are rechecked when a terminal is created; neither carries a path.
class TerminalShellCatalog {
  const TerminalShellCatalog(this.runtime);
  final RuntimeController runtime;

  Future<List<TerminalShell>> discover() async {
    final reply = await runtime
        .call('terminal.shells')
        .timeout(const Duration(seconds: 8));
    if (reply is! List || reply.length > TerminalShell.values.length) {
      throw const FormatException('Invalid terminal shell list');
    }
    final shells = <TerminalShell>[];
    for (final row in reply) {
      if (row is! Map) throw const FormatException('Invalid terminal shell');
      final shell = TerminalShell.fromId(row['id']);
      if (shell == null ||
          row['label'] != shell.label ||
          shells.contains(shell)) {
        throw const FormatException('Invalid terminal shell');
      }
      shells.add(shell);
    }
    return List.unmodifiable(shells);
  }

  Future<TerminalShell> preferred() async {
    final id = await RuntimeController.channel.invokeMethod<String>(
      'terminal.shell.load',
    );
    return TerminalShell.fromId(id) ?? TerminalShell.systemSh;
  }

  Future<void> remember(TerminalShell shell) => RuntimeController.channel
      .invokeMethod<void>('terminal.shell.save', shell.id);
}
