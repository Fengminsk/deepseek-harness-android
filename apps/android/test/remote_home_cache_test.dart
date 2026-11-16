import 'package:dsh_android/remote_dsh_page.dart';
import 'package:dsh_android/remote_home_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('remote-home-cache-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('restores per-computer project and session labels', () async {
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
            RemoteDshSession(id: 's-1', title: 'Latest', updatedAt: 42),
          ],
        ),
      ],
      'pc-2': <RemoteDshProject>[],
    });
    final restored = await cache.read();
    expect(restored.keys, containsAll(<String>['pc-1', 'pc-2']));
    expect(restored['pc-1']!.single.sessions.single.title, 'Latest');
    expect(restored['pc-1']!.single.sessions.single.updatedAt, 42);
    expect(restored['pc-2'], isEmpty);
  });

  test('a damaged snapshot does not block the home page', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => '{bad json');
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await const RemoteHomeCache(channel: channel).read(), isEmpty);
  });
}
