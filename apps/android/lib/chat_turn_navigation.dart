import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'chat_messages.dart';
import 'chat_projection.dart';
import 'runtime.dart';
import 'ui.dart';

/// Native presentation of the original `turnOutline` projection. An absent
/// projection stays absent; the UI never infers a whole-log index from a page.
class SessionTurnMark {
  const SessionTurnMark({
    required this.turn,
    required this.seq,
    required this.prompt,
    required this.response,
  });
  final int turn, seq;
  final String prompt, response;

  static List<SessionTurnMark> parse(Object? value) {
    if (value is! List) return const [];
    final result = <SessionTurnMark>[];
    var previousTurn = -1, previousSeq = -1;
    for (final raw in value) {
      if (raw is! Json || raw['turn'] is! int || raw['seq'] is! int) {
        return const [];
      }
      final turn = raw['turn'] as int, seq = raw['seq'] as int;
      if (turn < 0 || seq < 0 || turn <= previousTurn || seq <= previousSeq) {
        return const [];
      }
      result.add(
        SessionTurnMark(
          turn: turn,
          seq: seq,
          prompt: raw['prompt'] is String ? raw['prompt'] as String : '',
          response: raw['response'] is String ? raw['response'] as String : '',
        ),
      );
      previousTurn = turn;
      previousSeq = seq;
    }
    return result;
  }

  /// Only durable turn/start rows from the loaded window are fallback marks.
  static List<SessionTurnMark> fromLoadedWindow(List<Json> events) {
    final result = <SessionTurnMark>[];
    var previousTurn = -1, previousSeq = -1;
    for (final event in events) {
      if (event['type'] != 'turn/start') continue;
      final data = event['data'];
      final turn = data is Json ? data['turn'] : null;
      final seq = event['seq'];
      if (turn is! int ||
          seq is! int ||
          turn <= previousTurn ||
          seq <= previousSeq ||
          turn < 0 ||
          seq < 0) {
        continue;
      }
      result.add(
        SessionTurnMark(turn: turn, seq: seq, prompt: '', response: ''),
      );
      previousTurn = turn;
      previousSeq = seq;
    }
    return result;
  }
}

class ChatTurnNavigatorPage extends StatefulWidget {
  const ChatTurnNavigatorPage({
    super.key,
    required this.runtime,
    required this.sessionId,
  });
  final RuntimeController runtime;
  final String sessionId;
  @override
  State<ChatTurnNavigatorPage> createState() => _ChatTurnNavigatorPageState();
}

class _ChatTurnNavigatorPageState extends State<ChatTurnNavigatorPage> {
  List<SessionTurnMark> turns = const [];
  int? throughSeq;
  bool loading = true;
  String? error;
  int epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++epoch;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.runtime.call('session.turnOutline', {
        'sessionId': widget.sessionId,
      }) as Json;
      if (!mounted || generation != epoch) return;
      setState(() {
        final outline = SessionTurnMark.parse(result['turns']);
        turns = outline.isNotEmpty
            ? outline
            : SessionTurnMark.fromLoadedWindow(
                widget.runtime.timelines[widget.sessionId] ?? const [],
              );
        throughSeq =
            result['asOfSeq'] as int? ??
            widget.runtime.historyWindows[widget.sessionId]?.throughSeq;
        loading = false;
      });
    } catch (_) {
      if (!mounted || generation != epoch) return;
      setState(() {
        loading = false;
        error = '暂时无法读取会话轮次，请重试。';
      });
    }
  }

  @override
  void dispose() {
    epoch++;
    super.dispose();
  }

  void _open(int index) {
    final cursor = throughSeq;
    if (cursor == null || cursor < 0) return;
    Navigator.of(context).push<void>(
      PocketRoute(
        builder: (_) => ChatTurnDetailPage(
          runtime: widget.runtime,
          sessionId: widget.sessionId,
          mark: turns[index],
          nextSeq: index + 1 < turns.length ? turns[index + 1].seq : null,
          throughSeq: cursor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('会话轮次'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新轮次',
      onPressed: loading ? null : _load,
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(
            child: PocketButton.tonal(onPressed: _load, child: Text(error!)),
          )
        : turns.isEmpty
        ? const Center(child: Text('此会话暂无可用的轮次索引'))
        : PocketList.builder(
            itemCount: turns.length,
            itemBuilder: (context, index) {
              final mark = turns[index];
              return PocketTile(
                key: ValueKey('turn-${mark.turn}'),
                title: Text(
                  mark.prompt.isEmpty ? '第 ${mark.turn} 轮' : mark.prompt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: mark.response.isEmpty
                    ? Text('第 ${mark.turn} 轮')
                    : Text(
                        mark.response,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _open(index),
              );
            },
          ),
  );
}

/// A selected Turn is read at its own original log cursor. Very long Turns
/// reveal additional bounded pages on demand, without loading intervening Turns.
class ChatTurnDetailPage extends StatefulWidget {
  const ChatTurnDetailPage({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.mark,
    required this.nextSeq,
    required this.throughSeq,
  });
  final RuntimeController runtime;
  final String sessionId;
  final SessionTurnMark mark;
  final int? nextSeq;
  final int throughSeq;
  @override
  State<ChatTurnDetailPage> createState() => _ChatTurnDetailPageState();
}

class _ChatTurnDetailPageState extends State<ChatTurnDetailPage> {
  final controller = ScrollController();
  final projection = ChatProjection();
  final events = <Json>[];
  bool loading = true, loadingEarlier = false, hasEarlier = false;
  String? error;
  int epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool earlier = false}) async {
    final generation = ++epoch;
    setState(() {
      if (earlier) {
        loadingEarlier = true;
      } else {
        loading = true;
      }
      error = null;
    });
    try {
      final before = earlier
          ? events.first['seq'] as int
          : (widget.nextSeq ?? widget.throughSeq + 1);
      final page = await widget.runtime.call('session.readWindow', {
        'sessionId': widget.sessionId,
        'throughSeq': widget.throughSeq,
        'beforeSeq': before,
      }) as Json;
      if (!mounted || generation != epoch) return;
      final records = (page['events'] as List).cast<Json>();
      final selected = records
          .where(
            (event) =>
                (event['seq'] as int) >= widget.mark.seq &&
                (widget.nextSeq == null ||
                    (event['seq'] as int) < widget.nextSeq!),
          )
          .toList();
      final first = page['firstSeq'] as int?;
      setState(() {
        if (earlier) {
          events.insertAll(0, selected);
        } else {
          events
            ..clear()
            ..addAll(selected);
        }
        projection.reconcile(events);
        hasEarlier =
            page['hasMore'] == true && first != null && first > widget.mark.seq;
        loading = false;
        loadingEarlier = false;
      });
    } catch (_) {
      if (!mounted || generation != epoch) return;
      setState(() {
        loading = false;
        loadingEarlier = false;
        error = '这一轮的内容暂时无法读取。';
      });
    }
  }

  @override
  void dispose() {
    epoch++;
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text('第 ${widget.mark.turn} 轮'),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null && events.isEmpty
        ? Center(
            child: PocketButton.tonal(
              onPressed: () => _load(),
              child: Text(error!),
            ),
          )
        : ChatTimeline(
            sessionId: widget.sessionId,
            projection: projection,
            controller: controller,
            events: events,
            runtime: widget.runtime,
            showTurnNavigation: false,
            historyHeader: hasEarlier || loadingEarlier || error != null
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: loadingEarlier
                          ? null
                          : () => _load(earlier: true),
                      child: Text(
                        error ?? (loadingEarlier ? '正在读取…' : '查看本轮更早内容'),
                      ),
                    ),
                  )
                : null,
          ),
  );
}
