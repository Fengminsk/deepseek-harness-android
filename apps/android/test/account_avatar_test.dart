import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_android/account_avatar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

class _Headers extends Fake implements HttpHeaders {
  _Headers(this.type, [this.location]);
  final String? type, location;
  @override
  ContentType? get contentType =>
      type == null ? null : ContentType.parse(type!);
  @override
  String? value(String name) =>
      name == HttpHeaders.locationHeader ? location : null;
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(this.headers, {this.statusCode = 200, Uint8List? bytes})
    : contentLength = bytes?.length ?? 0,
      super(Stream.value(bytes ?? Uint8List(0)));
  @override
  final HttpHeaders headers;
  @override
  final int statusCode, contentLength;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.response);
  final _Response response;
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
}

class _Client extends Fake implements HttpClient {
  _Client(this.response);
  final _Response response;
  final requested = <Uri>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    return _Request(response);
  }

  @override
  void close({bool force = false}) => closed = true;
}

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
    'picture redirects reject non-HTTPS and credential-bearing URLs',
    () async {
      expect(
        () => accountAvatarUri('http://platform.deepseek.com/picture'),
        throwsFormatException,
      );
      await expectLater(
        fetchAccountAvatar('https://token@platform.deepseek.com/picture'),
        throwsFormatException,
      );
      await expectLater(
        fetchAccountAvatar('data:text/html;base64,AAA'),
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
    'fresh profile retries a failed picture without duplicating a load',
    () async {
      final requests = <Completer<Uint8List>>[];
      final loader = AccountAvatarLoader(
        fetch: (_) {
          final pending = Completer<Uint8List>();
          requests.add(pending);
          return pending.future;
        },
      );
      addTearDown(loader.dispose);
      const url = 'https://example.test/avatar';
      loader.setUrl(url, retryFailed: true);
      loader.setUrl(url, retryFailed: true);
      expect(requests, hasLength(1));
      requests.single.completeError(StateError('offline'));
      await Future<void>.delayed(Duration.zero);
      loader.setUrl(url, retryFailed: true);
      expect(requests, hasLength(2));
      requests.last.complete(_png);
      await Future<void>.delayed(Duration.zero);
      final loaded = loader.snapshot;
      loader.setUrl(url, retryFailed: true);
      expect(requests, hasLength(2));
      expect(loader.snapshot, same(loaded));
    },
  );

  testWidgets('profile source formats produce a bounded real picture', (
    tester,
  ) async {
    final observed = await tester.runAsync(() async {
      final results = <String, Object>{};
      final sources = {
        'embedded-raster': 'data:image/png;base64,${base64Encode(_png)}',
        'embedded-vector': Uri.dataFromString(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
          '<rect width="24" height="24" fill="#407cff"/></svg>',
          mimeType: 'image/svg+xml',
          encoding: utf8,
        ).toString(),
      };
      for (final entry in sources.entries) {
        final bytes = await fetchAccountAvatar(entry.value);
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          try {
            results[entry.key] = {
              'width': frame.image.width,
              'height': frame.image.height,
            };
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      }
      for (final type in [null, 'application/octet-stream', 'image/png']) {
        final client = _Client(_Response(_Headers(type), bytes: _png));
        final bytes = await HttpOverrides.runZoned(
          () => fetchAccountAvatar('http://images.example.test/avatar'),
          createHttpClient: (_) => client,
        );
        results[type ?? 'no-content-type'] = {
          'scheme': client.requested.single.scheme,
          'decoded': bytes.length == _png.length,
          'closed': client.closed,
        };
      }
      return results;
    });
    expect(
      observed,
      jsonDecode(
        File('test/fixtures/account_avatar.expected.json').readAsStringSync(),
      ),
    );
  });

  testWidgets('invalid picture data and downgrade redirects retain fallback', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final client = _Client(
        _Response(
          _Headers('image/png', 'http://images.example.test/a'),
          statusCode: 302,
        ),
      );
      await HttpOverrides.runZoned(() async {
        await expectLater(
          fetchAccountAvatar('https://example.test/avatar'),
          throwsFormatException,
        );
      }, createHttpClient: (_) => client);
      expect(client.requested, hasLength(1));
      expect(client.closed, isTrue);
      await expectLater(
        fetchAccountAvatar('data:image/png;base64,bm90IGEgcGljdHVyZQ=='),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        decodeAccountAvatar(Uint8List(accountAvatarByteLimit + 1)),
        throwsFormatException,
      );
      await expectLater(
        fetchAccountAvatar('data:image/svg+xml,%3Csvg%3Ebroken'),
        throwsA(anything),
      );
    });
  });

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
