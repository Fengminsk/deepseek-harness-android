import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'network_proxy.dart';

typedef AccountAvatarFetch = Future<Uint8List> Function(String url);
const accountAvatarByteLimit = 2 * 1024 * 1024;

enum AccountAvatarStatus { loading, ready, failed }

/// Diagnostic output contains source categories only, never account fields,
/// complete URLs, image data or exception messages.
void reportAccountAvatarProfile(Map<String, dynamic>? profile) {
  final source = profile?['avatarUrl'];
  _avatarDiagnostic('profile', {
    'field': profile == null
        ? 'no-profile'
        : !profile.containsKey('avatarUrl')
        ? 'missing'
        : source == null
        ? 'null'
        : source is! String
        ? 'invalid-type'
        : source.trim().isEmpty
        ? 'empty'
        : 'present',
    if (source is String && source.isNotEmpty) ..._avatarSource(source),
  });
}

Map<String, String> _avatarSource(String source) {
  final uri = Uri.tryParse(source);
  final scheme = uri?.scheme;
  return {
    'scheme': switch (scheme) {
      null => 'invalid',
      '' => 'relative',
      'https' || 'http' || 'data' => scheme,
      _ => 'other',
    },
    'host': switch (uri?.host) {
      'platform.deepseek.com' || 'chat.deepseek.com' => 'deepseek',
      'thirdwx.qlogo.cn' || 'wx.qlogo.cn' => 'wechat',
      'q.qlogo.cn' => 'qq',
      'gravatar.com' ||
      'www.gravatar.com' ||
      'secure.gravatar.com' => 'gravatar',
      null || '' => 'none',
      _ => 'redacted',
    },
  };
}

String _avatarContentType(String? value) => switch (value) {
  null => 'missing',
  'image/png' ||
  'image/jpeg' ||
  'image/webp' ||
  'image/gif' ||
  'image/svg+xml' ||
  'image/avif' ||
  'image/bmp' ||
  'application/octet-stream' ||
  'text/html' ||
  'application/json' => value,
  _ => 'other',
};

String? _avatarResponseType(HttpHeaders headers) {
  try {
    return headers.contentType?.mimeType;
  } on FormatException {
    // A malformed CDN header does not change whether the body is an image.
    return 'invalid';
  } on HttpException {
    // Dart's MIME parser also reports unterminated parameters as HTTP errors.
    return 'invalid';
  }
}

String _avatarFailure(Object failure) => switch (failure) {
  TimeoutException() => 'timeout',
  HandshakeException() => 'tls',
  SocketException() => 'network',
  HttpException() => 'http',
  FormatException() => 'format',
  _ => 'other',
};

void _avatarDiagnostic(String event, Map<String, Object?> fields) {
  debugPrint('[account-avatar] ${jsonEncode({'event': event, ...fields})}');
}

/// One image observation belongs to one profile URL and one load attempt.
class AccountAvatarSnapshot {
  const AccountAvatarSnapshot(this.url, this.status, [this.bytes]);

  final String url;
  final AccountAvatarStatus status;
  final Uint8List? bytes;
}

/// Owns the profile picture for both the account page and the sidebar.
/// No credential is passed to the image request or retained with the picture.
class AccountAvatarLoader extends ChangeNotifier {
  AccountAvatarLoader({AccountAvatarFetch? fetch})
    : _fetch = fetch ?? fetchAccountAvatar;

  final AccountAvatarFetch _fetch;
  AccountAvatarSnapshot? _snapshot;
  AccountAvatarSnapshot? get snapshot => _snapshot;
  int _generation = 0;
  bool _disposed = false;

  /// Changed sources load once; absent sources clear the picture. A successful
  /// profile refresh may retry a failed source without duplicating a live load.
  void setUrl(String? url, {bool retryFailed = false}) {
    if (_disposed) return;
    final next = url?.trim();
    if (next == _snapshot?.url || (next == null && _snapshot == null)) {
      if (retryFailed) retry();
      return;
    }
    if (next == null || next.isEmpty) {
      clear();
      return;
    }
    _load(next);
  }

  void retry() {
    if (_disposed || _snapshot?.status != AccountAvatarStatus.failed) return;
    _load(_snapshot!.url);
  }

  /// A rendered image can fail even after the isolated download decoded.
  /// Only the exact currently displayed attempt may replace the picture.
  void renderedImageFailed(AccountAvatarSnapshot snapshot) {
    if (_disposed ||
        !identical(snapshot, _snapshot) ||
        snapshot.status != AccountAvatarStatus.ready) {
      return;
    }
    _avatarDiagnostic('render-failed', _avatarSource(snapshot.url));
    _snapshot = AccountAvatarSnapshot(snapshot.url, AccountAvatarStatus.failed);
    notifyListeners();
  }

  void clear() {
    if (_disposed) return;
    _generation++;
    if (_snapshot == null) return;
    _snapshot = null;
    notifyListeners();
  }

  void _load(String url) {
    final generation = ++_generation;
    _snapshot = AccountAvatarSnapshot(url, AccountAvatarStatus.loading);
    notifyListeners();
    unawaited(() async {
      try {
        _avatarDiagnostic('load', _avatarSource(url));
        final bytes = await _fetch(url);
        if (_disposed || generation != _generation) return;
        _avatarDiagnostic('ready', {'bytes': bytes.length});
        _snapshot = AccountAvatarSnapshot(
          url,
          AccountAvatarStatus.ready,
          bytes,
        );
      } catch (failure) {
        if (_disposed || generation != _generation) return;
        _avatarDiagnostic('failed', {'category': _avatarFailure(failure)});
        _snapshot = AccountAvatarSnapshot(url, AccountAvatarStatus.failed);
      }
      notifyListeners();
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _snapshot = null;
    super.dispose();
  }
}

/// No credentials, cookies or non-HTTPS endpoints enter the picture request.
Uri accountAvatarUri(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Unsupported account picture URL');
  }
  return uri;
}

/// Public profile pictures may be embedded images or network URLs. Legacy HTTP
/// sources are upgraded before the request; redirects cannot downgrade HTTPS.
/// Network loads capture one saved route for their entire redirect chain. The
/// optional factories replace platform reads and client creation in tests.
Future<Uint8List> fetchAccountAvatar(
  String url, {
  Future<NetworkProxyRoute> Function() readRoute = readNetworkProxyRoute,
  HttpClient Function(NetworkProxyRoute) clientFactory = createProxyHttpClient,
}) async {
  final source = Uri.tryParse(url);
  if (source?.scheme == 'data') {
    if (url.length > accountAvatarByteLimit * 3 + 100) {
      throw const FormatException('Account picture is too large');
    }
    final data = UriData.parse(url);
    _avatarDiagnostic('embedded', {'type': _avatarContentType(data.mimeType)});
    if (!const {
      'image/png',
      'image/jpeg',
      'image/webp',
      'image/gif',
      'image/svg+xml',
    }.contains(data.mimeType)) {
      throw const FormatException('Unsupported account picture format');
    }
    return decodeAccountAvatar(data.contentAsBytes(), type: data.mimeType);
  }
  var uri = accountAvatarUri(
    source?.scheme == 'http'
        ? source!.replace(scheme: 'https').toString()
        : url,
  );
  late final HttpClient client;
  try {
    final route = await readRoute();
    client = clientFactory(route)
      ..connectionTimeout = const Duration(seconds: 8);
  } catch (failure) {
    _avatarDiagnostic('request-failed', {
      'stage': 'proxy-configuration',
      'category': _avatarFailure(failure),
    });
    rethrow;
  }
  var stage = 'connect';
  try {
    HttpClientResponse? response;
    for (var redirects = 0; redirects <= 3; redirects++) {
      stage = 'connect';
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      stage = 'headers';
      response = await request.close().timeout(const Duration(seconds: 15));
      _avatarDiagnostic('response', {
        ..._avatarSource(uri.toString()),
        'status': response.statusCode,
        'type': _avatarContentType(_avatarResponseType(response.headers)),
      });
      if (!{
        HttpStatus.movedPermanently,
        HttpStatus.found,
        HttpStatus.seeOther,
        HttpStatus.temporaryRedirect,
        HttpStatus.permanentRedirect,
      }.contains(response.statusCode)) {
        break;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      stage = 'redirect';
      if (redirects == 3 || location == null) {
        throw const FormatException(
          'Account picture redirected too many times',
        );
      }
      uri = accountAvatarUri(uri.resolve(location).toString());
      await response.drain<void>().timeout(const Duration(seconds: 2));
    }
    final loaded = response;
    if (loaded == null) {
      throw const FormatException('Missing account picture');
    }
    final type = _avatarResponseType(loaded.headers);
    stage = 'response';
    // The public avatar CDN returns nonstandard MIME values for valid images.
    // Only a bounded, successfully decoded body qualifies as a picture.
    if (loaded.statusCode != HttpStatus.ok ||
        loaded.contentLength > accountAvatarByteLimit) {
      throw const FormatException('Account picture is unavailable');
    }
    stage = 'body';
    final bytes = await readAccountAvatarBytes(loaded)
        .timeout(const Duration(seconds: 15));
    stage = 'decode';
    return await decodeAccountAvatar(bytes, type: type);
  } catch (failure) {
    _avatarDiagnostic('request-failed', {
      'stage': stage,
      'category': _avatarFailure(failure),
    });
    rethrow;
  } finally {
    client.close(force: true);
  }
}

bool _avatarHasSvgPrefix(Uint8List bytes) {
  final prefix = utf8.decode(
    Uint8List.sublistView(bytes, 0, bytes.length < 1024 ? bytes.length : 1024),
    allowMalformed: true,
  );
  return RegExp(
    r'^\uFEFF?\s*(?:<\?xml[\s\S]*?\?>\s*)?(?:<!--[\s\S]*?-->\s*)*<svg(?:\s|>)',
  ).hasMatch(prefix);
}

/// Validate raster data and rasterize SVG once for both account surfaces.
/// The SVG compiler accepts embedded images only; it does not fetch references.
Future<Uint8List> decodeAccountAvatar(Uint8List bytes, {String? type}) async {
  if (bytes.isEmpty || bytes.length > accountAvatarByteLimit) {
    throw const FormatException('Account picture is empty or too large');
  }
  final svg =
      _avatarHasSvgPrefix(bytes) ||
      (type == 'image/svg+xml' &&
          bytes.length <= 256 * 1024 &&
          utf8.decode(bytes, allowMalformed: true).contains('<svg'));
  if (svg) {
    if (bytes.length > 256 * 1024) {
      throw const FormatException('Unsupported account picture SVG');
    }
    final info = await vg.loadPicture(SvgBytesLoader(bytes), null);
    try {
      if (info.size.isEmpty || !info.size.isFinite) {
        throw const FormatException('Account picture has no image area');
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final scale =
          128 /
          (info.size.width > info.size.height
              ? info.size.width
              : info.size.height);
      canvas.translate(
        (128 - info.size.width * scale) / 2,
        (128 - info.size.height * scale) / 2,
      );
      canvas.scale(scale);
      canvas.drawPicture(info.picture);
      final picture = recorder.endRecording();
      try {
        final image = await picture.toImage(128, 128);
        try {
          final encoded = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (encoded == null) {
            throw const FormatException('Account picture could not be decoded');
          }
          return encoded.buffer.asUint8List(
            encoded.offsetInBytes,
            encoded.lengthInBytes,
          );
        } finally {
          image.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      info.picture.dispose();
    }
  }
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: 128,
    targetHeight: 128,
    allowUpscaling: false,
  );
  try {
    final frame = await codec.getNextFrame();
    frame.image.dispose();
  } finally {
    codec.dispose();
  }
  return bytes;
}

/// Enforce the cap while bytes arrive, including when Content-Length is absent.
Future<Uint8List> readAccountAvatarBytes(Stream<List<int>> response) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    if (builder.length + chunk.length > accountAvatarByteLimit) {
      throw const FormatException('Account picture is too large');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

class AccountAvatar extends StatelessWidget {
  const AccountAvatar({
    super.key,
    required this.snapshot,
    required this.onImageError,
    this.size = 30,
  });

  final AccountAvatarSnapshot? snapshot;
  final ValueChanged<AccountAvatarSnapshot> onImageError;
  final double size;

  @override
  Widget build(BuildContext context) {
    final shown = snapshot;
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child:
            shown?.status == AccountAvatarStatus.ready && shown?.bytes != null
            ? Image.memory(
                shown!.bytes!,
                key: ValueKey(shown),
                fit: BoxFit.cover,
                cacheWidth: 128,
                cacheHeight: 128,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    onImageError(shown);
                  });
                  return const Icon(Icons.person_outline_rounded);
                },
              )
            : const Icon(Icons.person_outline_rounded),
      ),
    );
  }
}
