/// Owns the main-process foreground sync service from the Dart side.
///
/// The service keeps the process (and therefore the Flutter UI isolate and the
/// remote WebSocket) alive while the App is in the background, so
/// `session.follow` frames and `remote.*` notifications keep arriving and the
/// existing notification dispatcher can post system notifications.
///
/// The service must be started while the App is in the foreground (Android 12+
/// forbids background FGS starts): callers start it when a remote connection is
/// ready and the conversation page is open, and stop it when that page is
/// disposed or the connection reaches a terminal state.
library;

import 'package:flutter/services.dart';

/// Starts/stops background synchronization. Tests inject a fake implementation.
abstract class RemoteSyncLifecycle {
  /// Ask the platform to keep the process alive in the background.
  Future<void> start();

  /// Stop the background service and remove its ongoing notification.
  Future<void> stop();
}

/// `dsh/runtime` implementation: `remote.sync.start` / `remote.sync.stop`.
class MethodChannelRemoteSyncLifecycle implements RemoteSyncLifecycle {
  MethodChannelRemoteSyncLifecycle({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/runtime');

  final MethodChannel _channel;
  bool _started = false;

  /// Whether [start] succeeded in this process; the platform service also
  /// reports its own state through `remote.sync.status`.
  bool get started => _started;

  @override
  Future<void> start() async {
    if (_started) return;
    try {
      await _channel.invokeMethod<bool>('remote.sync.start');
      _started = true;
    } on Object {
      // Older App shells or a missing channel: foreground sync stays off, the
      // conversation itself keeps working.
      _started = false;
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    try {
      await _channel.invokeMethod<bool>('remote.sync.stop');
    } on Object {
      // Stopping is best effort; the service also stops with the Activity.
    }
  }
}
