import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_android/configuration_edits.dart';

Map<String, dynamic> snapshot({
  required Map<String, dynamic> value,
  Map<String, dynamic>? user,
  List<Map<String, dynamic>> secrets = const [],
  Map<String, dynamic>? schema,
  int revision = 1,
}) => {
  'ns': 'provider',
  'value': value,
  'user': user,
  'secrets': secrets,
  'revision': revision,
  'schema': schema,
};

void main() {
  test('editing a nested address leaves the hidden token and inherited defaults intact', () {
    final descriptor = snapshot(
      value: {
        'connection': {'url': 'https://old.example', 'timeout': 120},
        'enabled': true,
      },
      user: {
        'connection': {'url': 'https://old.example'},
      },
      secrets: [
        {
          'path': ['connection', 'token'],
          'set': true,
        },
      ],
    );
    final draft = cloneConfiguration(descriptor['value'])
      ..['connection']['url'] = 'https://new.example';
    final edits = configurationEdits(descriptor, draft);
    final actual = <String, dynamic>{
      'connection': {'url': 'https://old.example', 'token': 'private-token'},
    };
    for (final edit in edits) {
      applyConfigurationEdit(actual, edit);
    }
    expect(actual, {
      'connection': {'url': 'https://new.example', 'token': 'private-token'},
    });
    expect(edits, hasLength(1));
    expect(configurationEdits(descriptor, descriptor['value']), isEmpty);
  });

  test(
    'removing or replacing a secret ancestor and adding a secret are rejected',
    () {
      final descriptor = snapshot(
        value: {
          'connection': {'url': 'old'},
        },
        secrets: [
          {
            'path': ['connection', 'token'],
            'set': true,
          },
        ],
      );
      for (final draft in <Map<String, dynamic>>[
        {},
        {'connection': null},
        {'connection': 'replacement'},
        {
          'connection': {'url': 'old', 'token': 'new'},
        },
      ]) {
        expect(
          () => configurationEdits(descriptor, draft),
          throwsA(isA<ConfigurationEditException>()),
        );
      }
    },
  );

  test('secret-bearing arrays cannot be replaced, reordered, extended or edited by index', () {
    final descriptor = snapshot(
      value: {
        'accounts': [
          {'name': 'one'},
          {'name': 'two'},
        ],
        'timeout': 1,
      },
      secrets: [
        {
          'path': ['accounts', '0', 'token'],
          'set': true,
        },
        {
          'path': ['accounts', '1', 'token'],
          'set': false,
        },
      ],
    );
    for (final accounts in [
      <dynamic>[],
      [
        {'name': 'two'},
        {'name': 'one'},
      ],
      [
        {'name': 'changed'},
        {'name': 'two'},
      ],
      [
        {'name': 'one'},
        {'name': 'two'},
        {'name': 'three'},
      ],
    ]) {
      expect(
        () => configurationEdits(descriptor, {
          'accounts': accounts,
          'timeout': 1,
        }),
        throwsA(isA<ConfigurationEditException>()),
      );
    }
    final ordinary = cloneConfiguration(descriptor['value'])..['timeout'] = 2;
    expect(configurationEdits(descriptor, ordinary), [
      {
        'op': 'set',
        'path': ['timeout'],
        'value': 2,
      },
    ]);
  });

  test(
    'schema protects a new dict entry absent from the redaction sidecar',
    () {
      final descriptor = snapshot(
        value: {'accounts': <String, dynamic>{}},
        schema: {
          'uid': 1,
          'refs': {
            '1': {
              'uid': 1,
              'type': 'object',
              'dict': {'accounts': 2},
            },
            '2': {'uid': 2, 'type': 'dict', 'inner': 3},
            '3': {
              'uid': 3,
              'type': 'object',
              'dict': {'token': 4, 'url': 5},
            },
            '4': {
              'uid': 4,
              'type': 'string',
              'meta': {'role': 'secret'},
            },
            '5': {'uid': 5, 'type': 'string'},
          },
        },
      );
      expect(
        () => configurationEdits(descriptor, {
          'accounts': {
            'new': {'token': 'secret'},
          },
        }),
        throwsA(isA<ConfigurationEditException>()),
      );
      expect(
        configurationEdits(descriptor, {
          'accounts': {
            'new': {'url': 'address'},
          },
        }),
        [
          {
            'op': 'set',
            'path': ['accounts', 'new', 'url'],
            'value': 'address',
          },
        ],
      );
    },
  );

  test('reset removes only ordinary overrides and preserves hidden credentials and arrays', () {
    final descriptor = snapshot(
      value: {},
      user: {
        'connection': {
          'url': 'overridden',
          'retry': {'count': 3},
        },
        'accounts': [
          {'name': 'one'},
        ],
        'timeout': 10,
      },
      secrets: [
        {
          'path': ['connection', 'token'],
          'set': true,
        },
        {
          'path': ['accounts', '0', 'token'],
          'set': true,
        },
      ],
    );
    final actual = <String, dynamic>{
      'connection': {
        'url': 'overridden',
        'retry': {'count': 3},
        'token': 'keep',
      },
      'accounts': [
        {'name': 'one', 'token': 'keep-array'},
      ],
      'timeout': 10,
    };
    final reset = configurationReset(descriptor);
    for (final operation in reset.operations) {
      applyConfigurationEdit(actual, operation);
    }
    expect(actual, {
      'connection': {'token': 'keep'},
      'accounts': [
        {'name': 'one', 'token': 'keep-array'},
      ],
    });
    expect(reset.preserved, contains(equals(['accounts'])));
    expect(reset.preserved, contains(equals(['connection', 'token'])));
  });

  test('secret-role union containers protect newly introduced descendants', () {
    final descriptor = snapshot(
      value: {'accounts': <String, dynamic>{}},
      schema: {
        'uid': 1,
        'refs': {
          '1': {
            'uid': 1,
            'type': 'object',
            'dict': {'accounts': 2},
          },
          '2': {'uid': 2, 'type': 'dict', 'inner': 3},
          '3': {
            'uid': 3,
            'type': 'union',
            'list': [4, 5],
          },
          '4': {
            'uid': 4,
            'type': 'object',
            'dict': {'token': 5},
            'meta': {'role': 'secret'},
          },
          '5': {'uid': 5, 'type': 'string'},
        },
      },
    );
    expect(
      () => configurationEdits(descriptor, {
        'accounts': {
          'new': {'token': 'secret'},
        },
      }),
      throwsA(isA<ConfigurationEditException>()),
    );
  });

  test('three-way merge retains unrelated remote changes without replacing parent objects', () {
    final before = snapshot(
      value: {
        'connection': {'url': 'old', 'timeout': 10},
        'enabled': true,
      },
    );
    final latest = snapshot(
      value: {
        'connection': {'url': 'old', 'timeout': 30},
        'enabled': false,
      },
      revision: 2,
    );
    final result = rebaseConfiguration(before, {
      'connection': {'url': 'mine', 'timeout': 10},
      'enabled': true,
    }, latest);
    expect(result.conflicts, isEmpty);
    expect(result.value, {
      'connection': {'url': 'mine', 'timeout': 30},
      'enabled': false,
    });
  });

  test('same-field conflict requires an explicit choice and retains null distinct from absent', () {
    final before = snapshot(value: {'name': 'old', 'optional': null});
    final latest = snapshot(value: {'name': 'remote'}, revision: 2);
    final draft = <String, dynamic>{'name': 'local', 'optional': 'mine'};
    final conflict = rebaseConfiguration(before, draft, latest);
    expect(conflict.conflicts, hasLength(2));
    final resolved = rebaseConfiguration(
      before,
      draft,
      latest,
      useLocal: {
        conflict.conflicts[0].id: false,
        conflict.conflicts[1].id: true,
      },
    );
    expect(resolved.conflicts, isEmpty);
    expect(resolved.value, {'name': 'remote', 'optional': 'mine'});
  });

  test('remote parent replacement is treated as a conflict instead of silently recreated', () {
    final before = snapshot(
      value: {
        'nested': {'one': 1},
      },
    );
    final latest = snapshot(value: {'nested': null}, revision: 2);
    final result = rebaseConfiguration(before, {
      'nested': {'one': 2},
    }, latest);
    expect(result.conflicts, hasLength(1));
    expect(result.value, {'nested': null});
  });
}
