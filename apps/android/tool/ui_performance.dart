import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dsh_android/main.dart' show ChatPage;
import 'package:dsh_android/ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_perf_fixture.dart';

/// Use an isolated Flutter host with a path dependency on dsh_android.
/// This entry point does not start the native Agent or use personal data.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _PerformanceApp());
}

class _PerformanceApp extends StatefulWidget {
  const _PerformanceApp();
  @override
  State<_PerformanceApp> createState() => _PerformanceAppState();
}

class _PerformanceAppState extends State<_PerformanceApp> {
  final runtime = UiPerfRuntime();
  final timings = <FrameTiming>[];
  final reports = <Map<String, dynamic>>[];
  bool ripple = false;
  bool measuring = false;
  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(record);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(run()));
  }

  void record(List<FrameTiming> batch) {
    if (measuring) timings.addAll(batch);
  }

  int percentile(List<int> values, double percentile) {
    if (values.isEmpty) return 0;
    values.sort();
    return values[((values.length - 1) * percentile).round()];
  }

  Future<void> run() async {
    // ignore: avoid_print
    print('DSH_UI_PERF_START');
    for (final scenario in ['tasks', 'live', 'tools', 'idle-ripple']) {
      if (!mounted) return;
      setState(() => ripple = scenario == 'idle-ripple');
      void tick(int i) => switch (scenario) {
        'tasks' => runtime.taskTick(i),
        'live' => runtime.liveTick(i),
        'tools' => runtime.toolsTick(),
        _ => null,
      };
      for (var i = 0; i < 45; i++) {
        tick(i);
        SchedulerBinding.instance.scheduleFrame();
        await SchedulerBinding.instance.endOfFrame;
      }
      timings.clear();
      final rssBefore = ProcessInfo.currentRss;
      measuring = true;
      final watch = Stopwatch()..start();
      for (var i = 0; i < 240; i++) {
        tick(i + 45);
        SchedulerBinding.instance.scheduleFrame();
        await SchedulerBinding.instance.endOfFrame;
      }
      watch.stop();
      // Outside the timed workload: drain the engine's batched frame reports.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      measuring = false;
      if (!mounted) return;
      final build = timings.map((f) => f.buildDuration.inMicroseconds).toList();
      final raster = timings
          .map((f) => f.rasterDuration.inMicroseconds)
          .toList();
      final rate = View.of(context).display.refreshRate;
      final budget = 1000000 / rate;
      final report = {
        'scenario': scenario,
        'mode': 'profile',
        'updates': 240,
        'frames': timings.length,
        'refreshRate': rate,
        'wallMicros': watch.elapsedMicroseconds,
        'buildP50': percentile(build, .5),
        'buildP95': percentile(build, .95),
        'rasterP50': percentile(raster, .5),
        'rasterP95': percentile(raster, .95),
        'overBudget': timings
            .where(
              (f) =>
                  f.buildDuration.inMicroseconds > budget ||
                  f.rasterDuration.inMicroseconds > budget,
            )
            .length,
        'rssBefore': rssBefore,
        'rssAfter': ProcessInfo.currentRss,
        'peakRss': ProcessInfo.maxRss,
        'requests': runtime.requests,
      };
      // ignore: avoid_print
      print('DSH_UI_PERF ${jsonEncode(report)}');
      reports.add(report);
      if (Platform.isAndroid) {
        // This path belongs only to the disposable diagnostic host. File
        // output survives devices that suppress Flutter's logcat messages.
        final directory = Directory(
          '/sdcard/Android/data/com.minnnng.dsh_ui_perf/files',
        );
        await directory.create(recursive: true);
        await File('${directory.path}/ui-performance.json').writeAsString(
          jsonEncode({
            'complete': scenario == 'idle-ripple',
            'reports': reports,
          }),
        );
      }
    }
    // ignore: avoid_print
    print('DSH_UI_PERF_DONE');
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: pocketTheme(Brightness.dark),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: !ripple),
      child: LiquidGlassScope(
        enabled: true,
        quality: LiquidGlassQuality.ultra,
        child: LiquidGlassHost(enabled: true, child: child!),
      ),
    ),
    home: ChatPage(runtime: runtime),
  );

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(record);
    runtime.dispose();
    super.dispose();
  }
}
