import 'package:flutter/widgets.dart';

import 'runtime.dart';

/// Keeps independent runtime domains from rebuilding a whole page. Selection
/// must contain immutable values (or explicit lengths/revisions for live lists).
/// Local parent updates still rebuild, including draft and navigation changes.
class RuntimeSelectionBuilder<T> extends StatefulWidget {
  const RuntimeSelectionBuilder({
    super.key,
    required this.runtime,
    required this.select,
    required this.builder,
  });
  final RuntimeController runtime;
  final T Function() select;
  final Widget Function(BuildContext, T) builder;

  @override
  State<RuntimeSelectionBuilder<T>> createState() =>
      _RuntimeSelectionState<T>();
}

class _RuntimeSelectionState<T> extends State<RuntimeSelectionBuilder<T>> {
  late T selection;
  @override
  void initState() {
    super.initState();
    selection = widget.select();
    widget.runtime.addListener(changed);
  }

  void changed() {
    final next = widget.select();
    if (selection != next) setState(() => selection = next);
  }

  @override
  void didUpdateWidget(RuntimeSelectionBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(changed);
      widget.runtime.addListener(changed);
    }
    selection = widget.select();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, selection);

  @override
  void dispose() {
    widget.runtime.removeListener(changed);
    super.dispose();
  }
}
