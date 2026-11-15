// 真机帧耗时测量入口：包一层生产 App，把每帧的 build/raster 耗时按秒汇总成
// 一行 `DSH_FRAME {...}` 输出到 logcat，供 tool/device-frame-profile.mjs 采集。
//
// 只在显式 `--target=lib/main_perf.dart` 的 profile 构建里使用；普通 `lib/main.dart`
// 构建不含任何统计代码，生产行为零影响。测量场景由驱动脚本用 adb 输入驱动，
// 脚本按时间窗口把采样归属到场景并对照 16.67 ms（60 fps）帧预算判定。

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'main.dart' as app;

/// 测量入口：先装帧统计回调，再启动与生产完全相同的 App。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _FrameStats.install();
  app.main();
}

/// 一秒钟一批的帧耗时统计。
///
/// 输出格式固定为单行 JSON，字段：`at`（窗口结束的设备毫秒时间戳）、`n`（帧数）、
/// `b`/`r`/`s`（build、raster、totalSpan 的微秒数组）。驱动脚本据此计算分位数与
/// 超预算比例；窗口内数组长度受刷新率约束（60 Hz 约 60 项），logcat 一行放得下。
class _FrameStats {
  _FrameStats._();

  static const Duration _window = Duration(seconds: 1);

  static final List<FrameTiming> _frames = <FrameTiming>[];
  static Timer? _timer;

  /// 安装回调与定时上报；重复调用无副作用。
  static void install() {
    if (_timer != null) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(_window, (_) => _flush());
    // 前台/profile 下必须可见：驱动脚本用这一行确认统计已就绪。
    debugPrint('DSH_FRAME_READY');
  }

  static void _onTimings(List<FrameTiming> batch) {
    _frames.addAll(batch);
  }

  static void _flush() {
    if (_frames.isEmpty) return;
    final build = <int>[];
    final raster = <int>[];
    final total = <int>[];
    for (final frame in _frames) {
      build.add(frame.buildDuration.inMicroseconds);
      raster.add(frame.rasterDuration.inMicroseconds);
      total.add(frame.totalSpan.inMicroseconds);
    }
    _frames.clear();
    debugPrint(
      'DSH_FRAME ${jsonEncode(<String, Object>{
        'at': DateTime.now().millisecondsSinceEpoch,
        'n': build.length,
        'b': build,
        'r': raster,
        's': total,
      })}',
    );
  }
}
