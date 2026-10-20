import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

/// Saves the original DSH archive through Android's system document picker.
class SessionExportPage extends StatefulWidget {
  const SessionExportPage({
    super.key,
    required this.runtime,
    required this.sessionId,
    required this.sessionTitle,
  });

  final RuntimeController runtime;
  final String sessionId, sessionTitle;

  @override
  State<SessionExportPage> createState() => _SessionExportPageState();
}

class _SessionExportPageState extends State<SessionExportPage> {
  String? id, message, error;
  Json? archive;
  bool preparing = false, saving = false, cleaning = false;
  int generation = 0;

  String nextId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> prepare() async {
    if (id != null || preparing || saving || cleaning) return;
    final requestId = nextId();
    final current = ++generation;
    setState(() {
      id = requestId;
      preparing = true;
      error = null;
      message = null;
    });
    try {
      final result = await widget.runtime.call('session.export.prepare', {
        'id': requestId,
        'sessionId': widget.sessionId,
        'includeDescendants': true,
      }) as Json;
      if (!mounted || generation != current) return;
      if (result['id'] != requestId ||
          result['filename'] is! String ||
          result['size'] is! num) {
        throw const FormatException('导出结果无效，请重试');
      }
      setState(() {
        archive = result;
        preparing = false;
      });
      await save();
    } catch (failure) {
      if (!mounted || generation != current) return;
      setState(() {
        preparing = false;
        error = '未能生成会话导出。原会话未改变。\n$failure';
      });
      try {
        await widget.runtime.call('session.export.release', {'id': requestId});
        if (mounted && generation == current) setState(() => id = null);
      } catch (cleanupFailure) {
        if (mounted && generation == current) {
          setState(() => error = '$error\n临时文件清理尚未确认，请重试清理。');
        }
      }
    }
  }

  Future<void> save() async {
    final prepared = archive;
    final requestId = id;
    if (prepared == null || requestId == null || saving || cleaning) return;
    final current = generation;
    setState(() {
      saving = true;
      error = null;
      message = null;
    });
    try {
      final raw = await RuntimeController.channel.invokeMethod<String>(
        'sessionExport.save',
        {'id': requestId, 'filename': prepared['filename']},
      );
      final result = jsonDecode(raw!) as Json;
      if (!mounted || generation != current) return;
      if (result['status'] != 'saved' && result['status'] != 'cancelled') {
        throw const FormatException('尚未确认保存结果，请检查目标文件');
      }
      setState(() {
        message = result['status'] == 'saved'
            ? '已保存 ${prepared['filename']}'
            : result['partialDestination'] == true
            ? '已取消保存。目标位置可能留下不完整的 ZIP 文件。'
            : '已取消保存。';
        archive = null;
      });
      try {
        await widget.runtime.call('session.export.release', {'id': requestId});
        if (mounted && generation == current) setState(() => id = null);
      } catch (cleanupFailure) {
        if (mounted && generation == current) {
          setState(() => error = '保存操作已结束，但临时文件清理尚未确认，请重试清理。');
        }
      }
    } catch (failure) {
      if (mounted && generation == current) {
        setState(
          () => error =
              '保存未完成，可重新选择位置重试。\n'
              '目标位置可能已留下不完整的 ZIP 文件。\n$failure',
        );
      }
    } finally {
      if (mounted && generation == current) setState(() => saving = false);
    }
  }

  Future<void> discard() async {
    final requestId = id;
    if (requestId == null || cleaning) return;
    final completedMessage = archive == null && !preparing && !saving
        ? message
        : null;
    final current = ++generation;
    setState(() => cleaning = true);
    try {
      await RuntimeController.channel.invokeMethod<void>(
        'sessionExport.cancel',
        {'id': requestId},
      );
      await widget.runtime.call('session.export.cancel', {'id': requestId});
      if (mounted && generation == current) {
        setState(() {
          id = null;
          archive = null;
          preparing = false;
          saving = false;
          error = null;
          message = completedMessage ?? '本次导出已取消。若已开始保存，目标位置可能留下不完整的 ZIP 文件。';
        });
      }
    } catch (failure) {
      if (mounted && generation == current) {
        setState(() {
          preparing = false;
          saving = false;
          archive = null;
          error = '临时文件清理尚未确认，可重试清理。\n$failure';
        });
      }
    } finally {
      if (mounted && generation == current) setState(() => cleaning = false);
    }
  }

  @override
  void dispose() {
    generation++;
    final requestId = id;
    if (requestId != null) {
      unawaited(() async {
        try {
          await RuntimeController.channel.invokeMethod<void>(
            'sessionExport.cancel',
            {'id': requestId},
          );
        } catch (failure) {
          // The Activity may already be gone; still ask the live service to release its cache.
        }
        try {
          await widget.runtime.call('session.export.cancel', {'id': requestId});
        } catch (failure) {
          // Service teardown or Android cache eviction also owns these temporary artifacts.
        }
      }());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('导出会话'),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        PocketSection(
          children: [
            PocketRow(
              icon: Icons.folder_zip_outlined,
              title: widget.sessionTitle,
              subtitle: '保存原版 DSH ZIP，包含会话日志、子 Agent 会话和已引用的附件。',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Text(
                preparing
                    ? '正在生成 ZIP…'
                    : saving
                    ? '请选择保存位置，正在等待保存完成…'
                    : archive != null
                    ? 'ZIP 已生成，可重新选择保存位置。'
                    : '导出不会停止当前任务。文件通过系统选择器保存。',
              ),
            ),
          ],
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(message!),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(error!),
          ),
        if (id == null)
          PocketButton(onPressed: prepare, child: const Text('生成并保存 ZIP')),
        if (archive != null && !saving && !cleaning)
          PocketButton(onPressed: save, child: const Text('重新选择保存位置')),
        if (id != null)
          PocketButton.tonal(
            onPressed: cleaning ? null : discard,
            child: Text(
              cleaning
                  ? '正在清理'
                  : preparing || saving || archive != null
                  ? '取消本次导出'
                  : '重试清理',
            ),
          ),
      ],
    ),
  );
}
