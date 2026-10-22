import 'package:dsh_android/browser_url.dart';
import 'package:dsh_android/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote pages exclude application origins and unsafe schemes', () {
    final runtime = RuntimeController()
      ..phase = 'ready'
      ..web = {'phase': 'listening', 'host': '192.168.1.20', 'port': 3080};
    addTearDown(runtime.dispose);
    final origin = BrowserLocalOrigin.fromRuntime(runtime);
    expect(origin.port, 3080);
    expect(
      browserAddress('example.org', origin).toString(),
      'https://example.org',
    );
    for (final value in [
      'file:///private.txt',
      'content://media/a',
      'data:text/html,hello',
      'javascript:alert(1)',
      'https://user:secret@example.org/',
      'https://appassets.androidplatform.net/document/',
      'http://127.0.0.1:3080/',
      'http://localhost:3080/',
      'http://192.168.1.20:3080/',
      'http://192.168.1.20:4040/',
      'http://localhost:4040/',
      'http://10.0.0.1/',
      'https://[::1]/',
      'http://2130706433/',
      'http://printer.local/',
      'https://example.org/ bad',
    ]) {
      expect(browserAddress(value, origin), isNull, reason: value);
    }
  });

  test('unknown listener status denies every loopback port', () {
    final runtime = RuntimeController()
      ..phase = 'ready'
      ..web = {'phase': 'unknown', 'host': null, 'port': 3080};
    addTearDown(runtime.dispose);
    final origin = BrowserLocalOrigin.fromRuntime(runtime);
    expect(origin.port, isNull);
    expect(browserAddress('http://localhost:4040/', origin), isNull);
    expect(browserAddress('https://example.org/', origin), isNotNull);
  });

  test('confirmed disabled listener still refuses device-local addresses', () {
    final runtime = RuntimeController()
      ..phase = 'ready'
      ..web = {'phase': 'disabled', 'host': null, 'port': 3080};
    addTearDown(runtime.dispose);
    final origin = BrowserLocalOrigin.fromRuntime(runtime);
    expect(origin.port, 0);
    expect(browserAddress('http://localhost:3080/', origin), isNull);
  });
}
