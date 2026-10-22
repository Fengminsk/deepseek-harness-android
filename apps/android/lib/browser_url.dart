import 'runtime.dart';

/// The current listener identity is retained for the direct-address check.
class BrowserLocalOrigin {
  const BrowserLocalOrigin({this.port, this.host});
  final int? port;
  final String? host;

  factory BrowserLocalOrigin.fromRuntime(RuntimeController runtime) {
    final web = runtime.web;
    if (!runtime.ready ||
        web['phase'] == 'unknown' ||
        web['phase'] == 'starting') {
      return const BrowserLocalOrigin();
    }
    if (web['phase'] == 'disabled' ||
        web['phase'] == 'waiting-network' ||
        web['phase'] == 'failed') {
      return const BrowserLocalOrigin(port: 0);
    }
    if (web['phase'] != 'listening') return const BrowserLocalOrigin();
    final port = web['port'];
    if (port is! int || port < 1024 || port > 65535) {
      return const BrowserLocalOrigin();
    }
    return BrowserLocalOrigin(
      port: port,
      host: web['host'] is String ? web['host'] as String : null,
    );
  }

  Map<String, Object?> get wire => {
    'applicationPort': port,
    'applicationHost': host,
  };

  @override
  bool operator ==(Object other) =>
      other is BrowserLocalOrigin && port == other.port && host == other.host;
  @override
  int get hashCode => Object.hash(port, host);
}

/// Parse a direct address before handing it to the external browser. Redirects
/// belong to that browser; this App never loads remote pages in its WebView.
Uri? browserAddress(String input, BrowserLocalOrigin origin) {
  final value = input.trim();
  if (value.isEmpty ||
      value.length > 16 * 1024 ||
      RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
    return null;
  }
  final explicit = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:(?!\d+(?:[/?#]|$))')
      .hasMatch(value);
  final uri = Uri.tryParse(explicit ? value : 'https://$value');
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme.toLowerCase()) ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
  final local =
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      host.endsWith('.internal') ||
      host.endsWith('.home.arpa') ||
      host == 'localdomain' ||
      host.endsWith('.localdomain') ||
      RegExp(r'^[0-9.]+$').hasMatch(host) ||
      RegExp(r'^0x[0-9a-f]+$').hasMatch(host) ||
      host.contains(':');
  if (host == 'appassets.androidplatform.net' || local) return null;
  if (origin.host != null && host == origin.host!.toLowerCase()) {
    return null;
  }
  return uri;
}
