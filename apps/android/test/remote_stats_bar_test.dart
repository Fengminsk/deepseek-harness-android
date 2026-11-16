// 远程会话的底部统计条与详情弹层：分段显示、缺失隐藏、格式与弹层内容。
//
// 纯 widget 测试：读数直接构造 [RemoteSessionInsights]，不连接数据源；宽度由
// 宿主显式给定，因此「一行」与「折叠胶囊」两个分支都能稳定复现。

import 'package:dsh_android/remote_session_insights.dart';
import 'package:dsh_android/remote_stats_bar.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

RemoteSessionStats _stats({
  int turns = 0,
  int steps = 0,
  int llmMs = 0,
  int toolMs = 0,
  int ttftMs = 0,
  int ttftSteps = 0,
  int decodeMs = 0,
  int decodeTokens = 0,
}) => RemoteSessionStats(
  turns: turns,
  steps: steps,
  llmMs: llmMs,
  toolMs: toolMs,
  ttftMs: ttftMs,
  ttftSteps: ttftSteps,
  decodeMs: decodeMs,
  decodeTokens: decodeTokens,
);

RemoteTokenUsage _usage({
  int uncachedInputTokens = 0,
  int cacheReadTokens = 0,
  int cacheWriteTokens = 0,
  int outputTokens = 0,
}) => RemoteTokenUsage(
  uncachedInputTokens: uncachedInputTokens,
  cacheReadTokens: cacheReadTokens,
  cacheWriteTokens: cacheWriteTokens,
  outputTokens: outputTokens,
);

/// 一份与真实宿主探针读数同量级的完整读数。
RemoteSessionInsights _fullInsights() => RemoteSessionInsights(
  stats: _stats(
    turns: 20,
    steps: 23,
    llmMs: 57216,
    toolMs: 6723,
    ttftMs: 47690,
    ttftSteps: 23,
    decodeMs: 9526,
    decodeTokens: 1304,
  ),
  usage: _usage(
    uncachedInputTokens: 19162,
    cacheReadTokens: 385792,
    cacheWriteTokens: 0,
    outputTokens: 1304,
  ),
  pressure: const RemoteContextPressure(
    pressureTokens: 18999,
    projectedTokens: 19058,
    contextWindow: 1048576,
  ),
);

/// 把统计条放进 App 主题与可控宽度里，[onTap] 由测试决定是否打开弹层。
Widget _host({
  required RemoteSessionInsights insights,
  double width = 800,
  VoidCallback? onTap,
}) => MaterialApp(
  theme: pocketTheme(Brightness.light),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1)),
      child: Scaffold(
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: RemoteStatsBar(insights: insights, onTap: onTap),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  test('hasReadings 只认统计类读数，只有待办时不算', () {
    expect(RemoteStatsBar.hasReadings(RemoteSessionInsights.none), isFalse);
    expect(
      RemoteStatsBar.hasReadings(
        RemoteSessionInsights(
          todos: const <RemoteTodoItem>[
            RemoteTodoItem(content: '检查构建', status: RemoteTodoStatus.pending),
          ],
        ),
      ),
      isFalse,
    );
    expect(
      RemoteStatsBar.hasReadings(
        RemoteSessionInsights(stats: _stats(turns: 2, steps: 3)),
      ),
      isTrue,
    );
    expect(
      RemoteStatsBar.hasReadings(
        RemoteSessionInsights(usage: _usage(outputTokens: 5)),
      ),
      isTrue,
    );
    expect(
      RemoteStatsBar.hasReadings(
        const RemoteSessionInsights(
          pressure: RemoteContextPressure(contextWindow: 1048576),
        ),
      ),
      isFalse,
    );
    expect(
      RemoteStatsBar.hasReadings(
        const RemoteSessionInsights(
          pressure: RemoteContextPressure(
            pressureTokens: 500,
            contextWindow: 1000,
          ),
        ),
      ),
      isTrue,
    );
  });

  testWidgets('完整读数显示为一行三段，缓存命中与上下文用派生值', (tester) async {
    await tester.pumpWidget(_host(insights: _fullInsights()));

    expect(find.byKey(RemoteStatsBar.barKey), findsOneWidget);
    expect(find.byKey(RemoteStatsBar.lineKey), findsOneWidget);
    expect(find.byKey(RemoteStatsBar.capsuleKey), findsNothing);
    expect(find.text('轮 20 · 步 23'), findsOneWidget);
    expect(find.text('406K tok · 缓存命中 95%'), findsOneWidget);
    expect(find.text('上下文 2%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺失读数逐段隐藏，不显示 0 假数据', (tester) async {
    // 只有会话统计：没有 token 段，也没有上下文段。
    await tester.pumpWidget(
      _host(insights: RemoteSessionInsights(stats: _stats(turns: 2, steps: 3))),
    );
    expect(find.text('轮 2 · 步 3'), findsOneWidget);
    expect(find.textContaining('tok'), findsNothing);
    expect(find.textContaining('上下文'), findsNothing);

    // 会话统计 0 轮 0 步：整条不渲染。
    await tester.pumpWidget(
      _host(insights: RemoteSessionInsights(stats: _stats())),
    );
    expect(find.byKey(RemoteStatsBar.barKey), findsNothing);

    // 完全没有读数：整条不渲染。
    await tester.pumpWidget(_host(insights: RemoteSessionInsights.none));
    expect(find.byKey(RemoteStatsBar.barKey), findsNothing);

    // 用量全为 0（这一轮没有计费）：不显示 0 tok / 0% 的假读数。
    await tester.pumpWidget(
      _host(insights: RemoteSessionInsights(usage: _usage())),
    );
    expect(find.byKey(RemoteStatsBar.barKey), findsNothing);

    // 只有输出、没有缓存读写：token 段显示，缓存命中段隐藏。
    await tester.pumpWidget(
      _host(insights: RemoteSessionInsights(usage: _usage(outputTokens: 5))),
    );
    expect(find.text('5 tok'), findsOneWidget);
    expect(find.textContaining('缓存命中'), findsNothing);

    // 上下文只有容量、没有已用量：没有百分比段，整条不渲染。
    await tester.pumpWidget(
      _host(
        insights: const RemoteSessionInsights(
          pressure: RemoteContextPressure(contextWindow: 1048576),
        ),
      ),
    );
    expect(find.byKey(RemoteStatsBar.barKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存命中率按 Web 同规则格式化，包含真实 0% 与高精度读数', (tester) async {
    // 命中 0% 是真实读数（有计费输入、没有缓存读取），照常显示。
    await tester.pumpWidget(
      _host(
        insights: RemoteSessionInsights(
          usage: _usage(uncachedInputTokens: 100),
        ),
      ),
    );
    expect(find.text('100 tok · 缓存命中 0%'), findsOneWidget);

    // 四舍五入会放大成 100% 时提高精度，保持「部分命中低于 100%」。
    await tester.pumpWidget(
      _host(
        insights: RemoteSessionInsights(
          usage: _usage(uncachedInputTokens: 1, cacheReadTokens: 9999),
        ),
      ),
    );
    expect(find.text('10K tok · 缓存命中 99.99%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏放不下一行时折叠为可点的小胶囊，保留关键读数', (tester) async {
    await tester.pumpWidget(_host(insights: _fullInsights(), width: 200));

    expect(find.byKey(RemoteStatsBar.barKey), findsOneWidget);
    expect(find.byKey(RemoteStatsBar.capsuleKey), findsOneWidget);
    expect(find.byKey(RemoteStatsBar.lineKey), findsNothing);
    expect(find.text('上下文 2%'), findsOneWidget);

    // 没有上下文读数时胶囊退回缓存命中；只有会话统计时退回轮/步。
    await tester.pumpWidget(
      _host(
        insights: RemoteSessionInsights(
          usage: _usage(uncachedInputTokens: 19162, cacheReadTokens: 385792),
        ),
        width: 200,
      ),
    );
    expect(find.byKey(RemoteStatsBar.capsuleKey), findsOneWidget);
    expect(find.text('缓存命中 95%'), findsOneWidget);

    await tester.pumpWidget(
      _host(
        insights: RemoteSessionInsights(stats: _stats(turns: 2, steps: 3)),
        width: 200,
      ),
    );
    expect(find.text('轮 2 · 步 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点按统计条打开详情弹层，列出 token 四桶、上下文说明与平均读数', (tester) async {
    final insights = _fullInsights();
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: RemoteStatsBar(
                insights: insights,
                onTap: () => showRemoteStatsSheet(context, insights: insights),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(RemoteStatsBar.barKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('remote-stats-sheet')), findsOneWidget);
    expect(find.text('会话统计'), findsOneWidget);

    // 进度与平均用时。
    expect(find.text('轮次'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.text('步数'), findsOneWidget);
    expect(find.text('23'), findsOneWidget);
    expect(find.text('模型用时'), findsOneWidget);
    expect(find.text('57.2秒'), findsOneWidget);
    expect(find.text('工具调用用时'), findsOneWidget);
    expect(find.text('6.7秒'), findsOneWidget);
    expect(find.text('首 token 平均（TTFT）'), findsOneWidget);
    expect(find.text('2.1秒'), findsOneWidget);
    expect(find.text('输出速度（TPS）'), findsOneWidget);
    expect(find.text('137 tok/s'), findsOneWidget);

    // token 四桶与合计。
    expect(find.text('Token 用量'), findsOneWidget);
    expect(find.text('缓存命中'), findsOneWidget);
    expect(find.text('95%'), findsOneWidget);
    expect(find.text('未缓存输入'), findsOneWidget);
    expect(find.text('19,162 tok'), findsOneWidget);
    expect(find.text('缓存读取'), findsOneWidget);
    expect(find.text('385,792 tok'), findsOneWidget);
    expect(find.text('缓存写入'), findsOneWidget);
    expect(find.text('0 tok'), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    expect(find.text('1,304 tok'), findsOneWidget);
    expect(find.text('合计'), findsOneWidget);
    expect(find.text('406,258 tok'), findsOneWidget);

    // 上下文占用说明。
    expect(find.text('上下文'), findsOneWidget);
    expect(find.text('预测下次提示'), findsOneWidget);
    expect(find.text('19,058 tok'), findsOneWidget);
    expect(find.text('模型容量'), findsOneWidget);
    expect(find.text('1,048,576 tok'), findsOneWidget);
    expect(find.text('占用'), findsOneWidget);
    expect(find.text('2%'), findsOneWidget);
    expect(find.textContaining('不含输出'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭会话统计'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-stats-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情弹层只列出有读数的小节', (tester) async {
    final insights = RemoteSessionInsights(stats: _stats(turns: 2, steps: 3));
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: RemoteStatsBar(
                insights: insights,
                onTap: () => showRemoteStatsSheet(context, insights: insights),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(RemoteStatsBar.barKey));
    await tester.pumpAndSettle();

    expect(find.text('进度与用时'), findsOneWidget);
    expect(find.text('Token 用量'), findsNothing);
    expect(find.text('上下文'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
