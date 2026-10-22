import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'runtime.dart';
import 'workspace_changes_preference.dart';

// Wire validators mirror ui-deliverables/changes.ts. These are Host records,
// never a comparison reconstructed from the current workspace on the client.
bool _integer(dynamic value, {int? minimum}) =>
    value is int &&
    value.abs() <= 9007199254740991 &&
    (minimum == null || value >= minimum);
bool _path(dynamic value) => value is String && value.isNotEmpty;

class WorkspaceChangedFile {
  const WorkspaceChangedFile({
    required this.path,
    required this.display,
    required this.added,
    required this.deleted,
    this.binary = false,
    this.oversized = false,
  });
  final String path, display;
  final int added, deleted;
  final bool binary, oversized;
  String get name => display.split(RegExp(r'[/\\]')).last;

  static WorkspaceChangedFile? parse(dynamic value) {
    if (value is! Map ||
        !_path(value['path']) ||
        !_path(value['display']) ||
        !_integer(value['added']) ||
        !_integer(value['deleted']) ||
        (value.containsKey('binary') && value['binary'] != true) ||
        (value.containsKey('oversized') && value['oversized'] != true)) {
      return null;
    }
    return WorkspaceChangedFile(
      path: value['path'],
      display: value['display'],
      added: value['added'],
      deleted: value['deleted'],
      binary: value['binary'] == true,
      oversized: value['oversized'] == true,
    );
  }
}

class WorkspaceChangesSummary {
  const WorkspaceChangesSummary({
    required this.turn,
    required this.files,
    required this.total,
    required this.added,
    required this.deleted,
  });
  final int turn, total, added, deleted;
  final List<WorkspaceChangedFile> files;

  static WorkspaceChangesSummary? parse(dynamic value) {
    if (value is! Map ||
        !_integer(value['turn'], minimum: 1) ||
        !_integer(value['total']) ||
        !_integer(value['added']) ||
        !_integer(value['deleted']) ||
        value['files'] is! List) {
      return null;
    }
    final files = <WorkspaceChangedFile>[];
    for (final raw in value['files']) {
      final file = WorkspaceChangedFile.parse(raw);
      if (file == null) return null;
      files.add(file);
    }
    return WorkspaceChangesSummary(
      turn: value['turn'],
      files: List.unmodifiable(files),
      total: value['total'],
      added: value['added'],
      deleted: value['deleted'],
    );
  }
}

class WorkspaceDiffHunk {
  const WorkspaceDiffHunk({
    required this.oldStart,
    required this.oldLines,
    required this.newStart,
    required this.newLines,
    required this.lines,
  });
  final int oldStart, oldLines, newStart, newLines;
  final List<String> lines;
  String get header => '@@ -$oldStart,$oldLines +$newStart,$newLines @@';

  static WorkspaceDiffHunk? parse(dynamic value) {
    if (value is! Map ||
        ![
          'oldStart',
          'oldLines',
          'newStart',
          'newLines',
        ].every((key) => _integer(value[key], minimum: 0)) ||
        value['lines'] is! List ||
        !(value['lines'] as List).every(
          (line) => line is String && RegExp(r'^[+ -]').hasMatch(line),
        )) {
      return null;
    }
    return WorkspaceDiffHunk(
      oldStart: value['oldStart'],
      oldLines: value['oldLines'],
      newStart: value['newStart'],
      newLines: value['newLines'],
      lines: List<String>.unmodifiable(value['lines']),
    );
  }
}

enum WorkspaceDiffKind { text, binary, oversized }

class WorkspaceFileDiff {
  const WorkspaceFileDiff({
    required this.kind,
    required this.path,
    required this.display,
    this.before = true,
    this.after = true,
    this.coarse = false,
    this.hunks = const [],
  });
  final WorkspaceDiffKind kind;
  final String path, display;
  final bool before, after, coarse;
  final List<WorkspaceDiffHunk> hunks;

  static WorkspaceFileDiff? parse(dynamic value) {
    if (value is! Map || !_path(value['path']) || !_path(value['display'])) {
      return null;
    }
    final kind = switch (value['kind']) {
      'text' => WorkspaceDiffKind.text,
      'binary' => WorkspaceDiffKind.binary,
      'oversized' => WorkspaceDiffKind.oversized,
      _ => null,
    };
    if (kind == null) return null;
    if (kind != WorkspaceDiffKind.text) {
      return WorkspaceFileDiff(
        kind: kind,
        path: value['path'],
        display: value['display'],
      );
    }
    if (value['before'] is! bool ||
        value['after'] is! bool ||
        value['coarse'] is! bool ||
        value['hunks'] is! List) {
      return null;
    }
    final hunks = <WorkspaceDiffHunk>[];
    for (final raw in value['hunks']) {
      final hunk = WorkspaceDiffHunk.parse(raw);
      if (hunk == null) return null;
      hunks.add(hunk);
    }
    return WorkspaceFileDiff(
      kind: kind,
      path: value['path'],
      display: value['display'],
      before: value['before'],
      after: value['after'],
      coarse: value['coarse'],
      hunks: List.unmodifiable(hunks),
    );
  }
}

enum WorkspaceDiffLineKind { context, added, deleted }

class WorkspaceDiffLine {
  const WorkspaceDiffLine(this.kind, this.oldLine, this.newLine, this.text);
  final WorkspaceDiffLineKind kind;
  final int? oldLine, newLine;
  final String text;
  String get sign => switch (kind) {
    WorkspaceDiffLineKind.added => '+',
    WorkspaceDiffLineKind.deleted => '-',
    WorkspaceDiffLineKind.context => ' ',
  };
}

/// Exactly FileDiff.hunkRows: context advances both sides; a removed line
/// advances only the old side and an added line only the new side.
List<WorkspaceDiffLine> workspaceHunkRows(WorkspaceDiffHunk hunk) {
  var oldLine = hunk.oldStart, newLine = hunk.newStart;
  return [
    for (final line in hunk.lines)
      switch (line[0]) {
        '+' => WorkspaceDiffLine(
          WorkspaceDiffLineKind.added,
          null,
          newLine++,
          line.substring(1),
        ),
        '-' => WorkspaceDiffLine(
          WorkspaceDiffLineKind.deleted,
          oldLine++,
          null,
          line.substring(1),
        ),
        _ => WorkspaceDiffLine(
          WorkspaceDiffLineKind.context,
          oldLine++,
          newLine++,
          line.substring(1),
        ),
      },
  ];
}

const workspaceDiffMaxRenderedLines = 5000;

/// The original renderer's display budget leaves source hunk coordinates intact.
({List<WorkspaceDiffHunk> hunks, bool truncated}) workspaceRenderedHunks(
  List<WorkspaceDiffHunk> hunks,
) {
  var remaining = workspaceDiffMaxRenderedLines;
  final kept = <WorkspaceDiffHunk>[];
  var truncated = false;
  for (final hunk in hunks) {
    if (remaining == 0) {
      truncated = true;
      break;
    }
    if (hunk.lines.length <= remaining) {
      kept.add(hunk);
      remaining -= hunk.lines.length;
    } else {
      kept.add(
        WorkspaceDiffHunk(
          oldStart: hunk.oldStart,
          oldLines: hunk.oldLines,
          newStart: hunk.newStart,
          newLines: hunk.newLines,
          lines: List.unmodifiable(hunk.lines.take(remaining)),
        ),
      );
      remaining = 0;
      truncated = true;
    }
  }
  return (hunks: List.unmodifiable(kept), truncated: truncated);
}

enum WorkspaceReadPhase { idle, waiting, loading, missing, error, ready }

class WorkspaceRead<T> {
  const WorkspaceRead(this.phase, [this.value]);
  final WorkspaceReadPhase phase;
  final T? value;
}

class _ClosedRead<T> implements ValueListenable<WorkspaceRead<T>> {
  const _ClosedRead();
  @override
  WorkspaceRead<T> get value => WorkspaceRead<T>(WorkspaceReadPhase.missing);
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _Read<T> {
  _Read(bool ready)
    : state = ValueNotifier(
        WorkspaceRead<T>(
          ready ? WorkspaceReadPhase.idle : WorkspaceReadPhase.waiting,
        ),
      );
  final ValueNotifier<WorkspaceRead<T>> state;
  String? requestId;
  int observers = 0;
  void reset(bool ready) {
    state.value = WorkspaceRead<T>(
      ready ? WorkspaceReadPhase.idle : WorkspaceReadPhase.waiting,
    );
  }
}

/// One viewed Session's narrow Host-read cache. Summary failures deliberately
/// become missing, just like ChangesSummaryStore; only failed diffs are retried.
/// Connection replacement clears every record and retires all pending replies.
class WorkspaceChangesController extends ChangeNotifier {
  WorkspaceChangesController({required this.runtime, required this.sessionId}) {
    _generation = runtime.connectionGeneration;
    _ready = runtime.ready;
    _preference = WorkspaceChangesPreference(runtime);
    _preference.addListener(_preferenceChanged);
    runtime.addListener(_connectionChanged);
    unawaited(_preference.start());
  }
  final RuntimeController runtime;
  final String sessionId;
  final _summaries = <int, _Read<WorkspaceChangesSummary>>{};
  final _diffs = <(int, int), _Read<WorkspaceFileDiff>>{};
  late int _generation;
  late bool _ready;
  late final WorkspaceChangesPreference _preference;
  bool get enabled => !_disposed && _preference.enabled;
  bool get preferenceConfirmed => _preference.confirmed;
  bool get retired => _disposed;
  Future<void> initialize() => _preference.start();
  bool _disposed = false;

  ValueListenable<WorkspaceRead<WorkspaceChangesSummary>> summary(int seq) =>
      _disposed
      ? const _ClosedRead<WorkspaceChangesSummary>()
      : _summary(seq).state;
  ValueListenable<WorkspaceRead<WorkspaceFileDiff>> diff(int seq, int index) =>
      _disposed
      ? const _ClosedRead<WorkspaceFileDiff>()
      : _diff(seq, index).state;
  _Read<WorkspaceChangesSummary> _summary(int seq) =>
      _summaries.putIfAbsent(seq, () => _Read(_ready));
  _Read<WorkspaceFileDiff> _diff(int seq, int index) =>
      _diffs.putIfAbsent((seq, index), () => _Read(_ready));

  Future<void> loadSummary(int seq) => _disposed
      ? Future.value()
      : _load(
          _summary(seq),
          'workspaceChanges.summary',
          {'seq': seq},
          WorkspaceChangesSummary.parse,
          summary: true,
        );
  Future<void> loadDiff(int seq, int index) => _disposed
      ? Future.value()
      : _load(
          _diff(seq, index),
          'workspaceChanges.diff',
          {'seq': seq, 'index': index},
          (raw) {
            final value = WorkspaceFileDiff.parse(raw);
            final files = _summary(seq).state.value.value?.files;
            if (files != null &&
                index >= 0 &&
                index < files.length &&
                value?.path != files[index].path) {
              return null;
            }
            return value;
          },
        );

  /// A route leases an in-flight comparison; leaving the last reader cancels
  /// the Host read. Completed cache entries are kept for the current connection.
  VoidCallback retainDiff(int seq, int index) {
    if (_disposed) return () {};
    final read = _diff(seq, index);
    read.observers++;
    var released = false;
    return () {
      if (released || _disposed) return;
      released = true;
      read.observers--;
      if (read.observers == 0 && read.requestId != null) {
        _cancel(read);
        read.state.value = const WorkspaceRead(WorkspaceReadPhase.idle);
      }
    };
  }

  Future<void> _load<T>(
    _Read<T> read,
    String method,
    Json args,
    T? Function(dynamic) parse, {
    bool summary = false,
  }) async {
    if (_disposed || !_ready || !enabled) return;
    final phase = read.state.value.phase;
    if (phase != WorkspaceReadPhase.idle &&
        phase != WorkspaceReadPhase.waiting &&
        (summary || phase != WorkspaceReadPhase.error)) {
      return;
    }
    final requestId = _newRequestId();
    read.requestId = requestId;
    read.state.value = WorkspaceRead<T>(WorkspaceReadPhase.loading);
    WorkspaceRead<T> next;
    try {
      final raw = await runtime.call(method, {
        ...args,
        'sessionId': sessionId,
        'requestId': requestId,
      });
      if (raw is Map &&
          raw['ok'] == false &&
          raw['error'] is Map &&
          raw['error']['code'] == 'workspace-changes/unavailable') {
        if (!_disposed && read.requestId == requestId) {
          read.requestId = null;
          read.state.value = WorkspaceRead<T>(WorkspaceReadPhase.missing);
        }
        return;
      }
      final value = _unwrap(raw);
      final parsed = value == null ? null : parse(value);
      next = value == null
          ? WorkspaceRead<T>(WorkspaceReadPhase.missing)
          : parsed == null
          ? WorkspaceRead<T>(
              summary ? WorkspaceReadPhase.missing : WorkspaceReadPhase.error,
            )
          : WorkspaceRead<T>(WorkspaceReadPhase.ready, parsed);
    } catch (_) {
      next = WorkspaceRead<T>(
        summary ? WorkspaceReadPhase.missing : WorkspaceReadPhase.error,
      );
    }
    if (_disposed || read.requestId != requestId) return;
    read.requestId = null;
    read.state.value = next;
  }

  void _cancel<T>(_Read<T> read) {
    final requestId = read.requestId;
    read.requestId = null;
    if (requestId == null) return;
    unawaited(
      runtime
          .call('workspaceChanges.cancel', {'requestId': requestId})
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void _connectionChanged() {
    if (_disposed ||
        (_generation == runtime.connectionGeneration &&
            _ready == runtime.ready)) {
      return;
    }
    _generation = runtime.connectionGeneration;
    _ready = runtime.ready;
    for (final read in [..._summaries.values, ..._diffs.values]) {
      _cancel(read);
      read.reset(_ready);
    }
    _reloadObserved();
  }

  void _preferenceChanged() {
    if (_disposed) return;
    if (!enabled) {
      for (final read in [..._summaries.values, ..._diffs.values]) {
        if (read.requestId != null) {
          _cancel(read);
          read.reset(_ready);
        }
      }
    }
    notifyListeners();
    _reloadObserved();
  }

  void _reloadObserved() {
    if (_ready && enabled && !_disposed) {
      for (final seq in _summaries.keys.toList()) {
        unawaited(loadSummary(seq));
      }
      for (final entry in _diffs.entries.toList()) {
        if (entry.value.observers > 0) {
          unawaited(loadDiff(entry.key.$1, entry.key.$2));
        }
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    runtime.removeListener(_connectionChanged);
    _preference.removeListener(_preferenceChanged);
    _preference.dispose();
    for (final read in [..._summaries.values, ..._diffs.values]) {
      _cancel(read);
    }
    // A Session can be replaced during its parent's build. Notify overlaid
    // detail routes after that build, before releasing their observed records.
    scheduleMicrotask(() {
      notifyListeners();
      for (final read in [..._summaries.values, ..._diffs.values]) {
        read.state.dispose();
      }
      super.dispose();
    });
  }
}

dynamic _unwrap(dynamic value) {
  if (value is Map && value['ok'] == true) return value['value'];
  throw const FormatException(
    'Host read failed or returned an invalid envelope',
  );
}

String _newRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
