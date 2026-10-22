import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'job_output.dart';
import 'runtime.dart';
import 'ui.dart';

class JobsPage extends StatefulWidget {
  const JobsPage({super.key, required this.runtime, required this.sessionId});
  final RuntimeController runtime;
  final String sessionId;
  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> {
  StreamSubscription<Json>? subscription;
  List<Json> jobs = [];
  bool current = false;
  String? error;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(watch());
  }

  Future<void> watch() async {
    final attempt = ++generation;
    setState(() {
      current = false;
      error = null;
    });
    await subscription?.cancel();
    if (!mounted || attempt != generation) return;
    subscription = widget.runtime
        .watchApi(
          'job',
          'list',
          args: {
            'request': {'sessionId': widget.sessionId},
          },
        )
        .listen(
          (frame) {
            if (!mounted || attempt != generation) return;
            setState(() {
              if (frame['type'] == 'item') {
                final value = frame['value'] as Json;
                jobs = (value['jobs'] as List).cast<Json>();
                current = true;
                error = null;
              } else if (frame['type'] == 'disconnected') {
                current = false;
                error = '运行时连接已中断，下面是上次读取的任务。';
              } else if (frame['type'] == 'opening') {
                current = false;
              }
            });
          },
          onError: (Object failure) {
            if (mounted && attempt == generation) {
              setState(() {
                current = false;
                error = '无法读取子进程任务：$failure';
              });
            }
          },
          onDone: () {
            if (mounted && attempt == generation) {
              setState(() {
                current = false;
                error ??= '任务状态连接已结束，请重新连接。';
              });
            }
          },
        );
  }

  @override
  void dispose() {
    generation++;
    unawaited(subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('子进程任务'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '重新连接任务列表',
      onPressed: watch,
    ),
    body: PocketList(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, 20),
          child: Text('展示当前会话拥有的子进程，以及 DSH 允许所有会话查看的任务。读取输出不会消耗 Agent 的读取位置。'),
        ),
        if (error != null)
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.sync_problem_rounded,
                title: '任务状态暂不可用',
                subtitle: error,
              ),
            ],
          ),
        if (jobs.isEmpty)
          PocketSection(
            children: [
              PocketRow(
                icon: current
                    ? Icons.check_circle_outline_rounded
                    : Icons.hourglass_top_rounded,
                title: current
                    ? '当前没有子进程任务'
                    : error != null
                    ? '任务列表未能加载'
                    : '正在连接任务列表',
              ),
            ],
          ),
        for (final job in jobs)
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.terminal_rounded,
                title: '${job['label']}',
                subtitle:
                    '${jobStatusLabel('${job['status']}')}'
                    '${job['progress'] == null ? '' : ' · ${job['progress']}'}'
                    '${current ? '' : ' · 上次状态'}',
                onTap: () => Navigator.push(
                  context,
                  PocketRoute<void>(
                    builder: (_) => JobOutputPage(
                      runtime: widget.runtime,
                      sessionId: widget.sessionId,
                      job: job,
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    ),
  );
}

class JobOutputPage extends StatefulWidget {
  const JobOutputPage({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.job,
  });
  final RuntimeController runtime;
  final String sessionId;
  final Json job;
  @override
  State<JobOutputPage> createState() => _JobOutputPageState();
}

class _JobOutputPageState extends State<JobOutputPage> {
  final output = JobOutput();
  StreamSubscription<Json>? subscription;
  int generation = 0;
  int observationGeneration = 0;
  bool current = false, stopping = false;
  bool stopNeedsReconcile = false;
  String? error, actionError, notice;
  String get jobId => widget.job['id'] as String;

  @override
  void initState() {
    super.initState();
    output.job = widget.job;
    unawaited(watch());
  }

  Future<void> watch() async {
    final attempt = ++generation;
    setState(() {
      invalidateObservation();
      current = false;
      error = null;
    });
    await subscription?.cancel();
    if (!mounted || attempt != generation) return;
    subscription = widget.runtime
        .watchApi(
          'job',
          'follow',
          resumeArgs: () => {
            'request': {
              'sessionId': widget.sessionId,
              'jobId': jobId,
              if (output.cursor != null) 'from': output.cursor,
            },
          },
        )
        .listen(
          (frame) {
            if (!mounted || attempt != generation) return;
            setState(() {
              if (frame['type'] == 'item') {
                final value = frame['value'] as Json;
                output.apply(value);
                current = true;
                error = null;
                if (value['type'] == 'opened' && stopNeedsReconcile) {
                  stopNeedsReconcile = false;
                  stopping = output.job?['status'] == 'stopping';
                  notice = switch (output.job?['status']) {
                    'running' => '任务仍在运行，如需停止请重新发起。',
                    'stopping' => '任务正在停止，等待最终输出。',
                    _ => '任务已结束，正在读取最终输出。',
                  };
                }
                if (output.settled) {
                  stopping = false;
                  stopNeedsReconcile = false;
                  notice = null;
                }
              } else if (frame['type'] == 'opening') {
                invalidateObservation();
                current = false;
              } else if (frame['type'] == 'disconnected') {
                invalidateObservation();
                current = false;
                error = '输出连接中断；已读内容保留，恢复后从原位置继续读取。';
              }
            });
          },
          onError: (Object failure) {
            if (mounted && attempt == generation) {
              setState(() {
                invalidateObservation();
                current = false;
                error = '无法继续读取输出：$failure';
              });
            }
          },
          onDone: () {
            if (!mounted || attempt != generation || output.settled) return;
            setState(() {
              invalidateObservation();
              current = false;
              error ??= '输出连接已结束，任务结果尚未确认。';
            });
          },
        );
  }

  void invalidateObservation() {
    observationGeneration++;
    if (stopping) {
      stopNeedsReconcile = true;
      notice = '停止结果待核对，恢复输出后确认任务状态。';
    }
  }

  Future<void> stop() async {
    if (stopping || !current || !widget.runtime.ready) return;
    final runtime = widget.runtime;
    final connection = runtime.connectionGeneration;
    final watch = generation;
    final observation = observationGeneration;
    // A stream can reopen within the same page and runtime connection. A stop
    // receipt belongs only to the observation that issued it; it is never replayed.
    bool ownsReceipt() =>
        mounted &&
        identical(widget.runtime, runtime) &&
        connection == runtime.connectionGeneration &&
        watch == generation &&
        observation == observationGeneration &&
        current &&
        runtime.ready &&
        !output.settled;
    setState(() {
      stopping = true;
      stopNeedsReconcile = false;
      actionError = null;
      notice = null;
    });
    try {
      final result = await runtime.call('api.call', {
        'namespace': 'job',
        'method': 'kill',
        'args': {
          'request': {'sessionId': widget.sessionId, 'jobId': jobId},
        },
      }) as Json;
      if (!ownsReceipt()) return;
      setState(
        () => notice = result['outcome'] == 'already-finished'
            ? '任务已结束，正在核对最终输出。'
            : '停止请求已接受，等待任务结束。',
      );
    } catch (failure) {
      if (ownsReceipt()) {
        setState(() {
          stopping = false;
          actionError = '停止请求的结果未确认：$failure';
        });
      }
    }
  }

  Future<void> copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: output.text));
      if (mounted) setState(() => notice = '已复制当前保留的输出。');
    } catch (failure) {
      if (mounted) setState(() => actionError = '无法复制：$failure');
    }
  }

  @override
  void dispose() {
    generation++;
    unawaited(subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = output.job ?? widget.job;
    final active = job['status'] == 'running' || job['status'] == 'stopping';
    return PocketScaffold(
      title: const Text('任务输出'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '重新连接任务输出',
        onPressed: watch,
      ),
      body: PocketList(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.terminal_rounded,
                title: '${job['label']}',
                subtitle:
                    '${jobStatusLabel('${job['status']}')}${current ? '' : ' · 上次状态'}',
              ),
              if (job['detail'] != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
                  child: SelectableText('${job['detail']}'),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PocketButton.tonal(
                      onPressed: output.text.isEmpty ? null : copy,
                      child: const Text('复制输出'),
                    ),
                    if (active)
                      PocketButton.tonal(
                        onPressed: !current || !widget.runtime.ready || stopping
                            ? null
                            : stop,
                        child: Text(
                          stopNeedsReconcile
                              ? '核对停止状态'
                              : stopping
                              ? '正在停止'
                              : '停止子进程',
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          for (final message in [error, actionError, notice])
            if (message != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(message),
              ),
          if (output.gapBefore)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('只显示当前保留的输出，前面的部分已不在此视图中。'),
            ),
          PocketCard(
            padding: const EdgeInsets.all(18),
            child: SelectableText(
              output.text.isEmpty ? '暂时没有输出。' : output.text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
