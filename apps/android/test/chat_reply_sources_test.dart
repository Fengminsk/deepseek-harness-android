import 'package:dsh_android/chat_reply_sources.dart';
import 'package:dsh_android/tool_activity_data.dart';
import 'package:flutter_test/flutter_test.dart';

ToolActivity sourceActivity(
  String id,
  String name,
  dynamic meta, {
  ToolActivityPhase phase = ToolActivityPhase.completed,
  bool hasResult = true,
  List<ToolActivity> children = const [],
  List<dynamic> content = const [],
}) => ToolActivity(
  identity: id,
  callId: id,
  anchorSeq: 1,
  name: name,
  phase: phase,
  events: const [],
  children: children,
  meta: meta,
  hasResult: hasResult,
  content: content,
);

void main() {
  test('only canonical successful structured results yield sources', () {
    final sources = ChatReplySources.fromActivities([
      sourceActivity('valid', 'web_search', {
        'sources': [
          {
            'url': 'https://example.org/a',
            'title': '原始标题',
            'snippet': '原始摘录',
            'publishedAt': '2026-10-22',
          },
        ],
        'truncated': true,
      }),
      sourceActivity('forged', 'shell', {
        'sources': [
          {'url': 'https://fake.org'},
        ],
        'truncated': false,
      }),
      sourceActivity('failed', 'web_search', {
        'sources': [
          {'url': 'https://failed.org'},
        ],
        'truncated': false,
      }, phase: ToolActivityPhase.failed),
      sourceActivity(
        'old',
        'web_search',
        null,
        content: [
          {'type': 'text', 'text': 'Sources:\n- [Guess](https://guess.org)'},
        ],
      ),
      sourceActivity('pending', 'web_fetch', {
        'url': 'https://pending.org',
        'statusCode': 200,
        'truncated': false,
      }, hasResult: false),
    ]);
    expect(sources.entries.length, 1);
    final source = sources.entries.single;
    expect(source.url, 'https://example.org/a');
    expect(source.label, '原始标题');
    expect(source.snippet, '原始摘录');
    expect(source.publishedAt, '2026-10-22');
    expect(source.records.single.activityId, 'valid');
    expect(sources.truncated, isTrue);
  });

  test(
    'invalid opaque search metadata rejects the whole result like original',
    () {
      for (final meta in [
        {
          'sources': [
            {'url': 'https://valid.org'},
            {'url': 123},
          ],
          'truncated': false,
        },
        {
          'sources': [
            {'url': 'https://valid.org', 'title': null},
          ],
          'truncated': false,
        },
        {
          'sources': [
            {'url': 'https://valid.org'},
          ],
        },
        {
          'sources': [
            {'url': 'https://valid.org'},
          ],
          'truncated': false,
          'answer': 2,
        },
      ]) {
        expect(
          ChatReplySources.fromActivities([
            sourceActivity('a', 'web_search', meta),
          ]).isEmpty,
          isTrue,
        );
      }
    },
  );

  test('PTC sources dedupe exact URLs while preserving fetch status and provenance', () {
    final fetch = sourceActivity('child', 'web_fetch', {
      'url': 'https://example.org/a',
      'statusCode': 404,
      'truncated': true,
    });
    final search = sourceActivity('search', 'web_search', {
      'sources': [
        {'url': 'https://example.org/a', 'title': '来自搜索的标题'},
      ],
      'truncated': false,
    });
    final parent = sourceActivity(
      'ptc',
      'execute_code',
      null,
      children: [fetch],
    );
    final sources = ChatReplySources.fromActivities([search, parent, fetch]);
    expect(sources.entries.length, 1);
    expect(sources.entries.single.records.length, 2);
    expect(sources.entries.single.records.last.statusCode, 404);
    expect(sources.entries.single.records.last.kind, ChatReplySourceKind.fetch);
    expect(sources.entries.single.label, '来自搜索的标题');
    expect(sources.truncated, isTrue);
  });

  test('missing titles use actual URL host; unsafe destinations stay non-navigable', () {
    for (final (url, expected) in [
      ('https://actual.example/path', true),
      ('http://actual.example/path', true),
      ('javascript:alert(1)', false),
      ('file:///private/token', false),
      ('https://user:secret@example.org/', false),
      ('/relative', false),
    ]) {
      final source = ChatReplySources.fromActivities([
        sourceActivity(url, 'web_fetch', {
          'url': url,
          'statusCode': 200,
          'truncated': false,
        }),
      ]).entries.single;
      expect(source.destination != null, expected, reason: url);
      expect(source.url, url);
      expect(source.title, isNull);
    }
    final source = ChatReplySources.fromActivities([
      sourceActivity('s', 'web_search', {
        'sources': [
          {'url': 'https://actual.example/path'},
        ],
        'truncated': false,
      }),
    ]).entries.single;
    expect(source.label, 'actual.example');
  });

  test(
    'answer links require explicit Markdown links to observed safe URLs',
    () {
      final sources = ChatReplySources.fromActivities([
        sourceActivity('search', 'web_search', {
          'sources': [
            {'url': 'https://example.org/a', 'title': 'A'},
            {'url': 'https://example.org/b', 'title': 'B'},
            {'url': 'javascript:alert(1)', 'title': 'Unsafe'},
          ],
          'truncated': false,
        }),
      ]);
      expect(
        sources.answerLinks('''
[原始结果](https://example.org/a) 与 https://example.org/b。
`[代码](https://example.org/b)`

```md
[示例](https://example.org/b)
```
[未观察](https://unobserved.example/)
[不安全](javascript:alert(1))
'''),
        {'https://example.org/a'},
      );
      expect(sources.answerLinks(''), isEmpty);
    },
  );

  test('equivalent reprojected facts keep an open source snapshot', () {
    ChatReplySources project(String title) => ChatReplySources.fromActivities([
      sourceActivity('search', 'web_search', {
        'sources': [
          {'url': 'https://example.org/a', 'title': title},
        ],
        'truncated': false,
      }),
    ]);
    final first = project('A');
    expect(first.sameResultsAs(project('A')), isTrue);
    expect(first.sameResultsAs(project('B')), isFalse);
    expect(first.sameResultsAs(ChatReplySources.empty), isFalse);
  });
}
