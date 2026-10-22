import 'dart:async';
import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

Json changeEvent(int seq, String type, int turn) => {
  'seq': seq,
  'type': type,
  'data': {'turn': turn},
};
Json changedFile(String path, {int added = 2, int deleted = 1}) => {
  'path': path,
  'display': path,
  'added': added,
  'deleted': deleted,
};
Json changeSummary({int turn = 1, List<Json>? files, int? total}) => {
  'turn': turn,
  'files': files ?? [changedFile('src/example.dart')],
  'total': total ?? files?.length ?? 1,
  'added': 10,
  'deleted': 4,
};
Json textDiff({
  String path = 'src/example.dart',
  List<String>? lines,
  bool coarse = false,
  int oldLines = 3,
  int newLines = 3,
}) => {
  'kind': 'text',
  'path': path,
  'display': path,
  'before': true,
  'after': true,
  'coarse': coarse,
  'hunks': [
    {
      'oldStart': 8,
      'oldLines': oldLines,
      'newStart': 14,
      'newLines': newLines,
      'lines': lines ?? [' context', '-before', '+after', ' '],
    },
  ],
};
Json accepted(dynamic value) => {'ok': true, 'value': value};
Json unavailable() => {
  'ok': false,
  'error': {'code': 'workspace-changes/unavailable'},
};

class ChangesRuntime extends RuntimeController {
  ChangesRuntime() {
    phase = 'ready';
  }
  int generation = 0;
  bool developerEnabled = true;
  bool malformedPreference = false;
  Completer<dynamic>? preferenceRead;
  final calls = <(String, Json)>[];
  Future<dynamic> Function(String, Json)? handler;
  @override
  int get connectionGeneration => generation;
  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    calls.add((method, params));
    if (method == 'api.call') {
      expectSync(params, {
        'namespace': 'settings',
        'method': 'describe',
        'args': {},
      });
      if (preferenceRead != null) return preferenceRead!.future;
      return settingsAnswer();
    }
    if (method == 'workspaceChanges.cancel') {
      return accepted({'cancelled': true});
    }
    return handler != null
        ? handler!(method, params)
        : accepted(
            method == 'workspaceChanges.summary' ? changeSummary() : textDiff(),
          );
  }

  Json settingsAnswer() => jsonDecode(
    jsonEncode({
      'writable': true,
      'namespaces': [
        {
          'ns': 'ui-settings',
          'revision': generation,
          'schema': {},
          'secrets': [],
          'value': {'enabled': malformedPreference ? 'true' : developerEnabled},
          'base': {'enabled': true},
          'user': {},
        },
      ],
    }),
  ) as Json;
  void settingsChanged(bool value) {
    developerEnabled = value;
    forms = List.of(forms);
    notifyListeners();
  }

  void reconnect() {
    generation++;
    notifyListeners();
  }

  List<(String, Json)> reads(String method) =>
      calls.where((call) => call.$1 == method).toList();
}

Future<void> flushChanges() => Future<void>.delayed(Duration.zero);
