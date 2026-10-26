import 'package:dsh_android/chat_reply_sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_reply_sources_test.dart' show sourceActivity;

void main() {
  test(
    'answer citations lead the drawer without removing observed search results',
    () {
      final sources = ChatReplySources.fromActivities([
        sourceActivity('search', 'web_search', {
          'sources': [
            {'url': 'https://example.org/unlinked'},
            {'url': 'https://example.org/cited'},
            {'url': 'https://example.org/also-cited'},
          ],
          'truncated': false,
        }),
      ]);
      final ordered = sources.forAnswer({
        'https://example.org/cited',
        'https://example.org/also-cited',
      });
      expect(ordered.map((source) => source.url), [
        'https://example.org/cited',
        'https://example.org/also-cited',
        'https://example.org/unlinked',
      ]);
      expect(
        sources.entries.first.url,
        'https://example.org/unlinked',
        reason: 'presentation order must not rewrite retrieval history',
      );
    },
  );

  test(
    'tool URL with control or whitespace never becomes a tappable destination',
    () {
      for (final url in [
        'https://example.org/a b',
        'https://example.org/a\n',
        ' https://example.org/a',
      ]) {
        final sources = ChatReplySources.fromActivities([
          sourceActivity('fetch', 'web_fetch', {
            'url': url,
            'statusCode': 200,
            'truncated': false,
          }),
        ]);
        expect(sources.entries.single.destination, isNull, reason: url);
      }
    },
  );
}
