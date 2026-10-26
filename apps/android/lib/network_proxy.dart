import 'dart:convert';
import 'dart:io';

import 'runtime.dart';

class NetworkProxyRoute {
  const NetworkProxyRoute({required this.mode, this.url, this.error});
  final String mode;
  final String? url, error;
  factory NetworkProxyRoute.fromJson(Json json) => NetworkProxyRoute(
    mode: json['mode'] as String,
    url: json['url'] as String?,
    error: json['error'] as String?,
  );
  String get identity => '$mode|$url|$error';
}

class NetworkProxyConfiguration {
  NetworkProxyConfiguration(Json json)
    : mode = json['mode'] as String,
      port = json['port'] as int,
      tool = json['tool'] as String? ?? '',
      route = NetworkProxyRoute.fromJson(json['route'] as Json),
      tools = (json['tools'] as List? ?? []).cast<Json>();
  final String mode, tool;
  final int port;
  final NetworkProxyRoute route;
  final List<Json> tools;
  Json get value => {'mode': mode, 'port': port, 'tool': tool};
}

/// Reads App-owned preferences; each caller owns its request's route snapshot.
class NetworkProxyPlatform {
  const NetworkProxyPlatform();
  static const preferenceTimeout = Duration(seconds: 5);

  Future<NetworkProxyConfiguration> read() async => NetworkProxyConfiguration(
    jsonDecode(
      await RuntimeController.channel
              .invokeMethod<String>('network.proxy.read')
              .timeout(preferenceTimeout) ??
          '{}',
    ) as Json,
  );

  Future<NetworkProxyConfiguration> save(Json value) async =>
      NetworkProxyConfiguration(
        jsonDecode(
          await RuntimeController.channel
                  .invokeMethod<String>('network.proxy.save', jsonEncode(value))
                  .timeout(preferenceTimeout) ??
              '{}',
        ) as Json,
      );

  Future<Json> test(Json value) async => jsonDecode(
    await RuntimeController.channel
            .invokeMethod<String>('network.proxy.test', jsonEncode(value))
            .timeout(const Duration(seconds: 18)) ??
        '{}',
  ) as Json;

  Future<void> openTool(String packageName) => RuntimeController.channel
      .invokeMethod<void>('network.proxy.openTool', packageName);

  /// Native transition admission refuses active Agent, terminal or job work.
  Future<void> apply() => RuntimeController.channel
      .invokeMethod<void>('restart')
      .timeout(const Duration(seconds: 25));
}

Future<NetworkProxyRoute> readNetworkProxyRoute() async =>
    NetworkProxyRoute.fromJson(
      jsonDecode(
        await RuntimeController.channel
                .invokeMethod<String>('network.proxy.route')
                .timeout(NetworkProxyPlatform.preferenceTimeout) ??
            '{}',
      ) as Json,
    );

HttpClient createProxyHttpClient(NetworkProxyRoute route) {
  if (route.error != null) throw StateError(route.error!);
  if (!const {'system', 'local'}.contains(route.mode) ||
      (route.mode == 'local' && route.url == null)) {
    throw const FormatException('代理路由未确认');
  }
  final endpoint = route.url == null ? null : Uri.parse(route.url!);
  if (endpoint != null &&
      (endpoint.scheme != 'http' ||
          endpoint.host.isEmpty ||
          !endpoint.hasPort ||
          endpoint.port < 1 ||
          endpoint.port > 65535 ||
          endpoint.userInfo.isNotEmpty)) {
    throw const FormatException('代理地址无效');
  }
  final client = HttpClient();
  client.findProxy = (uri) {
    if (endpoint == null ||
        const {'localhost', '127.0.0.1', '::1'}.contains(uri.host)) {
      return 'DIRECT';
    }
    final host = endpoint.host.contains(':')
        ? '[${endpoint.host}]'
        : endpoint.host;
    return 'PROXY $host:${endpoint.port}';
  };
  return client;
}

int checkedProxyPort(String text) {
  final port = int.tryParse(text.trim());
  if (port == null || port < 1 || port > 65535) {
    throw const FormatException('代理端口须为 1–65535');
  }
  return port;
}
