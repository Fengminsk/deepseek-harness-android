import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

/// Original DSH document readers, scoped to one Session, under native chrome.
/// The service remains shared with chat; leaving this route only closes reads.
class SessionDocumentPage extends StatefulWidget {
  const SessionDocumentPage({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.path,
    this.line,
  });
  final RuntimeController runtime;
  final String sessionId, path;
  final int? line;

  @override
  State<SessionDocumentPage> createState() => _SessionDocumentPageState();
}

class _SessionDocumentPageState extends State<SessionDocumentPage> {
  int retry = 0;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.runtime,
    builder: (context, _) {
      final safe = MediaQuery.paddingOf(context);
      final theme = Theme.of(context);
      final header = (MediaQuery.textScalerOf(context).scale(17) * 2.4).clamp(
        52.0,
        120.0,
      );
      String color(Color value) =>
          '#${(value.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
      return PocketScaffold(
        title: Text(widget.path.split(RegExp(r'[/\\]')).last),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '重新打开文档',
          onPressed: widget.runtime.ready
              ? () => setState(() => retry++)
              : null,
        ),
        body: !widget.runtime.ready
            ? const Center(child: Text('本地服务尚未连接，文档将在连接后重新打开。'))
            : defaultTargetPlatform != TargetPlatform.android
            ? const Center(child: Text('请在 Android 应用中打开文档。'))
            : AndroidView(
                key: ValueKey((
                  widget.sessionId,
                  widget.path,
                  widget.line,
                  widget.runtime.connectionGeneration,
                  theme.brightness,
                  safe.top,
                  safe.bottom,
                  header,
                  retry,
                )),
                viewType: 'dsh/document-preview',
                creationParamsCodec: const StandardMessageCodec(),
                creationParams: {
                  'sessionId': widget.sessionId,
                  'path': widget.path,
                  if (widget.line != null) 'line': widget.line,
                  'locale': Localizations.localeOf(context).toLanguageTag(),
                  'dark': theme.brightness == Brightness.dark,
                  'topInset': safe.top + header + 32,
                  'bottomInset': safe.bottom + 28,
                  'background': color(theme.scaffoldBackgroundColor),
                  'foreground': color(theme.colorScheme.onSurface),
                },
              ),
      );
    },
  );
}
