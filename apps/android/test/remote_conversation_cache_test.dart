// 会话本地缓存：按设备隔离、版本/损坏降级、条数与大小上限淘汰。
import 'dart:convert';

import 'package:dsh_android/remote_conversation_cache.dart';
import 'package:dsh_android/remote_conversation_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('remote-conversation-cache-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Map<String, String> stored;
  var saves = 0;
  var reads = 0;

  setUp(() {
    stored = <String, String>{};
    saves = 0;
    reads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map<Object?, Object?>;
      final deviceId = arguments['deviceId'] as String;
      switch (call.method) {
        case 'remote.conversation.read':
          reads++;
          return stored[deviceId];
        case 'remote.conversation.save':
          stored[deviceId] = arguments['value'] as String;
          saves++;
          return null;
        default:
          throw MissingPluginException();
      }
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  RemoteConversationWindow window(List<int> seqs, {bool hasMore = false}) =>
      RemoteConversationWindow(
        events: <Map<String, dynamic>>[
          for (final seq in seqs)
            <String, dynamic>{
              'seq': seq,
              'kind': 'message',
              'text': 'event-$seq',
            },
        ],
        throughSeq: seqs.isEmpty ? 0 : seqs.last,
        firstSeq: seqs.isEmpty ? null : seqs.first,
        hasMore: hasMore,
      );

  test('caches and restores one conversation window per device', () async {
    const cache = RemoteConversationCache(channel: channel);
    await cache.save(
      deviceId: 'pc-1',
      sessionId: 's-1',
      window: window(<int>[1, 2, 3], hasMore: true),
      title: '修复登录',
    );
    await cache.save(
      deviceId: 'pc-1',
      sessionId: 's-2',
      window: window(<int>[10]),
    );
    final restored = await cache.read('pc-1', 's-1');
    expect(restored, isNotNull);
    expect(restored!.title, '修复登录');
    expect(restored.window.throughSeq, 3);
    expect(restored.window.firstSeq, 1);
    expect(restored.window.hasMore, isTrue);
    expect(restored.window.events.map((event) => event['seq']), <int>[1, 2, 3]);
    final other = await cache.read('pc-1', 's-2');
    expect(other!.window.events.single['seq'], 10);
  });

  test('one cache read restores conversation and stats preference', () async {
    const cache = RemoteConversationCache(channel: channel);
    await cache.save(
      deviceId: 'pc-1',
      sessionId: 's-1',
      window: window(<int>[1, 2]),
    );
    await cache.saveStatsExpanded(
      deviceId: 'pc-1',
      sessionId: 's-1',
      expanded: false,
    );
    reads = 0;
    final state = await cache.readState('pc-1', 's-1');
    expect(reads, 1);
    expect(state.entry?.window.events, hasLength(2));
    expect(state.statsExpanded, isFalse);
  });

  test('keeps devices isolated', () async {
    const cache = RemoteConversationCache(channel: channel);
    await cache.save(
      deviceId: 'pc-1',
      sessionId: 's-1',
      window: window(<int>[1]),
    );
    expect(await cache.read('pc-2', 's-1'), isNull);
    expect(await cache.read('pc-1', 's-1'), isNotNull);
  });

  test('damaged or unknown-version documents degrade to empty', () async {
    const cache = RemoteConversationCache(channel: channel);
    stored['pc-1'] = '{bad json';
    expect(await cache.read('pc-1', 's-1'), isNull);
    stored['pc-1'] = jsonEncode(<String, dynamic>{
      'version': 99,
      'sessions': <Object?>[],
    });
    expect(await cache.read('pc-1', 's-1'), isNull);
  });

  test(
    'evicts least recently saved sessions beyond the per-device limit',
    () async {
      const cache = RemoteConversationCache(channel: channel);
      for (
        var index = 0;
        index < RemoteConversationCache.maxSessionsPerDevice + 1;
        index++
      ) {
        await cache.save(
          deviceId: 'pc-1',
          sessionId: 's-$index',
          window: window(<int>[index]),
        );
      }
      expect(await cache.read('pc-1', 's-0'), isNull, reason: '最早的会话被淘汰');
      for (
        var index = 1;
        index <= RemoteConversationCache.maxSessionsPerDevice;
        index++
      ) {
        expect(await cache.read('pc-1', 's-$index'), isNotNull);
      }
      expect(saves, RemoteConversationCache.maxSessionsPerDevice + 1);
    },
  );

  test('trims oversized windows to the newest events that still fit', () async {
    const cache = RemoteConversationCache(channel: channel);
    final oversized = RemoteConversationWindow(
      events: <Map<String, dynamic>>[
        <String, dynamic>{'seq': 1, 'text': 'x' * 300000},
        <String, dynamic>{'seq': 2, 'text': 'tail'},
      ],
      throughSeq: 2,
      firstSeq: 1,
    );
    await cache.save(deviceId: 'pc-1', sessionId: 's-1', window: oversized);
    final restored = await cache.read('pc-1', 's-1');
    expect(restored, isNotNull);
    expect(restored!.window.events.map((event) => event['seq']), <int>[2]);
    expect(
      utf8.encode(stored['pc-1']!).length,
      lessThanOrEqualTo(RemoteConversationCache.maxDeviceBytes),
    );
  });
  test(
    'keeps a contiguous newest suffix under the session byte limit',
    () async {
      const cache = RemoteConversationCache(channel: channel);
      final events = <Map<String, dynamic>>[
        for (var seq = 1; seq <= 400; seq++)
          <String, dynamic>{'seq': seq, 'text': '消息' * 400},
      ];
      await cache.save(
        deviceId: 'pc-1',
        sessionId: 'long-session',
        window: RemoteConversationWindow(
          events: events,
          throughSeq: 400,
          firstSeq: 1,
        ),
      );
      final item =
          (jsonDecode(stored['pc-1']!) as Map<String, dynamic>)['sessions']
              as List<dynamic>;
      final encoded = item.single as Map<String, dynamic>;
      expect(
        utf8.encode(jsonEncode(encoded)).length,
        lessThanOrEqualTo(RemoteConversationCache.maxSessionBytes),
      );
      final restored = await cache.read('pc-1', 'long-session');
      final kept = restored!.window.events;
      expect(kept.length, lessThan(events.length));
      expect(kept.last['seq'], 400);
      expect(kept.first['seq'], restored.window.firstSeq);
      expect(
        kept.map((event) => event['seq']),
        List<int>.generate(
          kept.length,
          (index) => (kept.first['seq'] as int) + index,
        ),
      );
    },
  );
  test('统计条展开偏好按设备+会话持久化，并在事件写回后保留', () async {
    const cache = RemoteConversationCache(channel: channel);
    await cache.saveStatsExpanded(
      deviceId: 'pc-1',
      sessionId: 's-1',
      expanded: false,
    );
    expect(await cache.readStatsExpanded('pc-1', 's-1'), isFalse);
    expect(await cache.readStatsExpanded('pc-1', 's-2'), isNull);
    expect(await cache.readStatsExpanded('pc-2', 's-1'), isNull);

    await cache.save(
      deviceId: 'pc-1',
      sessionId: 's-1',
      window: window(<int>[1, 2]),
      title: '保留偏好',
    );
    expect(await cache.readStatsExpanded('pc-1', 's-1'), isFalse);
    expect(await cache.read('pc-1', 's-1'), isNotNull);

    await cache.saveStatsExpanded(
      deviceId: 'pc-1',
      sessionId: 's-1',
      expanded: true,
    );
    expect(await cache.readStatsExpanded('pc-1', 's-1'), isTrue);
  });

  test('旧缓存文档没有统计偏好时返回 null（默认展开）', () async {
    const cache = RemoteConversationCache(channel: channel);
    stored['pc-1'] = jsonEncode(<String, dynamic>{
      'version': 1,
      'sessions': <Map<String, dynamic>>[
        <String, dynamic>{
          'sessionId': 's-1',
          'title': '旧会话',
          'throughSeq': 1,
          'firstSeq': 1,
          'hasMore': false,
          'updatedAt': 1,
          'events': <dynamic>[],
        },
      ],
    });
    expect(await cache.readStatsExpanded('pc-1', 's-1'), isNull);
    await cache.saveStatsExpanded(
      deviceId: 'pc-1',
      sessionId: 's-1',
      expanded: false,
    );
    expect(await cache.readStatsExpanded('pc-1', 's-1'), isFalse);
  });
}
