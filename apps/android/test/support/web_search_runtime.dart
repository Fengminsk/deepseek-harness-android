import 'dart:async';

import 'package:dsh_android/configuration_edits.dart';
import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/web_search_settings_data.dart';
import 'package:flutter/services.dart';

Json _string({String? role}) => {
  'type': 'string',
  if (role != null) 'meta': {'role': role},
};
Json _number({int? min, int? max}) => {
  'type': 'number',
  'meta': {'step': 1, 'min': ?min, 'max': ?max},
};

/// Only the APIs this screen is permitted to use. Unknown calls fail the test.
class WebSearchTestRuntime extends RuntimeController {
  WebSearchTestRuntime() {
    phase = 'ready';
    bases = {
      webRoutingNamespace: {
        'searchProvider': 'deepseek-official',
        'fetchProvider': 'http',
      },
      webSearchNamespace: {
        'apiKeyEnv': 'MESSAGES_KEY',
        'baseURL': 'https://api.deepseek.com/anthropic/v1',
        'maxUses': 5,
        'model': 'deepseek-v4-flash',
        'maxTokens': 4096,
        'apiVersion': '2023-06-01',
      },
      webApiNamespace: {
        'apiKeyEnv': 'SEARCH_KEY',
        'baseURL': 'https://api.deepseek.com/v1/tools',
        'count': 10,
        'sendOriginalQuestion': true,
      },
    };
    values = {
      for (final entry in bases.entries)
        entry.key: cloneConfiguration(entry.value),
    };
    users = {for (final ns in bases.keys) ns: <String, dynamic>{}};
    revisions = {for (final ns in bases.keys) ns: 4};
  }

  late Map<String, Json> bases, values, users;
  late Map<String, int> revisions;
  final absent = <String>{};
  final calls = <({String method, Json args})>[];
  final configured = <String>{};
  bool writable = true, credentialWritable = true;
  bool notifyOnWrite = false;
  bool failKey = false;
  String? rejectSection, loseSection;
  bool applyBeforeLoss = false;
  int generation = 1;
  Completer<void>? pauseWrite;
  Completer<void>? pauseKeyWrite;
  Completer<dynamic>? keyRead;
  String? delayedKeyRef;

  @override
  int get connectionGeneration => generation;

  Json descriptor(String namespace) => {
    'ns': namespace,
    'revision': revisions[namespace],
    'value': cloneConfiguration(values[namespace]!),
    'user': cloneConfiguration(users[namespace]!),
    'base': cloneConfiguration(bases[namespace]!),
    'secrets': <Json>[],
    'schema': {
      'type': 'object',
      'dict': switch (namespace) {
        webRoutingNamespace => {
          'searchProvider': _string(),
          'fetchProvider': _string(),
        },
        webSearchNamespace => {
          'apiKey': _string(role: 'secret'),
          'apiKeyEnv': _string(role: 'credential-ref'),
          'baseURL': _string(),
          'model': _string(),
          'apiVersion': _string(),
          'maxUses': _number(min: 1),
          'maxTokens': _number(min: 1),
        },
        _ => {
          'apiKey': _string(role: 'secret'),
          'apiKeyEnv': _string(role: 'credential-ref'),
          'baseURL': _string(),
          'count': _number(min: 1, max: 50),
          'sendOriginalQuestion': {'type': 'boolean'},
        },
      },
    },
  };

  List<Json> get descriptors => [
    for (final ns in values.keys)
      if (!absent.contains(ns)) descriptor(ns),
  ];
  List<({String method, Json args})> get writes => calls
      .where(
        (call) =>
            call.method == 'settings.mutate' ||
            call.method == 'credentials.set' ||
            call.method == 'credentials.unset',
      )
      .toList();

  void change(
    String namespace,
    String field,
    dynamic value, {
    bool notify = true,
  }) {
    values[namespace]![field] = value;
    revisions[namespace] = revisions[namespace]! + 1;
    if (notify) publishForms();
  }

  void publishForms() {
    forms = descriptors;
    notifyListeners();
  }

  void reconnect() {
    generation++;
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'settings.describe') return descriptors;
    if (method != 'api.call') throw StateError('Unexpected API $method');
    final name = '${params['namespace']}.${params['method']}';
    final args = cloneConfiguration(params['args'] as Json);
    calls.add((method: name, args: args));
    switch (name) {
      case 'settings.describe':
        return {'writable': writable, 'namespaces': descriptors};
      case 'settings.mutate':
        final ns = args['ns'] as String;
        final waiting = pauseWrite;
        pauseWrite = null;
        if (waiting != null) await waiting.future;
        if (args['expectedRevision'] != revisions[ns] || rejectSection == ns) {
          throw PlatformException(code: 'settings/conflict');
        }
        if (loseSection != ns || applyBeforeLoss) {
          for (final op in (args['ops'] as List).cast<Json>()) {
            applyConfigurationEdit(users[ns]!, op);
            if (op['op'] == 'unset') {
              final key = (op['path'] as List).single as String;
              if (bases[ns]!.containsKey(key)) {
                values[ns]![key] = bases[ns]![key];
              } else {
                values[ns]!.remove(key);
              }
            } else {
              applyConfigurationEdit(values[ns]!, op);
            }
          }
          revisions[ns] = revisions[ns]! + 1;
          if (notifyOnWrite) publishForms();
        }
        if (loseSection == ns) throw PlatformException(code: 'disconnected');
        return descriptor(ns);
      case 'credentials.describe':
        final refs = (args['refs'] as List).cast<String>();
        if (keyRead != null && refs.contains(delayedKeyRef)) {
          final pending = keyRead!;
          keyRead = null;
          return pending.future;
        }
        return {
          for (final ref in refs)
            ref: {
              'configured': configured.contains(ref),
              'writable': credentialWritable,
              'source': null,
            },
        };
      case 'credentials.set':
        final waiting = pauseKeyWrite;
        pauseKeyWrite = null;
        if (waiting != null) await waiting.future;
        if (failKey) throw PlatformException(code: 'disconnected');
        configured.add(args['ref'] as String);
        return null;
      case 'credentials.unset':
        configured.remove(args['ref'] as String);
        return null;
      default:
        throw StateError('Unexpected API $name');
    }
  }
}
