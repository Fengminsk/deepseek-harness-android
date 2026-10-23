import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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

  void setUrl(String? url) {
    if (_disposed) return;
    final next = url?.trim();
    if (next == _snapshot?.url || (next == null && _snapshot == null)) return;
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

/// Bounded public-picture request. Each redirect is checked before sending the
/// next request, as Platform images may live on a separate HTTPS CDN.
Future<Uint8List> fetchAccountAvatar(String url) async {
  var uri = accountAvatarUri(url);
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
    if (loaded.statusCode != HttpStatus.ok ||
        loaded.headers.contentType?.primaryType != 'image' ||
        loaded.contentLength > accountAvatarByteLimit) {
      throw const FormatException('Account picture is unavailable');
    }
    final bytes = await readAccountAvatarBytes(loaded)
        .timeout(const Duration(seconds: 15));
    final codec = await ui
        .instantiateImageCodec(
          bytes,
          targetWidth: 128,
          targetHeight: 128,
          allowUpscaling: false,
        )
        .timeout(const Duration(seconds: 8));
    codec.dispose();
    return bytes;
  } finally {
    client.close(force: true);
  }
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
