import 'package:material_ui/material_ui.dart';

import 'entry_motion.dart';
import 'runtime.dart';
import 'ui.dart';

enum ChatTodoStatus { pending, inProgress, completed }

class ChatTodoItem {
  const ChatTodoItem(this.content, this.status);
  final String content;
  final ChatTodoStatus status;

  String get label => switch (status) {
    ChatTodoStatus.pending => '待开始',
    ChatTodoStatus.inProgress => '进行中',
    ChatTodoStatus.completed => '已完成',
  };
}

sealed class ChatArtifact {
  const ChatArtifact(this.event);
  final Json event;
  int get seq => event['seq'] as int;
  String get key;
}

/// The recorded whole list, never inferred from a tool call or its receipt.
class ChatTodoSnapshot extends ChatArtifact {
  const ChatTodoSnapshot(super.event, this.items);

  /// Null means the durable payload was unreadable, not an empty list.
  final List<ChatTodoItem>? items;
  @override
  String get key => 'todo:$seq';
  int count(ChatTodoStatus status) =>
      items?.where((item) => item.status == status).length ?? 0;
  String get summary {
    if (items == null) return '这条待办记录无法显示';
    if (items!.isEmpty) return '待办已清空';
    return [
      for (final status in ChatTodoStatus.values)
        if (count(status) > 0)
          '${count(status)} 项${switch (status) {
            ChatTodoStatus.pending => '待开始',
            ChatTodoStatus.inProgress => '进行中',
            ChatTodoStatus.completed => '已完成',
          }}',
    ].join(' · ');
  }

  String? get activeContent {
    for (final item in items ?? const <ChatTodoItem>[]) {
      if (item.status == ChatTodoStatus.inProgress) return item.content;
    }
    return null;
  }
}

class ChatPresentedFile {
  const ChatPresentedFile({
    required this.path,
    required this.seq,
    required this.index,
    this.description,
  });
  final String path;
  final String? description;
  final int seq, index;

  String get name {
    final separator = path.lastIndexOf(RegExp(r'[/\\]'));
    return separator < 0 ? path : path.substring(separator + 1);
  }
}

/// Completed-turn deliveries retain the original event coordinates and paths.
class ChatPresentedTurn extends ChatArtifact {
  const ChatPresentedTurn(super.event, this.turn, this.files);
  final int turn;
  final List<ChatPresentedFile> files;
  @override
  String get key => 'deliverables:$turn';
}

class _DeliveryTurn {
  final files = <ChatPresentedFile>[];
  int? closingSeq;
  Json? end;
}

/// Folds original log-only events independently of the message surface. Like
/// tool-todo's standing projection, turn/start clears the current list while
/// turn/end keeps it. Several in_progress items are legitimate parallel work.
///
/// Deliveries mirror ui-deliverables' presentedForClosing: latest declaration
/// per exact path before the closing reply (or turn/end with no reply), in
/// first-seen path order. No tool arguments or final prose declare a file.
class ChatArtifactsProjection {
  final _seen = <Json>[];
  final _rows = <String, ChatArtifact>{};
  final _turns = <int, _DeliveryTurn>{};
  List<Json>? _source;
  List<ChatArtifact> _entries = const [];
  ChatTodoSnapshot? currentTodos;
  int revision = 0;
  int processedEventCount = 0;
  List<ChatArtifact> get entries => _entries;

  void reconcile(List<Json> events) {
    if (identical(_source, events) && _seen.length == events.length) return;
    var prefix = 0;
    if (identical(_source, events) &&
        events.length >= _seen.length &&
        (_seen.isEmpty || identical(events[_seen.length - 1], _seen.last))) {
      prefix = _seen.length;
    } else {
      while (prefix < _seen.length &&
          prefix < events.length &&
          identical(_seen[prefix], events[prefix])) {
        prefix++;
      }
    }
    _source = events;
    if (prefix != _seen.length) {
      _seen.clear();
      _rows.clear();
      _turns.clear();
      currentTodos = null;
      prefix = 0;
    }
    if (prefix == events.length && _entries.length == _rows.length) return;
    for (var at = prefix; at < events.length; at++) {
      _consume(events[at]);
      _seen.add(events[at]);
      processedEventCount++;
    }
    _entries = List.unmodifiable(
      _rows.values.toList()..sort((a, b) => a.seq.compareTo(b.seq)),
    );
    revision++;
  }

  void _consume(Json event) {
    final data = event['data'];
    if (data is! Json || event['seq'] is! int) return;
    switch (event['type']) {
      case 'turn/start':
        currentTodos = null;
      case 'todo/write':
        final snapshot = ChatTodoSnapshot(event, _todos(data['todos']));
        _rows[snapshot.key] = snapshot;
        currentTodos = snapshot;
      case 'deliverables/presented':
        final turn = data['turn'],
            callId = data['callId'],
            files = data['files'];
        if (turn is! int ||
            turn < 1 ||
            callId is! String ||
            callId.isEmpty ||
            files is! List) {
          return;
        }
        final state = _turns.putIfAbsent(turn, _DeliveryTurn.new);
        for (var index = 0; index < files.length; index++) {
          final file = files[index];
          if (file is! Json ||
              file['path'] is! String ||
              (file['path'] as String).trim().isEmpty ||
              (file.containsKey('description') &&
                  file['description'] is! String)) {
            continue;
          }
          state.files.add(
            ChatPresentedFile(
              path: file['path'] as String,
              description: file['description'] as String?,
              seq: event['seq'] as int,
              index: index,
            ),
          );
        }
        _publish(turn, state);
      case 'assistant/message':
      case 'assistant/attempt':
        if (event['type'] == 'assistant/message' &&
            event['surfaceOp'] != 'append') {
          return;
        }
        final turn = data['turn'], message = data['message'];
        // The native carrier decodes persisted attempt records through the
        // original DSH stream assembler. It supplies no fabricated final text.
        final content = event['type'] == 'assistant/attempt'
            ? event['assistantContent']
            : message is Json
            ? message['content']
            : null;
        if (turn is! int || content is! List) return;
        final text = content.whereType<Json>().any(
          (block) =>
              block['type'] == 'text' &&
              block['text'] is String &&
              (block['text'] as String).trim().isNotEmpty,
        );
        if (!text) return;
        final state = _turns.putIfAbsent(turn, _DeliveryTurn.new);
        state.closingSeq = event['seq'] as int;
        _publish(turn, state);
      case 'turn/end':
        final turn = data['turn'];
        if (turn is! int) return;
        final state = _turns.putIfAbsent(turn, _DeliveryTurn.new);
        state.end = event;
        _publish(turn, state);
    }
  }

  void _publish(int turn, _DeliveryTurn state) {
    final end = state.end;
    if (end == null) return;
    final closingSeq = state.closingSeq ?? end['seq'] as int;
    final paths = <String, ChatPresentedFile>{};
    for (final file in state.files) {
      if (file.seq < closingSeq) paths[file.path] = file;
    }
    final key = 'deliverables:$turn';
    if (paths.isEmpty) {
      _rows.remove(key);
    } else {
      _rows[key] = ChatPresentedTurn(
        end,
        turn,
        List.unmodifiable(paths.values),
      );
    }
  }
}

List<ChatTodoItem>? _todos(dynamic value) {
  if (value is! List) return null;
  final items = <ChatTodoItem>[];
  final contents = <String>{};
  for (final raw in value) {
    if (raw is! Json || raw['content'] is! String) return null;
    final content = raw['content'] as String;
    final status = switch (raw['status']) {
      'pending' => ChatTodoStatus.pending,
      'in_progress' => ChatTodoStatus.inProgress,
      'completed' => ChatTodoStatus.completed,
      _ => null,
    };
    if (content.trim().isEmpty || status == null || !contents.add(content)) {
      return null;
    }
    items.add(ChatTodoItem(content, status));
  }
  return List.unmodifiable(items);
}

class ChatTodoRow extends StatelessWidget {
  const ChatTodoRow({required this.snapshot, super.key});
  final ChatTodoSnapshot snapshot;

  @override
  Widget build(BuildContext context) => PocketTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
    leading: const Icon(Icons.checklist_rounded, size: 22),
    title: const Text('待办更新'),
    subtitle: Text(snapshot.summary),
    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
    onTap: () => Navigator.of(
      context,
    ).push<void>(PocketRoute(builder: (_) => _TodoDetails(snapshot: snapshot))),
  );
}

class _TodoDetails extends StatelessWidget {
  const _TodoDetails({required this.snapshot});
  final ChatTodoSnapshot snapshot;
  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('待办记录'),
    body: PocketList(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Text(snapshot.summary),
        ),
        if (snapshot.items?.isNotEmpty == true)
          PocketSection(
            divided: true,
            children: [
              for (final item in snapshot.items!) _TodoItemRow(item: item),
            ],
          ),
      ],
    ),
  );
}

class _TodoItemRow extends StatelessWidget {
  const _TodoItemRow({required this.item});
  final ChatTodoItem item;
  @override
  Widget build(BuildContext context) => PocketTile(
    leading: Icon(
      switch (item.status) {
        ChatTodoStatus.pending => Icons.radio_button_unchecked_rounded,
        ChatTodoStatus.inProgress => Icons.timelapse_rounded,
        ChatTodoStatus.completed => Icons.check_circle_outline_rounded,
      },
      color: item.status == ChatTodoStatus.pending
          ? Theme.of(context).colorScheme.onSurfaceVariant
          : Theme.of(context).colorScheme.primary,
      size: 22,
    ),
    title: Text(item.content),
    subtitle: Text(item.label),
  );
}

/// Optional floating composer dock. Expanding reads the same current snapshot;
/// it never changes checklist state or starts another model request.
class ChatTodoDock extends StatefulWidget {
  const ChatTodoDock({
    required this.sessionId,
    required this.events,
    super.key,
  });
  final String sessionId;
  final List<Json> events;
  @override
  State<ChatTodoDock> createState() => _ChatTodoDockState();
}

class _ChatTodoDockState extends State<ChatTodoDock> {
  ChatArtifactsProjection _projection = ChatArtifactsProjection();
  bool _expanded = false;
  @override
  void didUpdateWidget(ChatTodoDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _projection = ChatArtifactsProjection();
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    _projection.reconcile(widget.events);
    final snapshot = _projection.currentTodos;
    if (snapshot == null || snapshot.items?.isEmpty == true) {
      _expanded = false;
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PocketReveal(
        child: GlassSurface(
          radius: 26,
          child: AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
            alignment: Alignment.topCenter,
            curve: Curves.easeOutCubic,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  expanded: _expanded,
                  child: PocketTile(
                    leading: const Icon(Icons.checklist_rounded, size: 22),
                    title: Text(snapshot.summary),
                    subtitle: !_expanded && snapshot.activeContent != null
                        ? Text(
                            snapshot.activeContent!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    trailing: AnimatedRotation(
                      turns: _expanded ? .5 : 0,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      child: const Icon(Icons.expand_less_rounded, size: 20),
                    ),
                    onTap: snapshot.items == null
                        ? null
                        : () => setState(() => _expanded = !_expanded),
                  ),
                ),
                if (_expanded)
                  PocketReveal(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * .32,
                      ),
                      child: ListView(
                        primary: false,
                        shrinkWrap: true,
                        children: [
                          for (final item in snapshot.items!)
                            _TodoItemRow(item: item),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the exact persisted path. The caller supplies the owning Session;
/// file bytes, permissions and native viewing remain in the shared file flow.
class ChatPresentedFiles extends StatefulWidget {
  const ChatPresentedFiles({
    required this.sessionId,
    required this.delivery,
    this.onOpen,
    super.key,
  });
  final String sessionId;
  final ChatPresentedTurn delivery;
  final Future<void> Function(ChatPresentedFile file)? onOpen;
  @override
  State<ChatPresentedFiles> createState() => _ChatPresentedFilesState();
}

class _ChatPresentedFilesState extends State<ChatPresentedFiles> {
  bool _expanded = false;
  final _opening = <(int, int)>{};
  final _failed = <(int, int)>{};
  int _generation = 0;

  @override
  void didUpdateWidget(ChatPresentedFiles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.delivery.key != widget.delivery.key) {
      _generation++;
      _opening.clear();
      _failed.clear();
      _expanded = false;
    }
  }

  Future<void> _open(ChatPresentedFile file) async {
    final callback = widget.onOpen;
    final key = (file.seq, file.index);
    if (callback == null || _opening.contains(key)) return;
    final generation = _generation;
    setState(() {
      _opening.add(key);
      _failed.remove(key);
    });
    try {
      await callback(file);
    } catch (error) {
      // The shared opener owns detailed diagnostics; preserve a retry here if
      // a caller rejects before it can present that file route.
      if (mounted && generation == _generation) {
        setState(() => _failed.add(key));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _opening.remove(key));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = widget.delivery.files;
    final shown = _expanded ? files : files.take(4);
    return PocketSection(
      title: '交付文件',
      divided: true,
      children: [
        for (final file in shown)
          PocketTile(
            key: ValueKey((file.seq, file.index)),
            leading: Icon(
              _fileIcon(file.path),
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(
              file.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                if (file.description?.trim().isNotEmpty == true)
                  file.description!,
                if (file.path != file.name) file.path,
                if (file.path == file.name &&
                    file.description?.trim().isNotEmpty != true)
                  '文件',
                if (_failed.contains((file.seq, file.index))) '文件未能打开，点按重试',
                if (widget.onOpen == null) '文件预览暂不可用',
                if (_opening.contains((file.seq, file.index))) '正在打开…',
              ].join('\n'),
            ),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap:
                widget.onOpen == null ||
                    _opening.contains((file.seq, file.index))
                ? null
                : () => _open(file),
          ),
        if (files.length > 4)
          PocketTile(
            title: Text(_expanded ? '收起文件' : '查看全部 ${files.length} 个文件'),
            trailing: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
      ],
    );
  }
}

IconData _fileIcon(String path) {
  final extension = path.split('.').last.toLowerCase();
  return switch (extension) {
    'pdf' => Icons.picture_as_pdf_outlined,
    'png' ||
    'jpg' ||
    'jpeg' ||
    'webp' ||
    'gif' ||
    'svg' => Icons.image_outlined,
    'xlsx' || 'xls' || 'csv' || 'ods' => Icons.table_chart_outlined,
    'pptx' || 'ppt' || 'odp' => Icons.slideshow_rounded,
    'docx' || 'doc' || 'odt' || 'md' || 'txt' => Icons.description_outlined,
    'zip' || 'tar' || 'gz' => Icons.folder_zip_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}
