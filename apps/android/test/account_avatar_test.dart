import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_android/account_avatar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'one shared picture survives both readers and retries only a failure',
    () async {
      final requests = <Completer<Uint8List>>[];
      final loader = AccountAvatarLoader(
        fetch: (_) {
          final request = Completer<Uint8List>();
          requests.add(request);
          return request.future;
        },
      );
      addTearDown(loader.dispose);

      loader.setUrl('https://platform.deepseek.com/picture/a');
      expect(loader.snapshot?.status, AccountAvatarStatus.loading);
      loader.setUrl('https://platform.deepseek.com/picture/a');
      loader.retry();
      expect(requests, hasLength(1));
      requests.single.completeError(StateError('network unavailable'));
      await Future<void>.delayed(Duration.zero);
      expect(loader.snapshot?.status, AccountAvatarStatus.failed);

      loader.retry();
      expect(requests, hasLength(2));
      final bytes = Uint8List.fromList([1, 2, 3]);
      requests.last.complete(bytes);
      await Future<void>.delayed(Duration.zero);
      final ready = loader.snapshot!;
      expect(ready.status, AccountAvatarStatus.ready);
      expect(ready.bytes, same(bytes));
      loader.retry();
      expect(requests, hasLength(2));
      loader.renderedImageFailed(ready);
      expect(loader.snapshot?.status, AccountAvatarStatus.failed);
      loader.retry();
      expect(requests, hasLength(3));
    },
  );

  test('late picture callbacks cannot replace another account or signed-out fallback', () async {
    final requests = <Completer<Uint8List>>[];
    final loader = AccountAvatarLoader(
      fetch: (_) {
        final request = Completer<Uint8List>();
        requests.add(request);
        return request.future;
      },
    );
    addTearDown(loader.dispose);
    loader.setUrl('https://platform.deepseek.com/picture/old');
    final stale = loader.snapshot!;
    loader.setUrl('https://platform.deepseek.com/picture/new');
    requests.first.complete(Uint8List.fromList([1]));
    await Future<void>.delayed(Duration.zero);
    expect(loader.snapshot?.url, endsWith('/new'));
    expect(loader.snapshot?.status, AccountAvatarStatus.loading);
    requests.last.complete(Uint8List.fromList([2]));
    await Future<void>.delayed(Duration.zero);
    loader.renderedImageFailed(stale);
    expect(loader.snapshot?.status, AccountAvatarStatus.ready);
    loader.clear();
    expect(loader.snapshot, isNull);
    loader.setUrl('https://platform.deepseek.com/picture/pending');
    loader.clear();
    requests.last.complete(Uint8List.fromList([3]));
    await Future<void>.delayed(Duration.zero);
    expect(loader.snapshot, isNull);
  });

  test(
    'picture source rejects non-HTTPS and credential-bearing URLs',
    () async {
      await expectLater(
        fetchAccountAvatar('http://platform.deepseek.com/picture'),
        throwsFormatException,
      );
      await expectLater(
        fetchAccountAvatar('https://token@platform.deepseek.com/picture'),
        throwsFormatException,
      );
      await expectLater(
        fetchAccountAvatar('data:image/png;base64,AAA'),
        throwsFormatException,
      );
      final base = accountAvatarUri('https://platform.deepseek.com/picture/a');
      expect(
        accountAvatarUri(
          base.resolve('https://cdn.example.test/b.png').toString(),
        ).host,
        'cdn.example.test',
      );
      expect(
        () => accountAvatarUri(
          base.resolve('http://cdn.example.test/b.png').toString(),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'picture byte cap also applies to unannounced streaming bodies',
    () async {
      expect(
        await readAccountAvatarBytes(
          Stream<List<int>>.fromIterable([
            Uint8List(accountAvatarByteLimit - 1),
            [7],
          ]),
        ),
        hasLength(accountAvatarByteLimit),
      );
      await expectLater(
        readAccountAvatarBytes(
          Stream<List<int>>.fromIterable([
            Uint8List(accountAvatarByteLimit),
            [7],
          ]),
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets('fallback remains circular, decorative and account-owned', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AccountAvatar(snapshot: null, onImageError: _ignored),
        ),
      ),
    );
    expect(find.byType(ClipOval), findsOneWidget);
    expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);
  });
}

void _ignored(AccountAvatarSnapshot _) {}
