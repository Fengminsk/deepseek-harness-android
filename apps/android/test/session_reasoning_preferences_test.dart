import 'dart:convert';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_reasoning_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default intent uses a session-scoped native record and can be cleared',
    () async {
      final records = <String, String>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(RuntimeController.channel, (call) async {
            final args = call.arguments as Map;
            final id = args['sessionId'] as String;
            switch (call.method) {
              case 'session.reasoning.load':
                return records[id];
              case 'session.reasoning.save':
                final selection = args['selection'] as String?;
                if (selection == null) {
                  records.remove(id);
                } else {
                  records[id] = selection;
                }
                return null;
              default:
                throw MissingPluginException(call.method);
            }
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(RuntimeController.channel, null),
      );
      const preferences = SessionReasoningPreferences();
      const selected = {
        'provider': 'deepseek-account',
        'model': 'deepseek-flash',
        'reasoningEffort': 'high',
      };
      expect(await preferences.load('A'), isNull);
      await preferences.save('A', selected);
      expect(await preferences.load('A'), selected);
      expect(await preferences.load('B'), isNull);
      records['B'] = jsonEncode({'provider': 'x'});
      await expectLater(preferences.load('B'), throwsFormatException);
      await preferences.save('A', null);
      expect(await preferences.load('A'), isNull);
    },
  );
}
