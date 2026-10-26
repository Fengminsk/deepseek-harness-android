import 'dart:convert';
import 'dart:io';

import 'package:dsh_android/chat_messages.dart';
import 'package:dsh_android/main.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../tool/ui_perf_fixture.dart';

void main() {
  for (final scenario in ['tasks', 'live', 'tools']) {
    testWidgets('bounded chat rebuilding for $scenario updates', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final runtime = UiPerfRuntime();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        runtime.dispose();
        await runtime.control.done;
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: LiquidGlassScope(
              enabled: true,
              quality: LiquidGlassQuality.standard,
              child: LiquidGlassHost(enabled: true, child: child!),
            ),
          ),
          home: ChatPage(runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      void tick(int i) => switch (scenario) {
        'live' => runtime.liveTick(i),
        'tools' => runtime.toolsTick(),
        _ => runtime.taskTick(i),
      };
      for (var i = 0; i < 10; i++) {
        tick(i);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      var timelineBuilds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is ChatTimeline) timelineBuilds++;
      };
      final memoryBefore = ProcessInfo.currentRss;
      final samples = <int>[];
      try {
        for (var i = 0; i < 100; i++) {
          final watch = Stopwatch()..start();
          tick(i + 10);
          await tester.pump();
          watch.stop();
          samples.add(watch.elapsedMicroseconds);
        }
      } finally {
        debugOnRebuildDirtyWidget = previous;
      }
      samples.sort();
      final report = {
        'scenario': scenario,
        'events': 2000,
        'updates': 100,
        'timelineBuilds': timelineBuilds,
        'p50Micros': samples[50],
        'p95Micros': samples[95],
        'rssBefore': memoryBefore,
        'rssAfter': ProcessInfo.currentRss,
        'peakRss': ProcessInfo.maxRss,
        'requests': runtime.requests,
      };
      // Debug-host evidence; device profile timings are measured separately.
      debugPrint('UI_PERF ${jsonEncode(report)}');
      final folder = Platform.environment['DSH_UI_PERF_OUTPUT'];
      if (folder != null) {
        await tester.runAsync(() async {
          await Directory(folder).create(recursive: true);
          await File('$folder/$scenario.json')
              .writeAsString(jsonEncode(report));
        });
      }
      expect(tester.takeException(), isNull);
      if (scenario == 'tasks' || scenario == 'tools') {
        expect(timelineBuilds, 0);
      }
      if (scenario == 'live') {
        expect(timelineBuilds, greaterThan(0));
        expect(find.textContaining('进度 109'), findsWidgets);
      }
    });
  }
}
