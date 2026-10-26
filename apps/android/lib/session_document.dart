import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';
import 'external_file_action.dart';
import 'settings_general.dart';

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
  late DeveloperToolsPreference _developerTools;
  bool _interactiveHtml = false;

  @override
  void initState() {
    super.initState();
    _observeDeveloperTools();
  }

  void _observeDeveloperTools() {
    _developerTools = DeveloperToolsPreference(widget.runtime)
      ..addListener(_updateInteractiveHtml);
    unawaited(_developerTools.start());
  }

  void _updateInteractiveHtml() {
    final next = _developerTools.confirmed && _developerTools.enabled;
    if (!mounted || next == _interactiveHtml) return;
    _interactiveHtml = next;
    final channel = _navigation;
    if (channel != null) unawaited(_publishInteractiveHtml(channel, next));
  }

  Future<void> _publishInteractiveHtml(
    MethodChannel channel,
    bool enabled,
  ) async {
    try {
      await channel.invokeMethod<bool>('setInteractiveHtml', enabled);
    } on PlatformException catch (_) {
      // The native reader may already have been disposed by navigation.
    } on MissingPluginException catch (_) {
      // A previous native build cannot change this preview in place.
    }
  }

  @override
  void didUpdateWidget(SessionDocumentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime) return;
    _navigation?.setMethodCallHandler(null);
    _navigation = null;
    _developerTools.removeListener(_updateInteractiveHtml);
    _developerTools.dispose();
    _interactiveHtml = false;
    _observeDeveloperTools();
  }

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
  bool _reloading = false;

  Future<void> _refreshDocument() async {
    if (_reloading) return;
    _reloading = true;
    final channel = _navigation;
    final generation = widget.runtime.connectionGeneration;
    try {
      if (channel != null &&
          await channel.invokeMethod<bool>('refresh') == true) {
        return;
      }
    } on PlatformException catch (_) {
      // The original reader has not mounted yet; reopening is the recovery.
    } on MissingPluginException catch (_) {
      // Older native builds do not have the in-place refresh command.
    } finally {
      _reloading = false;
    }
    if (mounted &&
        _navigation == channel &&
        widget.runtime.connectionGeneration == generation &&
        ModalRoute.of(context)?.isCurrent == true) {
      setState(() => retry++);
    }
  }

  void _connect(int viewId, int generation) {
    if (!mounted || generation != widget.runtime.connectionGeneration) return;
    _navigation?.setMethodCallHandler(null);
    final channel = MethodChannel('dsh/document-preview/$viewId');
    _navigation = channel;
    unawaited(_publishInteractiveHtml(channel, _interactiveHtml));
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
    _developerTools.removeListener(_updateInteractiveHtml);
    _developerTools.dispose();
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
            if (!widget.privateWorkspace)
              GlassButton(
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
              label: '重新读取文件',
              onPressed: widget.runtime.ready ? _refreshDocument : null,
            ),
          ],
        ),
        body: !widget.runtime.ready
            ? const Center(child: Text('本地服务尚未连接，文档将在连接后重新打开。'))
            : defaultTargetPlatform != TargetPlatform.android
            ? const Center(child: Text('请在 Android 应用中打开文档。'))
            : AndroidView(
                key: ValueKey((
                  widget.runtime,
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
                  // The WebView starts fail-closed. The accepted Host setting is
                  // sent through its fixed method channel without replacing it.
                  'interactiveHtml': false,
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
