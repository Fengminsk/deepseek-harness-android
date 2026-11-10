import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/account_avatar.dart';
import 'package:dsh_android/network_proxy.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

Future<Uint8List> _fetchAvatar(String url) => fetchAccountAvatar(
  url,
  readRoute: () async => const NetworkProxyRoute(mode: 'system'),
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
  final redirects = <_Response>[];
  VoidCallback? onRequest;
  bool closed = false;
  @override
  Duration? connectionTimeout;
  String Function(Uri)? proxy;
  @override
  set findProxy(String Function(Uri)? value) => proxy = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    onRequest?.call();
    return _Request(redirects.isEmpty ? response : redirects.removeAt(0));
  }

  @override
  void close({bool force = false}) => closed = true;
}

void main() {
  testWidgets(
    'the default avatar client reads the saved native proxy configuration',
    (tester) async {
      var reads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          expect(call.method, 'network.proxy.route');
          reads++;
          return jsonEncode({
            'mode': 'system',
            'url': 'http://127.0.0.1:8080',
          });
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.runAsync(() async {
        final client = _Client(_Response(_Headers('text/plain'), bytes: _png));
        await HttpOverrides.runZoned(
          () => fetchAccountAvatar('https://example.test/avatar'),
          createHttpClient: (_) => client,
        );
        expect(reads, 1);
        expect(client.proxy!(client.requested.single), 'PROXY 127.0.0.1:8080');
        expect(client.closed, isTrue);
      });
    },
  );

  testWidgets(
    'avatar requests retain one proxy route through redirects and read the next saved route',
    (tester) async {
      await tester.runAsync(() async {
        var selected = const NetworkProxyRoute(
          mode: 'local',
          url: 'http://127.0.0.1:7897',
        );
        var reads = 0;
        Future<NetworkProxyRoute> read() async {
          reads++;
          return selected;
        }

        final proxied =
            _Client(_Response(_Headers('binary/octet-stream'), bytes: _png))
              ..redirects.add(
                _Response(
                  _Headers(null, 'https://cdn.example.test/avatar'),
                  statusCode: 302,
                ),
              )
              ..onRequest = () =>
                  selected = const NetworkProxyRoute(mode: 'system');
        await HttpOverrides.runZoned(
          () => fetchAccountAvatar(
            'https://example.test/avatar',
            readRoute: read,
          ),
          createHttpClient: (_) => proxied,
        );
        expect(reads, 1);
        expect(proxied.requested, hasLength(2));
        for (final uri in proxied.requested) {
          expect(proxied.proxy!(uri), 'PROXY 127.0.0.1:7897');
        }
        expect(proxied.closed, isTrue);
        final direct = _Client(_Response(_Headers('text/plain'), bytes: _png));
        await HttpOverrides.runZoned(
          () => fetchAccountAvatar(
            'https://example.test/avatar',
            readRoute: read,
          ),
          createHttpClient: (_) => direct,
        );
        expect(reads, 2);
        expect(direct.proxy!(direct.requested.single), 'DIRECT');
        expect(direct.closed, isTrue);
      });
    },
  );

  testWidgets(
    'unavailable proxy configuration fails without a direct request; embedded images remain local',
    (tester) async {
      await tester.runAsync(() async {
        var reads = 0, creations = 0;
        Future<NetworkProxyRoute> unavailable() async {
          reads++;
          throw MissingPluginException('fixture native channel unavailable');
        }

        HttpClient client(NetworkProxyRoute route) {
          creations++;
          return _Client(_Response(_Headers('image/png'), bytes: _png));
        }

        await expectLater(
          fetchAccountAvatar(
            'https://example.test/avatar',
            readRoute: unavailable,
            clientFactory: client,
          ),
          throwsA(isA<MissingPluginException>()),
        );
        expect(reads, 1);
        expect(creations, 0);
        final embedded = await fetchAccountAvatar(
          'data:image/png;base64,${base64Encode(_png)}',
          readRoute: unavailable,
          clientFactory: client,
        );
        expect(embedded, _png);
        expect(reads, 1);
        expect(creations, 0);
      });
    },
  );

  test('avatar diagnostics reveal categories without account or URL data', () async {
    final messages = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) messages.add(message);
    };
    final loader = AccountAvatarLoader(
      fetch: (_) async {
        throw const FormatException('private-error-token secret-name');
      },
    );
    try {
      reportAccountAvatarProfile({'name': 'secret-name'});
      reportAccountAvatarProfile({'avatarUrl': null});
      reportAccountAvatarProfile({'avatarUrl': ''});
      reportAccountAvatarProfile({
        'avatarUrl':
            'https://private-user.example.test/secret-path?token=private-query',
      });
      reportAccountAvatarProfile({
        'avatarUrl': 'data:image/png;base64,private-image',
      });
      final client = _Client(
        _Response(_Headers('private/private-content'), statusCode: 403),
      );
      await HttpOverrides.runZoned(() async {
        await expectLater(
          _fetchAvatar(
            'https://private-user.example.test/secret-path?token=private-query',
          ),
          throwsFormatException,
        );
      }, createHttpClient: (_) => client);
      loader.setUrl('https://private-user.example.test/secret-path');
      await Future<void>.delayed(Duration.zero);
      final records = messages
          .map(
            (line) =>
                jsonDecode(line.substring('[account-avatar] '.length)) as Map,
          )
          .toList();
      expect(records.take(3).map((record) => record['field']), [
        'missing',
        'null',
        'empty',
      ]);
      expect(records[3]['scheme'], 'https');
      expect(records[3]['host'], 'redacted');
      expect(
        records.singleWhere(
          (record) => record['event'] == 'response',
        )['status'],
        403,
      );
      expect(
        records.singleWhere((record) => record['event'] == 'response')['type'],
        'other',
      );
      expect(
        records.singleWhere(
          (record) => record['event'] == 'request-failed',
        )['stage'],
        'response',
      );
      expect(records.last, {'event': 'failed', 'category': 'format'});
      final output = messages.join('\n');
      for (final secret in [
        'secret-name',
        'private-user',
        'secret-path',
        'private-query',
        'private-image',
        'private-content',
        'private-error-token',
      ]) {
        expect(output, isNot(contains(secret)));
      }
    } finally {
      loader.dispose();
      debugPrint = previous;
    }
  });

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
        _fetchAvatar('https://token@platform.deepseek.com/picture'),
        throwsFormatException,
      );
      await expectLater(
        _fetchAvatar('data:text/html;base64,AAA'),
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
        final bytes = await _fetchAvatar(entry.value);
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
      for (final type in [
        null,
        'application/octet-stream',
        'binary/octet-stream',
        'text/plain',
        'image/png',
        'image/svg+xml',
        'invalid header',
        'image/png; charset="broken',
      ]) {
        final client = _Client(_Response(_Headers(type), bytes: _png));
        final bytes = await HttpOverrides.runZoned(
          () => _fetchAvatar('http://images.example.test/avatar'),
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

  testWidgets('unknown CDN MIME accepts SVG bytes without running a browser', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final source = utf8.encode(
        '\uFEFF <?xml version="1.0"?>\n<!-- avatar -->\n'
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
        '<rect width="24" height="24" fill="#407cff"/></svg>',
      );
      final client = _Client(_Response(_Headers('text/plain'), bytes: source));
      final bytes = await HttpOverrides.runZoned(
        () => _fetchAvatar('https://images.example.test/avatar'),
        createHttpClient: (_) => client,
      );
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        try {
          expect([frame.image.width, frame.image.height], [128, 128]);
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      expect(client.closed, isTrue);
    });
  });

  testWidgets(
    'HTTP 200 error pages fail image decoding and the size cap remains',
    (tester) async {
      await tester.runAsync(() async {
        for (final body in [
          utf8.encode(
            '<html><body>Image temporarily unavailable</body></html>',
          ),
          utf8.encode('{"error":"unavailable"}'),
        ]) {
          final client = _Client(
            _Response(_Headers('text/plain'), bytes: body),
          );
          await HttpOverrides.runZoned(() async {
            await expectLater(
              _fetchAvatar('https://images.example.test/avatar'),
              throwsA(isA<Exception>()),
            );
          }, createHttpClient: (_) => client);
          expect(client.closed, isTrue);
        }
        final client = _Client(
          _Response(
            _Headers('binary/octet-stream'),
            bytes: Uint8List(accountAvatarByteLimit + 1),
          ),
        );
        await HttpOverrides.runZoned(() async {
          await expectLater(
            _fetchAvatar('https://images.example.test/avatar'),
            throwsFormatException,
          );
        }, createHttpClient: (_) => client);
        expect(client.closed, isTrue);
      });
    },
  );

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
          _fetchAvatar('https://example.test/avatar'),
          throwsFormatException,
        );
      }, createHttpClient: (_) => client);
      expect(client.requested, hasLength(1));
      expect(client.closed, isTrue);
      await expectLater(
        _fetchAvatar('data:image/png;base64,bm90IGEgcGljdHVyZQ=='),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        decodeAccountAvatar(Uint8List(accountAvatarByteLimit + 1)),
        throwsFormatException,
      );
      await expectLater(
        _fetchAvatar('data:image/svg+xml,%3Csvg%3Ebroken'),
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
