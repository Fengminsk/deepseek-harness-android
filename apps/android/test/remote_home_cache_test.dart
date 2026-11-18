import 'dart:convert';

import 'package:dsh_android/remote_dsh_page.dart';
import 'package:dsh_android/remote_home_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('remote-home-cache-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('restores per-computer projects and remembered expansion choices', () async {
    String? saved;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'remote.home.save') {
        saved = call.arguments as String;
        return null;
      }
      if (call.method == 'remote.home.read') return saved;
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const cache = RemoteHomeCache(channel: channel);
    await cache.write(
      const <String, List<RemoteDshProject>>{
        'pc-1': <RemoteDshProject>[
          RemoteDshProject(
            id: 'cwd:Project',
            deviceId: 'pc-1',
            name: 'Project',
            sessions: <RemoteDshSession>[
              RemoteDshSession(id: 's-1', title: 'Latest', updatedAt: 42),
            ],
          ),
        ],
        'pc-2': <RemoteDshProject>[],
      },
      expanded: const <String, bool>{'pc-1\u0000cwd:Project': false},
    );
    final restored = await cache.read();
    expect(restored.projects.keys, containsAll(<String>['pc-1', 'pc-2']));
    expect(restored.projects['pc-1']!.single.sessions.single.title, 'Latest');
    expect(restored.projects['pc-1']!.single.sessions.single.updatedAt, 42);
    expect(restored.projects['pc-2'], isEmpty);
    expect(restored.expanded, <String, bool>{'pc-1\u0000cwd:Project': false});
  });

  test('does not persist running state so an offline cache cannot claim work', () async {
    String? saved;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'remote.home.save') {
        saved = call.arguments as String;
        return null;
      }
      if (call.method == 'remote.home.read') return saved;
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const cache = RemoteHomeCache(channel: channel);
    await cache.write(const <String, List<RemoteDshProject>>{
      'pc-1': <RemoteDshProject>[
        RemoteDshProject(
          id: 'cwd:Project',
          deviceId: 'pc-1',
          name: 'Project',
          sessions: <RemoteDshSession>[
            RemoteDshSession(id: 's-1', title: 'Working', running: true),
          ],
        ),
      ],
    });
    expect(saved, isNot(contains('"running"')));
    final restored = await cache.read();
    expect(restored.projects['pc-1']!.single.sessions.single.running, isFalse);
  });

  test('reads a version 1 snapshot without expansion choices', () async {
    const legacy = <String, Object?>{
      'version': 1,
      'devices': <String, Object?>{
        'pc-1': <Object?>[
          <String, Object?>{
            'id': 'cwd:Project',
            'name': 'Project',
            'sessions': <Object?>[],
          },
        ],
      },
    };
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => jsonEncode(legacy),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final restored = await const RemoteHomeCache(channel: channel).read();
    expect(restored.projects['pc-1']!.single.name, 'Project');
    expect(restored.expanded, isEmpty);
  });

  test('a damaged snapshot does not block the home page', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => '{bad json');
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await const RemoteHomeCache(channel: channel).read(), isA<RemoteHomeSnapshot>());
    expect((await const RemoteHomeCache(channel: channel).read()).isEmpty, isTrue);
  });
}
