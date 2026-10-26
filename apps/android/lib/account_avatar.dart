import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

typedef AccountAvatarFetch = Future<Uint8List> Function(String url);
const accountAvatarByteLimit = 2 * 1024 * 1024;

enum AccountAvatarStatus { loading, ready, failed }

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
        final bytes = await _fetch(url);
        if (_disposed || generation != _generation) return;
        _snapshot = AccountAvatarSnapshot(
          url,
          AccountAvatarStatus.ready,
          bytes,
        );
      } catch (_) {
        if (_disposed || generation != _generation) return;
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
Future<Uint8List> fetchAccountAvatar(String url) async {
  final source = Uri.tryParse(url);
  if (source?.scheme == 'data') {
    if (url.length > accountAvatarByteLimit * 3 + 100) {
      throw const FormatException('Account picture is too large');
    }
    final data = UriData.parse(url);
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
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    HttpClientResponse? response;
    for (var redirects = 0; redirects <= 3; redirects++) {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      response = await request.close().timeout(const Duration(seconds: 15));
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
    final type = loaded.headers.contentType?.mimeType;
    // Public CDN objects can omit Content-Type or use octet-stream. Decode the
    // bounded body before accepting it instead of rejecting valid pictures.
    if (loaded.statusCode != HttpStatus.ok ||
        (loaded.headers.contentType?.primaryType != 'image' &&
            type != null &&
            type != 'application/octet-stream') ||
        loaded.contentLength > accountAvatarByteLimit) {
      throw const FormatException('Account picture is unavailable');
    }
    final bytes = await readAccountAvatarBytes(loaded)
        .timeout(const Duration(seconds: 15));
    return await decodeAccountAvatar(bytes, type: type);
  } finally {
    client.close(force: true);
  }
}

/// Validate raster data and rasterize SVG once for both account surfaces.
/// The SVG compiler accepts embedded images only; it does not fetch references.
Future<Uint8List> decodeAccountAvatar(Uint8List bytes, {String? type}) async {
  if (bytes.isEmpty || bytes.length > accountAvatarByteLimit) {
    throw const FormatException('Account picture is empty or too large');
  }
  if (type == 'image/svg+xml') {
    if (bytes.length > 256 * 1024 ||
        !utf8.decode(bytes, allowMalformed: true).contains('<svg')) {
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
