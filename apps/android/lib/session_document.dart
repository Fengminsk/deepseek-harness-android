import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';
import 'external_file_action.dart';

/// Original DSH document readers, scoped to one Session, under native chrome.
/// The service remains shared with chat; leaving this route only closes reads.
class SessionDocumentPage extends StatefulWidget {
  const SessionDocumentPage({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.path,
    this.line,
    this.privateWorkspace = false,
  });
  final RuntimeController runtime;
  final String sessionId, path;
  final int? line;
  final bool privateWorkspace;

  @override
  State<SessionDocumentPage> createState() => _SessionDocumentPageState();
}

class _SessionDocumentPageState extends State<SessionDocumentPage> {
  final externalOpen = ExternalFileOpenController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    externalOpen.observeRoute(context);
  }

  int retry = 0;
  late int? _line = widget.line;
  MethodChannel? _navigation;
  bool _opening = false;
  bool _openingExternal = false;

  void _connect(int viewId, int generation) {
    if (!mounted || generation != widget.runtime.connectionGeneration) return;
    _navigation?.setMethodCallHandler(null);
    final channel = MethodChannel('dsh/document-preview/$viewId');
    _navigation = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'openDocument') throw MissingPluginException();
      if (!mounted ||
          _navigation != channel ||
          generation != widget.runtime.connectionGeneration ||
          !widget.runtime.ready ||
          ModalRoute.of(context)?.isCurrent != true ||
          _opening) {
        throw PlatformException(
          code: 'document/inactive',
          message: '阅读页已离开，请返回文档后重试。',
        );
      }
      final args = call.arguments;
      if (args is! Map ||
          args['sessionId'] != widget.sessionId ||
          args['path'] is! String ||
          (args['path'] as String).isEmpty ||
          (args['path'] as String).length > 8192 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(args['path'] as String) ||
          args['line'] != null &&
              (args['line'] is! int ||
                  args['line'] < 1 ||
                  args['line'] > 9007199254740991)) {
        throw PlatformException(
          code: 'document/invalid-target',
          message: '文档链接无法识别或属于另一个会话。',
        );
      }
      final path = args['path'] as String;
      final line = args['line'] as int?;
      if (path == widget.path) {
        // The existing renderer answers the next navigation revision in place.
        _line = line;
        return {'opened': true};
      }
      final route = PocketRoute<void>(
        builder: (_) => SessionDocumentPage(
          runtime: widget.runtime,
          sessionId: widget.sessionId,
          path: path,
          line: line,
          privateWorkspace: widget.privateWorkspace,
        ),
      );
      _opening = true;
      final navigator = Navigator.of(context);
      final returned = args['replace'] == true
          ? navigator.pushReplacement<void, void>(route)
          : navigator.push<void>(route);
      // Retain this reader and its original resource/scroll state until return.
      returned.whenComplete(() {
        _opening = false;
      });
      return {'opened': true};
    });
  }

  @override
  void dispose() {
    externalOpen.dispose();
    _navigation?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.runtime,
    builder: (context, _) {
      final generation = widget.runtime.connectionGeneration;
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.privateWorkspace) GlassButton(
              icon: Icons.open_in_new_rounded,
              label: '在其他应用中打开',
              onPressed: !widget.runtime.ready || _openingExternal
                  ? null
                  : () async {
                      setState(() => _openingExternal = true);
                      await externalOpen.open(
                        context,
                        sessionId: widget.sessionId,
                        path: widget.path,
                      );
                      if (mounted) setState(() => _openingExternal = false);
                    },
            ),
            GlassButton(
              icon: Icons.refresh_rounded,
              label: '重新打开文档',
              onPressed: widget.runtime.ready
                  ? () => setState(() => retry++)
                  : null,
            ),
          ],
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
                  widget.privateWorkspace,
                  generation,
                  theme.brightness,
                  safe.top,
                  safe.bottom,
                  header,
                  retry,
                )),
                viewType: 'dsh/document-preview',
                onPlatformViewCreated: (id) => _connect(id, generation),
                creationParamsCodec: const StandardMessageCodec(),
                creationParams: {
                  'sessionId': widget.sessionId,
                  'path': widget.path,
                  'privateWorkspace': widget.privateWorkspace,
                  if (_line != null) 'line': _line,
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
