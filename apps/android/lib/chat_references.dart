import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'entry_motion.dart';
import 'runtime.dart';
import 'ui.dart';

/// UTF-16 offsets, like TextSelection and the original input-trigger grammar.
class ReferenceToken {
  const ReferenceToken(this.start, this.end, this.query, this.quoted);
  final int start, end;
  final String query;
  final bool quoted;
}

ReferenceToken? activeReferenceToken(TextEditingValue value) {
  final cursor = value.selection;
  if (!cursor.isValid ||
      !cursor.isCollapsed ||
      cursor.end > value.text.length ||
      (value.composing.isValid && !value.composing.isCollapsed)) {
    return null;
  }
  final lineStart = cursor.end == 0
      ? 0
      : value.text.lastIndexOf('\n', cursor.end - 1) + 1;
  final line = value.text.substring(lineStart, cursor.end);
  final quoted = RegExp(r'(?:^|\s)(@"([^"]*))$').firstMatch(line);
  final match = quoted ?? RegExp(r'(?:^|\s)(@([^\s]*))$').firstMatch(line);
  if (match == null) return null;
  final prefix = match.group(1)!;
  // Settled quoted paths and canonical session mentions are references, not
  // new queries. Native text keeps their exact wire spelling in the draft.
  if (quoted == null &&
      (prefix.contains('"') ||
          RegExp(r'^@\[[^\]\n]+\]\(dsh-session:[^)\s]+\)$').hasMatch(prefix))) {
    return null;
  }
  return ReferenceToken(
    cursor.end - prefix.length,
    cursor.end,
    match.group(2)!,
    quoted != null,
  );
}

String? fileReferenceMention(
  String path, {
  required bool directory,
  bool quoted = false,
  bool drill = false,
}) {
  final value = directory ? '$path/' : path;
  if (RegExp(r'[\x00-\x1f\x7f-\x9f"]').hasMatch(value)) return null;
  if (!quoted && !RegExp(r'\s').hasMatch(value)) return '@$value';
  // The original drill keeps a quote open. A settled plain-text selection
  // closes it, so the following typed words cannot become part of the path.
  return '@"$value${directory && drill ? '' : '"'}';
}

TextEditingValue replaceReferenceToken(
  TextEditingValue draft,
  ReferenceToken token,
  String mention, {
  bool drill = false,
}) {
  final replacement = drill ? mention : '$mention ';
  return TextEditingValue(
    text: draft.text.replaceRange(token.start, token.end, replacement),
    selection: TextSelection.collapsed(
      offset: token.start + replacement.length,
    ),
  );
}

class ReferenceCandidate {
  const ReferenceCandidate({
    required this.label,
    required this.kind,
    required this.mention,
    this.path,
    this.location,
    this.child = false,
  });
  final String label, kind, mention;
  final String? path, location;
  final bool child;
}

List<ReferenceCandidate> referenceCandidates(
  Json result, {
  required ReferenceToken token,
  required String sessionId,
  required List<Json> sessions,
}) {
  final candidates = <ReferenceCandidate>[];
  final files = result['files'];
  if (files is Json && files['ok'] == true) {
    if (files['value'] is! List) throw const FormatException('文件引用目录无效');
    for (final value in files['value'] as List) {
      if (value is! Json ||
          value['path'] is! String ||
          !['file', 'directory'].contains(value['kind'])) {
        throw const FormatException('文件引用目录无效');
      }
      final path = value['path'] as String;
      final directory = value['kind'] == 'directory';
      final mention = fileReferenceMention(
        path,
        directory: directory,
        quoted: token.quoted,
      );
      if (mention == null) continue;
      final slash = path.lastIndexOf('/');
      candidates.add(
        ReferenceCandidate(
          label: '${path.substring(slash + 1)}${directory ? '/' : ''}',
          kind: value['kind'] as String,
          mention: mention,
          path: path,
          location: slash < 0 ? null : path.substring(0, slash),
        ),
      );
    }
  }
  final matches = result['sessions'];
  final sessionRows = <ReferenceCandidate>[];
  if (matches is Json && matches['ok'] == true && !token.quoted) {
    if (matches['value'] is! List) throw const FormatException('会话引用目录无效');
    for (final value in matches['value'] as List) {
      if (value is! Json ||
          value['sessionId'] is! String ||
          value['label'] is! String ||
          value['mention'] is! String) {
        throw const FormatException('会话引用目录无效');
      }
      final summary = sessions
          .where((s) => (s['header'] as Json?)?['id'] == value['sessionId'])
          .firstOrNull;
      final header = summary?['header'] as Json?;
      final child =
          (summary?['origin'] ?? header?['origin']) == 'subagent' &&
          (summary?['parentId'] ?? header?['parentId']) == sessionId;
      sessionRows.add(
        ReferenceCandidate(
          label: (value['displayTitle'] ?? value['label']) as String,
          kind: 'session',
          mention: value['mention'] as String,
          child: child,
          location: value['sameWorkspace'] == true
              ? null
              : value['cwd'] as String?,
        ),
      );
    }
  }
  return [
    ...candidates,
    ...sessionRows.where((c) => c.child),
    ...sessionRows.where((c) => !c.child),
  ];
}

/// A composer owns its discovery and cancels it on edits, disconnect and close.
/// The original Gateway retains permission checks and candidate ordering.
class ReferenceDiscoveryController extends ChangeNotifier {
  ReferenceDiscoveryController(
    this.runtime,
    this.sessionId, {
    required this.prepare,
  }) {
    _connection = runtime.connectionGeneration;
    _phase = runtime.phase;
    runtime.addListener(_runtimeChanged);
  }
  final RuntimeController runtime;
  final String sessionId;
  final Future<void> Function() prepare;
  ReferenceToken? token;
  List<ReferenceCandidate> candidates = [];
  String? error;
  bool loading = false, drilled = false;
  bool _disposed = false;
  int _epoch = 0, _connection = 0, _preparedGeneration = -1;
  String _phase = '';
  Timer? _debounce;
  String? _request;
  (int, Future<void>)? _preparing;
  TextEditingValue? _draft;
  final _nonce =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';

  void update(TextEditingValue? draft, {bool drill = false}) {
    _draft = draft;
    final next = draft == null ? null : activeReferenceToken(draft);
    final same =
        next != null &&
        token != null &&
        next.query == token!.query &&
        next.quoted == token!.quoted;
    token = next;
    if (same) return;
    drilled = drill;
    _schedule();
  }

  void dismiss() => update(null);

  void _runtimeChanged() {
    if (_connection == runtime.connectionGeneration &&
        _phase == runtime.phase) {
      return;
    }
    _connection = runtime.connectionGeneration;
    _phase = runtime.phase;
    _preparedGeneration = -1;
    _schedule();
  }

  Future<void> _cancel() async {
    final id = _request;
    _request = null;
    if (id == null || !runtime.ready) return;
    try {
      await runtime.call('references.cancel', {'requestId': id});
    } catch (failure) {
      // Never publish cancelled candidates. The service also owns disconnect
      // cancellation and its bounded request timeout.
      debugPrint('Reference cancellation not confirmed: $failure');
    }
  }

  void _schedule({bool immediate = false}) {
    final epoch = ++_epoch;
    _debounce?.cancel();
    unawaited(_cancel());
    candidates = [];
    error = null;
    loading = token != null && runtime.ready;
    notifyListeners();
    if (!loading) return;
    _debounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 160),
      () => unawaited(_load(epoch)),
    );
  }

  void retry() => _schedule(immediate: true);

  Future<void> _load(int epoch) async {
    final connection = runtime.connectionGeneration;
    final current = token;
    bool valid() =>
        !_disposed &&
        epoch == _epoch &&
        runtime.ready &&
        connection == runtime.connectionGeneration;
    if (current == null || !valid()) return;
    try {
      if (_preparedGeneration != connection) {
        final prepared = _preparing?.$1 == connection
            ? _preparing!
            : _preparing = (connection, prepare());
        try {
          await prepared.$2;
        } finally {
          if (identical(_preparing, prepared)) _preparing = null;
        }
        if (!valid()) return;
        _preparedGeneration = connection;
      }
      final request = 'refs-$_nonce-$epoch';
      _request = request;
      final result = await runtime.call('references.list', {
        'sessionId': sessionId,
        'requestId': request,
        'query': current.query,
        'quoted': current.quoted,
      });
      if (_request == request) _request = null;
      if (!valid()) return;
      if (result is! Json) throw const FormatException('引用目录未返回结果');
      candidates = referenceCandidates(
        result,
        token: current,
        sessionId: sessionId,
        sessions: runtime.sessions,
      );
      final errors = <String>[];
      for (final entry in [('files', '文件'), ('sessions', '会话')]) {
        final value = result[entry.$1];
        if (value is Json && value['ok'] == false) {
          errors.add('${entry.$2}：${value['error']?['message'] ?? '读取失败'}');
        }
      }
      error = errors.isEmpty ? null : errors.join('\n');
    } catch (failure) {
      if (valid()) error = '$failure';
    } finally {
      if (valid()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  TextEditingValue? pick(ReferenceCandidate candidate, {bool drill = false}) {
    final draft = _draft, current = token;
    if (draft == null || current == null || !candidates.contains(candidate)) {
      return null;
    }
    final mention = drill && candidate.kind == 'directory'
        ? fileReferenceMention(
            candidate.path!,
            directory: true,
            quoted: current.quoted,
            drill: true,
          )!
        : candidate.mention;
    final next = replaceReferenceToken(draft, current, mention, drill: drill);
    if (drill) {
      update(next, drill: true);
    } else {
      dismiss();
    }
    return next;
  }

  TextEditingValue? goTo(String query) {
    final draft = _draft, current = token;
    if (draft == null || current == null) return null;
    final next = replaceReferenceToken(
      draft,
      current,
      '${current.quoted ? '@"' : '@'}$query',
      drill: true,
    );
    update(next, drill: true);
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _debounce?.cancel();
    runtime.removeListener(_runtimeChanged);
    unawaited(_cancel());
    super.dispose();
  }
}

/// A floating, scrollable chooser above the existing composer. Folder tap
/// inserts the folder; its separate chevron browses that folder in place.
class ComposerReferenceSuggestions extends StatefulWidget {
  const ComposerReferenceSuggestions({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.input,
    required this.focus,
    required this.prepare,
  });
  final RuntimeController runtime;
  final String sessionId;
  final TextEditingController input;
  final FocusNode focus;
  final Future<void> Function() prepare;
  @override
  State<ComposerReferenceSuggestions> createState() =>
      _ComposerReferenceSuggestionsState();
}

class _ComposerReferenceSuggestionsState
    extends State<ComposerReferenceSuggestions> {
  late final discovery = ReferenceDiscoveryController(
    widget.runtime,
    widget.sessionId,
    prepare: widget.prepare,
  );
  @override
  void initState() {
    super.initState();
    discovery.addListener(_rebuild);
    widget.input.addListener(_edit);
    widget.focus.addListener(_edit);
    _edit();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _edit() =>
      discovery.update(widget.focus.hasFocus ? widget.input.value : null);
  void _apply(TextEditingValue? value) {
    if (value == null) return;
    widget.input.value = value;
    widget.focus.requestFocus();
  }

  @override
  void dispose() {
    widget.input.removeListener(_edit);
    widget.focus.removeListener(_edit);
    discovery.removeListener(_rebuild);
    discovery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final token = discovery.token;
    if (token == null) return const SizedBox.shrink();
    final crumbs = discovery.drilled && token.query.contains('/')
        ? token.query
              .substring(0, token.query.lastIndexOf('/'))
              .split('/')
              .where((part) => part.isNotEmpty)
              .toList()
        : <String>[];
    final media = MediaQuery.of(context);
    final colors = Theme.of(context).colorScheme;
    final surface = colors.brightness == Brightness.dark
        ? colors.surfaceContainer
        : colors.surfaceBright;
    final headerHeight = max(52.0, media.textScaler.scale(16) * 1.3 + 8);
    // Scaffold removes consumed keyboard insets from its body's MediaQuery.
    // Keep this nested, shrink-wrapped popup within the actual visible screen.
    final view = View.of(context);
    final keyboard = max(
      media.viewInsets.bottom,
      view.viewInsets.bottom / view.devicePixelRatio,
    );
    final available = max(
      0.0,
      media.size.height - keyboard - media.padding.vertical,
    );
    final maxHeight = min(
      media.size.height * .3,
      available * .45,
    ).clamp(headerHeight + 52, 340.0);
    return PocketReveal(
      key: const Key('composer-reference-reveal'),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlassSurface(
          radius: 24,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: SizedBox(
              // Loading and query changes retain the open chooser's geometry.
              height: maxHeight,
              child: Stack(
                children: [
                  ListView(
                    key: const Key('composer-reference-list'),
                    primary: false,
                    // The header overlays this viewport; its initial breathing
                    // room scrolls away with the candidates and breadcrumbs.
                    padding: EdgeInsets.only(top: headerHeight + 8, bottom: 12),
                    children: [
                      if (crumbs.isNotEmpty)
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Row(
                            children: [
                              PocketButton.tonal(
                                onPressed: () => _apply(discovery.goTo('')),
                                child: const Text('工作区'),
                              ),
                              for (var i = 0; i < crumbs.length; i++)
                                PocketButton.tonal(
                                  onPressed: () => _apply(
                                    discovery.goTo(
                                      '${crumbs.take(i + 1).join('/')}/',
                                    ),
                                  ),
                                  child: Text(crumbs[i]),
                                ),
                            ],
                          ),
                        ),
                      if (!widget.runtime.ready || discovery.loading)
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            widget.runtime.ready ? '正在查找引用…' : '等待本地服务',
                          ),
                        ),
                      if (discovery.error != null)
                        PocketTile(
                          title: Text(
                            discovery.error!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.refresh_rounded),
                          onTap: discovery.retry,
                        ),
                      if (!discovery.loading &&
                          discovery.candidates.isEmpty &&
                          discovery.error == null &&
                          widget.runtime.ready)
                        const Padding(
                          padding: EdgeInsets.all(14),
                          child: Text('没有匹配的文件或会话'),
                        ),
                      for (final candidate in discovery.candidates)
                        PocketTile(
                          key: ValueKey(candidate.mention),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          leading: Icon(switch (candidate.kind) {
                            'directory' => Icons.folder_outlined,
                            'session' =>
                              candidate.child
                                  ? Icons.account_tree_outlined
                                  : Icons.chat_bubble_outline_rounded,
                            _ => Icons.description_outlined,
                          }),
                          title: Text(
                            candidate.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle:
                              candidate.location == null ||
                                  (discovery.drilled &&
                                      candidate.kind != 'session')
                              ? null
                              : Text(
                                  candidate.location!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: candidate.kind == 'directory'
                              ? GlassButton(
                                  icon: Icons.chevron_right_rounded,
                                  label: '浏览 ${candidate.label}',
                                  onPressed: () => _apply(
                                    discovery.pick(candidate, drill: true),
                                  ),
                                )
                              : null,
                          onTap: () => _apply(discovery.pick(candidate)),
                        ),
                    ],
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: FloatingHeader(
                      key: const Key('composer-reference-header'),
                      backgroundColor: surface,
                      overhang: 20,
                      child: SizedBox(
                        height: headerHeight,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '引用文件或会话',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium,
                                ),
                              ),
                              GlassButton(
                                icon: Icons.close_rounded,
                                label: '关闭引用选择',
                                onPressed: discovery.dismiss,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 12,
                    child: FloatingEdgeScrim(
                      backgroundColor: surface,
                      fadeStart: 0,
                      bottom: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
