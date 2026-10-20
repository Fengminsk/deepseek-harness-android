import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'models.dart' show ModelDraftGuard;
import 'runtime.dart';
import 'ui.dart';

const _pretty = JsonEncoder.withIndent('  ');
const _scope =
    '仅迁移本机已存在、可实时修改的普通运行设置。'
    '不包含账号与凭据、主题、插件安装/启停/拓扑、原始 Cordis 配置、会话、'
    'Web 开关和设备文件授权；这不是全量备份。'
    '\n文件中缺失的字段保持原样，不删除设置。凭据引用和设备路径需要单独设置。';

String _operationId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String _state(dynamic value) => switch (value) {
  'applied' => '已应用',
  'unchanged' => '内容相同，无需写入',
  'conflict' => '版本冲突，未覆盖',
  'unknown' => '写入结果未确认',
  _ => '尚未执行',
};

/// Previews a bounded ordinary-settings document before original revisioned writes.
class ConfigurationTransferPage extends StatefulWidget {
  const ConfigurationTransferPage({required this.runtime, super.key});
  final RuntimeController runtime;
  @override
  State<ConfigurationTransferPage> createState() =>
      _ConfigurationTransferPageState();
}

class _ConfigurationTransferPageState extends State<ConfigurationTransferPage> {
  final source = TextEditingController();
  final selected = <String>{};
  Json? plan, exported;
  String? reviewedText, fileOperation, message, receipt;
  bool busy = false, uncertain = false, replaceReview = false;

  List<Json> get sections =>
      (plan?['sections'] as List? ?? const []).cast<Json>();
  List<Json> get issues => (plan?['issues'] as List? ?? const []).cast<Json>();
  bool get canApply =>
      !busy &&
      !uncertain &&
      plan != null &&
      source.text == reviewedText &&
      issues.isEmpty &&
      selected.isNotEmpty &&
      sections
          .where((row) => selected.contains(row['ns']))
          .every((row) => row['status'] == 'pending');

  Future<void> pick() async {
    final id = _operationId();
    setState(() {
      busy = true;
      fileOperation = id;
      replaceReview = false;
    });
    try {
      final raw = await RuntimeController.channel.invokeMethod<String>(
        'configurationTransfer.pick',
        {'id': id},
      );
      final result = jsonDecode(raw!) as Json;
      if (!mounted) return;
      if (result['status'] == 'selected' && result['text'] is String) {
        setState(() {
          source.text = result['text'] as String;
          message = '文件已读取，尚未应用。请预览并核对范围。';
        });
      } else if (result['status'] == 'cancelled') {
        setState(() => message = '已取消选择，原草稿保留。');
      } else {
        throw const FormatException('未确认文件读取结果');
      }
    } catch (error) {
      if (mounted) setState(() => message = '读取失败，原草稿保留。\n$error');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          fileOperation = null;
        });
      }
    }
  }

  Future<void> preview() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (plan != null) {
        await widget.runtime.call('configuration.transfer.release', {
          'id': plan!['id'],
        });
        if (!mounted) return;
        setState(() => plan = null);
      }
      final text = source.text;
      final result = await widget.runtime.call(
        'configuration.transfer.preview',
        {'text': text},
      ) as Json;
      if (!mounted) {
        await widget.runtime.call('configuration.transfer.release', {
          'id': result['id'],
        });
        return;
      }
      setState(() {
        plan = result;
        reviewedText = text;
        uncertain = false;
        selected
          ..clear()
          ..addAll(sections.map((row) => row['ns'] as String));
        message = issues.isEmpty
            ? '已按本机原 schema 校验字段。请核对前后值；提交时仍由原服务校验并检查版本。'
            : '以下内容无法导入；没有任何设置被写入。请修正原文件或 JSON 草稿，不会静默跳过。';
      });
    } catch (error) {
      if (mounted) setState(() => message = '预览失败，文件内容已保留。\n$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    if (!canApply) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = await widget.runtime.call('configuration.transfer.apply', {
        'id': plan!['id'],
        'namespaces': selected.toList(),
      }) as Json;
      if (!mounted) return;
      setState(() {
        plan = result;
        receipt = sections
            .map((row) => '${row['ns']}：${_state(row['status'])}')
            .join('\n');
        message =
            '已收到原服务执行结果。跨命名空间不是原子事务；'
            '已应用的设置不会自动回滚，未完成项不会自动重试。原文件内容保留。';
      });
      try {
        await widget.runtime.refreshForms();
      } catch (error) {
        if (mounted) setState(() => message = '$message\n设置列表刷新失败：$error');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          uncertain = true;
          for (final section in sections) {
            if (selected.contains(section['ns'])) {
              section['status'] = 'unknown';
              section['message'] = '未收到本次操作回执，该项结果尚未确认。';
            }
          }
          message =
              '未能确认本次写入结果，可能已有部分设置生效。'
              '已停止重试；原文件保留，请重新读取预览并比较当前值。\n$error';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> prepareExport() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result =
          await widget.runtime.call('configuration.transfer.export') as Json;
      if (mounted) setState(() => exported = result);
    } catch (error) {
      if (mounted) setState(() => message = '无法准备导出，现有设置未改变。\n$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> saveExport() async {
    if (exported == null) return;
    final id = _operationId();
    setState(() {
      busy = true;
      fileOperation = id;
    });
    try {
      final raw = await RuntimeController.channel.invokeMethod<String>(
        'configurationTransfer.save',
        {
          'id': id,
          'filename': 'pocket-harness-settings.json',
          'text': exported!['text'],
        },
      );
      final result = jsonDecode(raw!) as Json;
      if (!mounted) return;
      if (result['status'] == 'saved') {
        setState(() => message = '已保存运行设置 JSON。此文件不是全量备份。');
      } else if (result['status'] == 'cancelled') {
        setState(
          () => message = result['partialDestination'] == true
              ? '已取消保存，目标位置可能留下不完整的 JSON 文件。'
              : '已取消保存，导出预览保留。',
        );
      } else {
        throw const FormatException('未确认文件保存结果');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => message =
              '保存未完成，导出预览保留，可重新选择位置。'
              '目标位置可能留下不完整文件。\n$error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          fileOperation = null;
        });
      }
    }
  }

  @override
  void dispose() {
    final id = plan?['id'];
    if (id != null) {
      unawaited(
        widget.runtime
            .call('configuration.transfer.release', {'id': id})
            .catchError((Object error) {
              // Instance close releases remaining previews after transport loss.
              debugPrint('Configuration preview cleanup not confirmed: $error');
              return null;
            }),
      );
    }
    final fileId = fileOperation;
    if (fileId != null) {
      unawaited(
        RuntimeController.channel
            .invokeMethod<void>('configurationTransfer.cancel', {'id': fileId})
            .catchError((Object error) {
              // Activity teardown closes the same native operation.
              debugPrint(
                'Configuration file cancellation not confirmed: $error',
              );
            }),
      );
    }
    source.dispose();
    super.dispose();
  }

  Widget note(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: SelectableText(text),
  );

  Widget omissions(dynamic value, String title) => PocketDisclosure(
    title: title,
    child: note(
      (value as List? ?? const [])
          .map((entry) {
            final path = (entry['path'] as List? ?? const []).join(' › ');
            return '${entry['ns'] ?? '全局'}${path.isEmpty ? '' : ' · $path'}：${entry['reason']}';
          })
          .join('\n'),
    ),
  );

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () => source.text.isNotEmpty,
    busy: busy,
    child: PocketScaffold(
      title: const Text('运行设置导入导出'),
      bottom: PocketButton(
        key: const Key('configuration-transfer-apply'),
        onPressed: canApply ? apply : null,
        child: Text(busy ? '正在处理' : '应用所选命名空间'),
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          note(_scope),
          if (message != null) note(message!),
          if (receipt != null)
            PocketSection(title: '上次执行回执', children: [note(receipt!)]),
          PocketSection(
            title: '导出',
            children: [
              PocketRow(
                icon: Icons.output_rounded,
                title: '读取本机运行设置',
                subtitle: '先展示实际范围，再选择保存位置',
                onTap: busy ? null : prepareExport,
              ),
              if (exported != null) ...[
                for (final section in exported!['sections'] as List)
                  PocketDisclosure(
                    title:
                        '${section['ns']} · ${(section['fields'] as List).length} 个字段',
                    child: note(_pretty.convert(section['fields'])),
                  ),
                omissions(exported!['excluded'], '实际未包含的命名空间和字段'),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: PocketButton.tonal(
                    key: const Key('configuration-transfer-save'),
                    onPressed: busy ? null : saveExport,
                    child: const Text('确认范围并另存为 JSON'),
                  ),
                ),
              ],
            ],
          ),
          PocketSection(
            title: '导入',
            children: [
              PocketRow(
                icon: Icons.file_open_outlined,
                title: '选择运行设置 JSON',
                subtitle: '最多 1 MiB；一次性读取，不新增目录授权',
                onTap: busy
                    ? null
                    : source.text.isEmpty
                    ? pick
                    : () => setState(() => replaceReview = true),
              ),
              if (replaceReview) ...[
                note('选择新文件会替换当前导入草稿。取消文件选择时保留原草稿。'),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      PocketButton(
                        onPressed: busy ? null : pick,
                        child: const Text('继续选择并替换草稿'),
                      ),
                      PocketButton.tonal(
                        onPressed: () => setState(() => replaceReview = false),
                        child: const Text('保留当前草稿'),
                      ),
                    ],
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  key: const Key('configuration-transfer-source'),
                  controller: source,
                  enabled: !busy,
                  minLines: 6,
                  maxLines: 14,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'JSON 草稿',
                    helperText: '修改后需重新预览；不接受 Cordis YAML 或凭据文件。',
                    helperMaxLines: 3,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: PocketButton.tonal(
                  key: const Key('configuration-transfer-preview'),
                  onPressed: busy || source.text.trim().isEmpty
                      ? null
                      : preview,
                  child: const Text('读取当前设置并预览'),
                ),
              ),
            ],
          ),
          if (plan != null) ...[
            if (source.text != reviewedText) note('草稿已修改，以下预览已过期。请重新预览后再应用。'),
            if (issues.isNotEmpty) omissions(issues, '必须处理的问题'),
            for (final section in sections)
              PocketSection(
                title: '${section['ns']} · 版本 ${section['revision']}',
                children: [
                  PocketSwitchRow(
                    key: ValueKey('configuration-transfer-${section['ns']}'),
                    title: Text(_state(section['status'])),
                    subtitle: Text(
                      '${(section['changes'] as List).length} 个变更字段；'
                      '其余字段保持原样',
                    ),
                    value: selected.contains(section['ns']),
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            if (value) {
                              selected.add(section['ns'] as String);
                            } else {
                              selected.remove(section['ns']);
                            }
                          }),
                  ),
                  if (section['message'] != null) note('${section['message']}'),
                  for (final change in section['changes'] as List)
                    PocketDisclosure(
                      title: (change['path'] as List).join(' › '),
                      child: note(
                        '当前：${change.containsKey('before') ? _pretty.convert(change['before']) : '未设置'}'
                        '\n导入：${_pretty.convert(change['after'])}',
                      ),
                    ),
                ],
              ),
            omissions(plan!['excluded'], '文件记录的不包含范围'),
            note(
              '逐命名空间执行。遇到冲突或未确认结果时停止后续写入；'
              '不会自动回滚已应用项，也不会自动重试。',
            ),
          ],
        ],
      ),
    ),
  );
}
