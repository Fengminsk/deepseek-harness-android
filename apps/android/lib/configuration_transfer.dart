import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'configuration_editor.dart' show configurationNamespaceTitle;
import 'confirmation.dart';
import 'metadata_artwork.dart';
import 'flclash/switch.dart';
import 'runtime.dart';
import 'text_document_page.dart';
import 'ui.dart';

const _pretty = JsonEncoder.withIndent('  ');
const _scope =
    '仅迁移本机已存在、可实时修改的普通运行设置。'
    '不包含账号与凭据、主题、插件安装/启停/拓扑、原始 Cordis 配置、会话、'
    'Web 开关和设备文件授权；这不是全量备份。'
    '\n文件中缺失的字段保持原样，不删除设置。凭据引用和设备路径需要单独设置。';

enum _Stage { home, input, preview, result, export }

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
  bool leaving = false, leaveReview = false;
  bool sourceDirty = false, planReleased = false;
  _Stage stage = _Stage.home;

  List<Json> get sections =>
      (plan?['sections'] as List? ?? const []).cast<Json>();
  List<Json> get issues => (plan?['issues'] as List? ?? const []).cast<Json>();
  bool get canApply =>
      !busy &&
      !uncertain &&
      !planReleased &&
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
          sourceDirty = true;
          message = '文件已读取。预览后再选择要导入的设置。';
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
      if (plan != null && !planReleased) {
        await widget.runtime.call('configuration.transfer.release', {
          'id': plan!['id'],
        });
        if (!mounted) return;
        setState(() => planReleased = true);
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
        stage = _Stage.preview;
        planReleased = false;
        receipt = null;
        reviewedText = text;
        uncertain = false;
        selected
          ..clear()
          ..addAll(sections.map((row) => row['ns'] as String));
        message = issues.isEmpty ? null : '文件有需要修正的内容，尚未写入任何设置。';
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
        stage = _Stage.result;
        receipt = sections
            .map(
              (row) =>
                  '${configurationNamespaceTitle('${row['ns']}')}：${_state(row['status'])}',
            )
            .join('\n');
        message = '已完成项保留，未完成项不会自动重试。原文件内容已保留。';
        sourceDirty = sections
            .where((row) => selected.contains(row['ns']))
            .any(
              (row) =>
                  row['status'] != 'applied' && row['status'] != 'unchanged',
            );
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
          stage = _Stage.result;
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
      if (mounted) {
        setState(() {
          exported = result;
          stage = _Stage.export;
        });
      }
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
    if (id != null && !planReleased) {
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

  void go(_Stage next) => setState(() {
    stage = next;
    message = null;
    replaceReview = false;
  });

  void back() {
    if (busy) return;
    if (stage != _Stage.home) {
      go(
        stage == _Stage.preview || stage == _Stage.result
            ? _Stage.input
            : _Stage.home,
      );
    } else if (sourceDirty && source.text.isNotEmpty) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => leaveReview = true);
    } else {
      close();
    }
  }

  void close() {
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Widget note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
    child: SelectableText(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        height: 1.6,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget scope() => PocketSection(
    children: [
      TextDocumentRow(
        title: '迁移范围',
        subtitle: '普通运行设置，不含账号与密钥',
        icon: Icons.info_outline_rounded,
        text: _scope,
      ),
    ],
  );

  Widget omissions(dynamic value, String title) {
    final items = (value as List? ?? const []).cast<Json>();
    return TextDocumentRow(
      title: title,
      subtitle: '${items.length} 项',
      icon: Icons.info_outline_rounded,
      text: items.isEmpty
          ? '没有此类项目。'
          : items
                .map((item) {
                  final path = (item['path'] as List? ?? const []).join(' › ');
                  return '${configurationNamespaceTitle('${item['ns'] ?? '全局'}')}'
                      '${path.isEmpty ? '' : ' · $path'}\n${item['reason']}';
                })
                .join('\n\n'),
    );
  }

  Future<void> editSource() async {
    if (busy) return;
    final result = await Navigator.of(context).push<String>(
      PocketRoute(
        builder: (_) => TextDocumentPage(
          title: '导入内容',
          text: source.text,
          readOnly: false,
          monospace: true,
          fieldKey: const Key('configuration-transfer-source'),
          helperText: '完成后返回导入草稿，预览不会写入设置。',
        ),
      ),
    );
    if (mounted && result != null && !busy) {
      setState(() {
        sourceDirty = sourceDirty || result != source.text;
        source.text = result;
      });
    }
  }

  String sectionText(Json section, {required bool exporting}) {
    final values = (section[exporting ? 'fields' : 'changes'] as List)
        .cast<Json>();
    return [
      if (section['message'] != null) '${section['message']}',
      for (final value in values)
        '${(value['path'] as List).join(' › ')}\n'
            '${exporting ? _pretty.convert(value['value']) : '当前：${value.containsKey('before') ? _pretty.convert(value['before']) : '未设置'}\n导入：${_pretty.convert(value['after'])}'}',
      '配置标识：${section['ns']}${section['revision'] == null ? '' : '\n读取版本：${section['revision']}'}',
    ].join('\n\n');
  }

  Widget selection(Json section) {
    final id = section['ns'] as String;
    final enabled = !busy && section['status'] == 'pending';
    void change(bool value) {
      if (!enabled) return;
      setState(() {
        if (value) {
          selected.add(id);
        } else {
          selected.remove(id);
        }
      });
    }

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '选择${configurationNamespaceTitle(id)}',
      toggled: selected.contains(id),
      enabled: enabled,
      onTap: enabled ? () => change(!selected.contains(id)) : null,
      child: GestureDetector(
        key: ValueKey('configuration-transfer-selection-target-$id'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        // Keep the padding owned even while disabled, rather than expanding
        // the surrounding disclosure when a user aims for the switch.
        onTap: () => change(!selected.contains(id)),
        child: SizedBox(
          width: DashboardSwitch.trackWidth,
          height: 48,
          child: Center(
            child: DashboardSwitch(
              key: ValueKey('configuration-transfer-$id'),
              value: selected.contains(id),
              onChanged: enabled ? change : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget sectionRows(
    List<Json> rows, {
    bool exporting = false,
    bool result = false,
  }) => PocketSection(
    divided: true,
    title: exporting
        ? '包含的设置'
        : result
        ? '执行结果'
        : '选择要导入的设置',
    children: [
      for (final section in rows)
        PocketRow(
          key: ValueKey('${stage.name}-${section['ns']}'),
          leading: result
              ? null
              : configurationArtwork({
                  'ns': section['ns'],
                  for (final form in widget.runtime.forms)
                    if (form['ns'] == section['ns']) 'display': form['display'],
                }),
          title: configurationNamespaceTitle('${section['ns']}'),
          subtitle: exporting
              ? '${(section['fields'] as List).length} 个字段'
              : '${(section['changes'] as List).length} 处变更'
                    '${result ? ' · ${_state(section['status'])}' : ''}',
          icon: exporting
              ? Icons.tune_rounded
              : result
              ? section['status'] == 'applied' ||
                        section['status'] == 'unchanged'
                    ? Icons.check_circle_outline_rounded
                    : Icons.info_outline_rounded
              : Icons.tune_rounded,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!exporting && !result) ...[
                selection(section),
                const SizedBox(width: 10),
              ],
              const Icon(Icons.chevron_right_rounded, size: 20),
            ],
          ),
          onTap: () => Navigator.of(context).push<void>(
            PocketRoute(
              builder: (_) => TextDocumentPage(
                title: configurationNamespaceTitle('${section['ns']}'),
                text: sectionText(section, exporting: exporting),
                monospace: true,
                selectable: true,
              ),
            ),
          ),
        ),
    ],
  );

  List<Widget> homeContent() => [
    PocketSection(
      divided: true,
      children: [
        PocketRow(
          key: const Key('configuration-transfer-import-entry'),
          icon: Icons.download_rounded,
          title: source.text.isEmpty ? '导入设置' : '继续导入',
          subtitle: source.text.isEmpty ? '从 JSON 文件或粘贴内容开始' : '已保留导入草稿',
          onTap: busy ? null : () => go(_Stage.input),
        ),
        PocketRow(
          key: const Key('configuration-transfer-export-entry'),
          icon: Icons.upload_rounded,
          title: '导出设置',
          subtitle: busy ? '正在读取本机设置…' : '核对范围后保存为 JSON',
          onTap: busy
              ? null
              : exported == null
              ? prepareExport
              : () => go(_Stage.export),
        ),
      ],
    ),
    if (message != null) note(message!),
    scope(),
  ];

  List<Widget> inputContent() => [
    PocketSection(
      divided: true,
      children: [
        PocketRow(
          icon: Icons.file_open_outlined,
          title: source.text.isEmpty ? '选择 JSON 文件' : '重新选择文件',
          subtitle: source.text.isEmpty
              ? '最多 1 MiB，不新增文件授权'
              : '当前草稿 ${source.text.length} 个字符',
          onTap: busy
              ? null
              : source.text.isEmpty
              ? pick
              : () => setState(() => replaceReview = true),
        ),
        PocketRow(
          title: source.text.isEmpty ? '粘贴 JSON 内容' : '查看或编辑 JSON',
          subtitle: source.text == reviewedText || reviewedText == null
              ? '高级编辑'
              : '草稿已修改，需要重新预览',
          icon: Icons.code_rounded,
          onTap: busy ? null : editSource,
        ),
        if (replaceReview) ...[
          note('选择新文件会替换当前草稿。取消文件选择时，原草稿保留。'),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
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
      ],
    ),
    if (message != null) note(message!),
    if (plan != null)
      PocketSection(
        children: [
          PocketRow(
            icon: Icons.fact_check_outlined,
            title: '查看上次${receipt == null && !uncertain ? '预览' : '执行结果'}',
            subtitle: source.text == reviewedText ? null : '预览已过期，请重新预览后再应用',
            onTap: busy
                ? null
                : () => go(
                    receipt == null && !uncertain
                        ? _Stage.preview
                        : _Stage.result,
                  ),
          ),
        ],
      ),
    scope(),
  ];

  List<Widget> previewContent() => [
    Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 22),
      child: Text(
        '已选 ${selected.length} 项设置',
        style: Theme.of(context).textTheme.titleLarge,
      ),
    ),
    if (busy) note('正在处理选中的设置…'),
    if (message != null) note(message!),
    if (source.text != reviewedText || planReleased) note('预览已过期。请重新预览后再应用。'),
    if (issues.isNotEmpty)
      PocketSection(children: [omissions(issues, '需要修正的内容')]),
    sectionRows(sections),
    PocketSection(
      divided: true,
      children: [
        PocketRow(
          icon: Icons.edit_outlined,
          title: '编辑导入内容',
          onTap: busy
              ? null
              : () {
                  go(_Stage.input);
                  unawaited(editSource());
                },
        ),
        TextDocumentRow(
          title: '应用规则',
          subtitle: '保留未选设置，提交时检查版本',
          icon: Icons.info_outline_rounded,
          text: '按本机配置规则校验，逐项检查版本并执行。遇到冲突或未确认结果时停止后续写入；已应用项不会自动回滚，未完成项不会自动重试。文件未提供的字段保持原样。',
        ),
        omissions(plan!['excluded'], '未包含的设置'),
      ],
    ),
  ];

  List<Widget> resultContent() => [
    Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 22),
      child: Text(
        uncertain || sections.any((row) => row['status'] == 'unknown')
            ? '有写入结果待确认'
            : sections.any((row) => row['status'] == 'conflict')
            ? '部分设置未能应用'
            : '已收到执行结果',
        style: Theme.of(context).textTheme.titleLarge,
      ),
    ),
    if (message != null) note(message!),
    sectionRows(sections, result: true),
    PocketSection(
      divided: true,
      children: [
        PocketRow(
          key: const Key('configuration-transfer-reread'),
          icon: Icons.refresh_rounded,
          title: '读取当前设置，重新预览',
          subtitle: '只读取并比较，不会重发上次写入',
          onTap: busy ? null : preview,
        ),
        PocketRow(
          icon: Icons.code_rounded,
          title: '查看保留的导入内容',
          onTap: busy
              ? null
              : () {
                  go(_Stage.input);
                  unawaited(editSource());
                },
        ),
      ],
    ),
  ];

  List<Widget> exportContent() => [
    Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 22),
      child: Text(
        '${(exported!['sections'] as List).length} 项设置可导出',
        style: Theme.of(context).textTheme.titleLarge,
      ),
    ),
    if (message != null) note(message!),
    sectionRows((exported!['sections'] as List).cast<Json>(), exporting: true),
    PocketSection(
      divided: true,
      children: [
        omissions(exported!['excluded'], '未包含的设置'),
        TextDocumentRow(
          title: '迁移范围',
          subtitle: '普通运行设置，不是全量备份',
          icon: Icons.info_outline_rounded,
          text: _scope,
        ),
        PocketRow(
          icon: Icons.refresh_rounded,
          title: '重新读取本机设置',
          onTap: busy ? null : prepareExport,
        ),
      ],
    ),
  ];

  Widget? action() => switch (stage) {
    _Stage.input when source.text.trim().isNotEmpty => PocketButton(
      key: const Key('configuration-transfer-preview'),
      onPressed: busy ? null : preview,
      child: Text(busy ? '正在预览…' : '预览导入内容'),
    ),
    _Stage.preview when canApply => PocketButton(
      key: const Key('configuration-transfer-apply'),
      onPressed: apply,
      child: Text('应用选中的 ${selected.length} 项设置'),
    ),
    _Stage.export => PocketButton(
      key: const Key('configuration-transfer-save'),
      onPressed: busy ? null : saveExport,
      child: Text(busy ? '正在保存…' : '保存为 JSON 文件'),
    ),
    _ => null,
  };

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: leaving,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) back();
    },
    child: PocketConfirmationLayer(
      confirmation: leaveReview
          ? PocketConfirmation(
              title: '保留导入草稿？',
              message: '离开此页面将清除本次草稿，已应用的设置保持不变。',
              secondaryLabel: '继续编辑',
              onSecondary: () => setState(() => leaveReview = false),
              primaryLabel: '放弃草稿并返回',
              onPrimary: busy ? null : close,
            )
          : null,
      child: PocketScaffold(
        title: Text(switch (stage) {
          _Stage.home => '导入与导出',
          _Stage.input => '导入设置',
          _Stage.preview => '核对导入',
          _Stage.result => '导入结果',
          _Stage.export => '导出设置',
        }),
        leading: GlassButton(
          icon: Icons.arrow_back_rounded,
          label: '返回',
          onPressed: busy || stage == _Stage.home && !Navigator.canPop(context)
              ? null
              : back,
        ),
        bottom: action(),
        body: PocketList(
          key: ValueKey('configuration-transfer-${stage.name}'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: switch (stage) {
            _Stage.home => homeContent(),
            _Stage.input => inputContent(),
            _Stage.preview => previewContent(),
            _Stage.result => resultContent(),
            _Stage.export => exportContent(),
          },
        ),
      ),
    ),
  );
}
