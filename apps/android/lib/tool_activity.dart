import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'tool_activity_data.dart';
import 'tool_activity_details.dart';

export 'tool_activity_data.dart' show ToolActivity, ToolActivityProjection;

/// A compact transcript row. Its detail panel follows this original call only.
class ToolActivityCard extends StatefulWidget {
  const ToolActivityCard({
    required this.activity,
    this.activitySource,
    this.initiallyExpanded = false,
    super.key,
  });
  final ToolActivity activity;

  /// The timeline owns this source beyond lazy rows and collapsed groups.
  /// Publish null before disposing its owner to dismiss unavailable details.
  /// Without a source, this row supplies updates and closes details on removal.
  final ValueListenable<ToolActivity?>? activitySource;

  /// Opens details after the first layout; false leaves only the compact row.
  final bool initiallyExpanded;
  @override
  State<ToolActivityCard> createState() => _ToolActivityCardState();
}

class _ToolActivityCardState extends State<ToolActivityCard>
    with AutomaticKeepAliveClientMixin {
  ToolActivityDetailsController? _details;
  @override
  bool get wantKeepAlive => _details != null && widget.activitySource == null;

  @override
  void initState() {
    super.initState();
    if (widget.initiallyExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open();
      });
    }
  }

  @override
  void didUpdateWidget(ToolActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity.identity != widget.activity.identity ||
        oldWidget.activitySource != widget.activitySource) {
      _details?.close();
    } else if (widget.activitySource == null) {
      _details?.update(widget.activity);
    }
  }

  @override
  void dispose() {
    if (widget.activitySource == null) _details?.close();
    super.dispose();
  }

  Future<void> _open() async {
    if (_details != null) return;
    if (widget.activitySource != null && widget.activitySource!.value == null) {
      return;
    }
    final details = ToolActivityDetailsController.open(
      context,
      widget.activity,
      source: widget.activitySource,
    );
    setState(() => _details = details);
    updateKeepAlive();
    await details.closed;
    if (!mounted || !identical(_details, details)) return;
    setState(() => _details = null);
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ToolActivityRow(
      activity: widget.activity,
      onTap: _open,
      opened: _details != null,
    );
  }
}
