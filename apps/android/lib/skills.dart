import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'session_document.dart';
import 'ui.dart';
import 'flclash/popup.dart';

class SessionSkill {
  const SessionSkill({
    required this.name,
    required this.description,
    required this.modelInvocable,
    this.path,
    this.whenToUse,
  });
  final String name, description;
  final bool modelInvocable;
  final String? path, whenToUse;

  factory SessionSkill.fromJson(Json value) {
    final name = value['name'];
    if (name is! String ||
        name.isEmpty ||
        !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(name) ||
        value['description'] is! String ||
        value['modelInvocable'] is! bool ||
        (value['path'] != null && value['path'] is! String) ||
        (value['whenToUse'] != null && value['whenToUse'] is! String)) {
      throw const FormatException('无效的技能目录');
    }
    return SessionSkill(
      name: name,
      description: value['description'] as String,
      modelInvocable: value['modelInvocable'] as bool,
      path: value['path'] as String?,
      whenToUse: value['whenToUse'] as String?,
    );
  }
}

// Same ordered-subsequence scoring as ui-primitives/rank-by-name.ts.
int? _alignment(String name, String query) {
  if (query.length > name.length) return null;
  int boundary(int i) =>
      i == 0 || name[i - 1] == '-' || name[i - 1] == '_' ? 8 : 0;
  var previous = List<int?>.generate(
    name.length,
    (i) => name[i] == query[0] ? 1 + boundary(i) - i : null,
  );
  for (var q = 1; q < query.length; q++) {
    final current = List<int?>.filled(name.length, null);
    int? left, leftLeft, bestGapped;
    for (var i = 0; i < name.length; i++) {
      if (leftLeft != null) {
        final score = leftLeft + i - 2;
        if (bestGapped == null || score > bestGapped) bestGapped = score;
      }
      if (name[i] == query[q]) {
        final bonus = 1 + boundary(i);
        if (left != null) current[i] = left + bonus + 4;
        if (bestGapped != null) {
          final score = bestGapped + bonus + 1 - i;
          if (current[i] == null || score > current[i]!) current[i] = score;
        }
      }
      leftLeft = left;
      left = previous[i];
    }
    previous = current;
  }
  int? best;
  for (final score in previous) {
    if (score != null && (best == null || score > best)) best = score;
  }
  return best;
}

List<SessionSkill> rankSessionSkills(List<SessionSkill> skills, String query) {
  query = query.toLowerCase();
  if (query.isEmpty) return skills;
  final ranked = <({SessionSkill skill, int index, bool prefix, int score})>[];
  for (var i = 0; i < skills.length; i++) {
    final name = skills[i].name.toLowerCase();
    final score = _alignment(name, query);
    if (score != null) {
      ranked.add((
        skill: skills[i],
        index: i,
        prefix: name.startsWith(query),
        score: score,
      ));
    }
  }
  ranked.sort((a, b) {
    if (a.prefix != b.prefix) return a.prefix ? -1 : 1;
    final score = b.score.compareTo(a.score);
    return score == 0 ? a.index.compareTo(b.index) : score;
  });
  return ranked.map((entry) => entry.skill).toList();
}

/// A menu pick is ordinary prompt text; the core owns skill loading and command
/// precedence. Replacing a leading slash token preserves the user's arguments.
TextEditingValue insertSessionSkill(TextEditingValue draft, String name) {
  final leading = RegExp(r'^\s*/[\w-]*(?=\s|$)').firstMatch(draft.text);
  final suffix = leading == null
      ? draft.text
      : draft.text.substring(leading.end).trimLeft();
  final prefix = '/$name ';
  return TextEditingValue(
    text: '$prefix$suffix',
    selection: TextSelection.collapsed(offset: prefix.length),
  );
}

/// One catalog per Session, owned by Chat. Filtering never reissues RPCs.
/// Existing history stays cold; only a caller-owned new draft may be created.
class SessionSkillsController extends ChangeNotifier {
  SessionSkillsController(this.runtime, this.sessionId, {this.prepareDraft});
  final RuntimeController runtime;
  final String sessionId;
  final Future<void> Function()? prepareDraft;
  List<SessionSkill> skills = [];
  String? error;
  bool loading = false, current = false;
  bool _disposed = false, _started = false;
  int _epoch = 0, _connection = -1;
  String _phase = '';
  StreamSubscription<Json>? _events;

  void start() {
    if (_started) return;
    _started = true;
    _connection = runtime.connectionGeneration;
    _phase = runtime.phase;
    runtime.addListener(_runtimeChanged);
    _events = runtime.remoteEvents.listen((event) {
      final args = event['args'] as List? ?? const [];
      if (event['event'] == 'plugin-manager/changed' ||
          (event['event'] == 'agent-preset/selected' &&
              args.firstOrNull == sessionId)) {
        unawaited(load());
      }
    });
    unawaited(load());
  }

  void _runtimeChanged() {
    if (_connection == runtime.connectionGeneration &&
        _phase == runtime.phase) {
      return;
    }
    _connection = runtime.connectionGeneration;
    _phase = runtime.phase;
    unawaited(load());
  }

  Future<void> load() async {
    if (_disposed) return;
    final epoch = ++_epoch;
    final connection = runtime.connectionGeneration;
    bool valid() =>
        !_disposed &&
        epoch == _epoch &&
        connection == runtime.connectionGeneration &&
        runtime.ready;
    current = false;
    skills = [];
    error = null;
    loading = runtime.ready;
    notifyListeners();
    if (!runtime.ready) return;
    Future<dynamic> read() => runtime
        .call('api.call', {
          'namespace': 'skills',
          'method': 'list',
          'args': {
            'request': {'sessionId': sessionId},
          },
        })
        .timeout(const Duration(seconds: 30));
    try {
      dynamic result;
      try {
        result = await read();
      } on PlatformException catch (failure) {
        if (failure.code != 'session/not-found' ||
            prepareDraft == null ||
            !valid()) {
          rethrow;
        }
        await prepareDraft!();
        if (!valid()) return;
        result = await read();
      }
      final parsed = (result['skills'] as List)
          .map(
            (value) =>
                SessionSkill.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList();
      if (parsed.map((skill) => skill.name).toSet().length != parsed.length) {
        throw const FormatException('技能名称重复');
      }
      if (!valid()) return;
      skills = parsed;
      current = true;
    } catch (failure) {
      if (!valid()) return;
      error =
          failure is PlatformException && failure.code == 'session/not-found'
          ? '当前会话已不可访问。请返回并重新打开会话。'
          : '暂时无法读取技能，请重试。';
    } finally {
      if (valid()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    runtime.removeListener(_runtimeChanged);
    unawaited(_events?.cancel());
    super.dispose();
  }
}

class SessionSkillsPage extends StatefulWidget {
  const SessionSkillsPage({
    super.key,
    required this.controller,
    this.initialQuery = '',
  });
  final SessionSkillsController controller;
  final String initialQuery;
  @override
  State<SessionSkillsPage> createState() => _SessionSkillsPageState();
}

class _SessionSkillsPageState extends State<SessionSkillsPage> {
  SessionSkillsController get controller => widget.controller;
  late final search = TextEditingController(text: widget.initialQuery);
  @override
  void initState() {
    super.initState();
    controller.addListener(changed);
    controller.start();
    search.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(changed);
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = rankSessionSkills(controller.skills, search.text);
    return PocketScaffold(
      title: const Text('技能'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新技能',
        onPressed: controller.loading || !controller.runtime.ready
            ? null
            : controller.load,
      ),
      body: PocketList(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: TextField(
              key: const Key('skill-search'),
              controller: search,
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              decoration: const InputDecoration(
                hintText: '搜索技能',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          if (!controller.runtime.ready ||
              controller.loading ||
              controller.error != null)
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.auto_stories_outlined,
                  title: !controller.runtime.ready
                      ? '等待本地服务'
                      : controller.loading
                      ? '正在读取技能…'
                      : controller.error!,
                  onTap: controller.error == null ? null : controller.load,
                ),
              ],
            ),
          if (controller.current && matches.isEmpty)
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.auto_stories_outlined,
                  title: controller.skills.isEmpty ? '此会话暂无可用技能' : '没有匹配的技能',
                ),
              ],
            ),
          if (matches.isNotEmpty)
            PocketSection(
              children: [
                for (final skill in matches)
                  PocketRow(
                    key: ValueKey('skill-${skill.name}'),
                    icon: Icons.auto_stories_outlined,
                    title: '/${skill.name}',
                    subtitle: [
                      if (!skill.modelInvocable) '仅由你主动调用',
                      skill.description,
                      if (skill.whenToUse?.isNotEmpty == true) skill.whenToUse!,
                    ].where((line) => line.isNotEmpty).join('\n'),
                    onTap: () => Navigator.of(context).pop(skill),
                    trailing: skill.path == null
                        ? null
                        : GlassButton(
                            icon: Icons.description_outlined,
                            label: '阅读 ${skill.name} 的说明',
                            onPressed: () => Navigator.of(context).push<void>(
                              PocketRoute<void>(
                                builder: (_) => SessionDocumentPage(
                                  runtime: controller.runtime,
                                  sessionId: controller.sessionId,
                                  path: skill.path!,
                                ),
                              ),
                            ),
                          ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Inline discovery retains plain-text semantics. It does not claim a slash
/// command; the existing command dispatcher still decides on submission.
class ComposerSkillSuggestions extends StatelessWidget {
  const ComposerSkillSuggestions({
    super.key,
    required this.controller,
    required this.query,
    required this.onPick,
    required this.onMore,
  });
  final SessionSkillsController controller;
  final String query;
  final ValueChanged<SessionSkill> onPick;
  final VoidCallback onMore;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final matches = rankSessionSkills(controller.skills, query);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .26,
          ),
          child: CommonPopupMenu(
            items: [
              if (controller.loading ||
                  controller.error != null ||
                  !controller.runtime.ready)
                CommonPopupMenuItem(
                  label: controller.loading
                      ? '正在读取技能…'
                      : controller.error ?? '等待本地服务',
                  dismissOnSelect: false,
                  onPressed: controller.error == null ? null : controller.load,
                ),
              for (final skill in matches.take(4))
                CommonPopupMenuItem(
                  label: '/${skill.name}',
                  section: '技能',
                  description:
                      '${skill.modelInvocable ? '' : '仅由你主动调用 · '}${skill.description}',
                  glyph: Icons.auto_stories_outlined,
                  dismissOnSelect: false,
                  onPressed: () => onPick(skill),
                ),
              CommonPopupMenuItem(
                label: '浏览技能',
                glyph: Icons.search_rounded,
                dismissOnSelect: false,
                onPressed: onMore,
              ),
            ],
          ),
        ),
      );
    },
  );
}
