import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// The chat hero observes a preset without admitting its draft conversation.
/// Keep this control stream separate from account and model test observations.
class ReadOnlyPresets {
  final control = StreamController<Json>.broadcast(sync: true);
  final reads = <String>[];
  int observations = 0;

  bool handles(String method, Json params) =>
      method == 'api.call' &&
      const {
        'agentPresets.list',
        'settings.describe',
        'session.list',
        'session.projections',
      }.contains('${params['namespace']}.${params['method']}');

  bool observes(String namespace, String method) =>
      namespace == 'session' && method == 'control';

  Stream<Json> watch({required Json args, Json Function()? resumeArgs}) {
    expectSync(args, isEmpty);
    expectSync(resumeArgs, isNull);
    observations++;
    return control.stream;
  }

  dynamic reply(Json params) {
    final operation = '${params['namespace']}.${params['method']}';
    final args = params['args'] as Json;
    reads.add(operation);
    switch (operation) {
      case 'agentPresets.list':
        expectSync(args, isEmpty);
        return {
          'presets': [
            {'id': 'android', 'name': '手机 Agent', 'isDefault': true},
          ],
        };
      case 'settings.describe':
        expectSync(args, isEmpty);
        return {
          'writable': true,
          'namespaces': [
            {
              'ns': 'agent-preset-registry',
              'revision': 1,
              'value': {'default': 'android'},
            },
          ],
        };
      case 'session.list':
        expectSync(args, {'_request': <String, dynamic>{}});
        return {'items': <Json>[]};
      case 'session.projections':
        expectSync(args.keys, ['request']);
        expectSync((args['request'] as Json).keys, ['sessionId']);
        expectSync(args['request']['sessionId'], isA<String>());
        // These hosts only have a local draft; no Session has been admitted.
        return null;
      default:
        throw StateError('Unexpected preset fixture request: $operation');
    }
  }

  void dispose() => unawaited(control.close());
}
