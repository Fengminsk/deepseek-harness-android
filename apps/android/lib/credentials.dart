import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'credentials_data.dart';
import 'ui.dart';

String _status(CredentialEntry entry) {
  if (entry.reading) return '正在核对状态';
  if (!entry.fresh) return '当前状态未确认';
  if (entry.status!.configured) {
    return '已配置${entry.status!.source == null ? '' : ' · ${entry.status!.source}'}';
  }
  return '尚未配置';
}

Widget _notice(String text) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
  child: Text(text),
);

class CredentialsPage extends StatefulWidget {
  const CredentialsPage({super.key, required this.controller});
  final CredentialsController controller;
  @override
  State<CredentialsPage> createState() => _CredentialsPageState();
}

class _CredentialsPageState extends State<CredentialsPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.start();
  }

  void open(CredentialEntry row) {
    unawaited(widget.controller.readReference(row.reference));
    Navigator.push<void>(
      context,
      PocketRoute<void>(
        builder: (_) => CredentialReferencePage(
          controller: widget.controller,
          reference: row.reference,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final rows = controller.entries.values.toList()
        ..sort((left, right) => left.reference.compareTo(right.reference));
      return PocketScaffold(
        title: const Text('凭据引用'),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '刷新凭据状态',
          onPressed: controller.loading ? null : controller.refresh,
        ),
        body: PocketList(
          children: [
            PocketSection(
              children: [
                const PocketRow(
                  icon: Icons.key_outlined,
                  title: '模型与工具共用凭据',
                  subtitle: '修改同名引用会影响使用它的模型、搜索和其他工具。只显示配置状态，已有密钥不会回填。',
                ),
                PocketRow(
                  icon: Icons.add_rounded,
                  title: '指定其他凭据引用',
                  subtitle: '输入工具或插件配置中声明的引用名称',
                  onTap: () => Navigator.push<void>(
                    context,
                    PocketRoute<void>(
                      builder: (_) => CredentialAddPage(controller: controller),
                    ),
                  ),
                ),
                if (controller.catalogError != null)
                  _notice(controller.catalogError!),
                if (controller.loading) _notice('正在读取凭据引用与状态…'),
                if (!controller.catalogFresh && !controller.loading)
                  _notice('配置中的使用位置尚未同步，可刷新核对。'),
              ],
            ),
            PocketSection(
              title: '配置中的引用与已查看的引用',
              children: [
                if (rows.isEmpty && controller.catalogFresh)
                  const PocketRow(
                    icon: Icons.key_outlined,
                    title: '当前配置没有声明凭据引用',
                  ),
                for (final row in rows)
                  PocketRow(
                    key: ValueKey('credential-${row.reference}'),
                    icon: Icons.key_rounded,
                    title: row.reference,
                    subtitle:
                        '${_status(row)}\n${row.uses.isEmpty ? '当前配置未列出使用位置' : row.uses.map((use) => use.label).join('\n')}${row.draft.isEmpty ? '' : '\n保留有本次填写内容'}',
                    onTap: () => open(row),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class CredentialAddPage extends StatefulWidget {
  const CredentialAddPage({super.key, required this.controller});
  final CredentialsController controller;
  @override
  State<CredentialAddPage> createState() => _CredentialAddPageState();
}

class _CredentialAddPageState extends State<CredentialAddPage> {
  final input = TextEditingController();
  bool loading = false;
  String? error;

  Future<void> open() async {
    final reference = input.text;
    if (!validCredentialReference(reference)) {
      setState(() => error = '使用字母或下划线开头，后续可包含字母、数字、下划线。');
      return;
    }
    setState(() => loading = true);
    final row = await widget.controller.addReference(reference);
    if (!mounted) return;
    setState(() => loading = false);
    if (row == null) return;
    await Navigator.pushReplacement<void, void>(
      context,
      PocketRoute<void>(
        builder: (_) => CredentialReferencePage(
          controller: widget.controller,
          reference: row.reference,
        ),
      ),
    );
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('指定凭据引用'),
    body: PocketList(
      children: [
        PocketSection(
          children: [
            _notice('填写工具配置中的引用名称，例如 DEEPSEEK_API_KEY。此操作只查看引用，不会自动修改工具配置。'),
            Padding(
              padding: const EdgeInsets.all(20),
              child: TextField(
                key: const ValueKey('credential-reference-input'),
                controller: input,
                enabled: !loading,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '凭据引用名称'),
              ),
            ),
            if (error != null) _notice(error!),
          ],
        ),
        PocketButton(
          onPressed: loading ? null : open,
          child: Text(loading ? '正在核对' : '查看凭据'),
        ),
      ],
    ),
  );
}

class CredentialReferencePage extends StatefulWidget {
  const CredentialReferencePage({
    super.key,
    required this.controller,
    required this.reference,
  });
  final CredentialsController controller;
  final String reference;
  @override
  State<CredentialReferencePage> createState() =>
      _CredentialReferencePageState();
}

class _CredentialReferencePageState extends State<CredentialReferencePage> {
  late final input = TextEditingController(text: row.draft);
  CredentialEntry get row => widget.controller.entry(widget.reference);
  bool reveal = false, removalReview = false, overwriteReview = false;

  @override
  void initState() {
    super.initState();
    input.addListener(_edited);
    widget.controller.addListener(_changed);
  }

  void _edited() => widget.controller.edit(widget.reference, input.text);

  void _changed() {
    if (input.text != row.draft) {
      input.value = TextEditingValue(
        text: row.draft,
        selection: TextSelection.collapsed(offset: row.draft.length),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    input.removeListener(_edited);
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final available = controller.canWrite(row);
    final unknown = row.write?.state == 'unconfirmed';
    return PocketScaffold(
      title: const Text('管理凭据'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '核对凭据状态',
        onPressed: row.reading
            ? null
            : () => controller.readReference(row.reference),
      ),
      body: PocketList(
        children: [
          PocketSection(
            title: row.reference,
            children: [
              PocketRow(
                icon: Icons.key_outlined,
                title: _status(row),
                subtitle: row.fresh && row.status?.writable == false
                    ? '此凭据来源不接受写入或移除'
                    : '修改会影响所有使用同名引用的功能。',
              ),
              if (row.readError != null) _notice(row.readError!),
              if (row.write?.notice != null) _notice(row.write!.notice!),
              if (row.uses.isEmpty)
                _notice('当前配置未列出使用位置；其他手工配置也可能使用此引用。')
              else
                for (final use in row.uses)
                  PocketRow(
                    icon: Icons.link_rounded,
                    title: use.namespace,
                    subtitle: use.path.join('.'),
                  ),
              if (!controller.catalogFresh) _notice('使用位置尚未同步，请返回目录刷新核对。'),
            ],
          ),
          PocketSection(
            title: '填写新的凭据',
            children: [
              _notice('已有凭据不会显示或回填。留空不更改；填写内容仅保留在本次 App 运行的内存中。'),
              Padding(
                padding: const EdgeInsets.all(20),
                child: TextField(
                  key: const ValueKey('credential-value-input'),
                  controller: input,
                  obscureText: !reveal,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '新凭据'),
                ),
              ),
              PocketSwitchRow(
                title: const Text('显示本次输入'),
                value: reveal,
                onChanged: (value) => setState(() => reveal = value),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: PocketButton(
                  key: const ValueKey('credential-save'),
                  onPressed: !available || row.draft.isEmpty
                      ? null
                      : () {
                          if (unknown) {
                            setState(() => overwriteReview = true);
                          } else {
                            unawaited(controller.save(row.reference));
                          }
                        },
                  child: Text(row.write?.inFlight == true ? '等待写入回执' : '保存凭据'),
                ),
              ),
              if (overwriteReview && unknown) ...[
                _notice('原服务只提供是否已配置，不能确认此前填写内容。再次保存将以当前填写内容覆盖此共享引用。'),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PocketButton.tonal(
                        onPressed: () =>
                            setState(() => overwriteReview = false),
                        child: const Text('继续核对'),
                      ),
                      PocketButton(
                        onPressed: !available || row.draft.isEmpty
                            ? null
                            : () {
                                setState(() => overwriteReview = false);
                                unawaited(
                                  controller.save(
                                    row.reference,
                                    acknowledgeUnknown: true,
                                  ),
                                );
                              },
                        child: const Text('确认重新保存'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          PocketSection(
            children: [
              PocketRow(
                icon: Icons.delete_outline_rounded,
                title: '移除保存的凭据',
                subtitle: '保留配置中的引用名称，使用此引用的功能可能需要重新授权。',
                onTap: available && row.status?.configured == true
                    ? () => setState(() => removalReview = true)
                    : null,
              ),
              if (removalReview) ...[
                _notice('确认移除 ${row.reference}？所有使用此引用的功能都会受到影响。'),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PocketButton.tonal(
                        onPressed: () => setState(() => removalReview = false),
                        child: const Text('保留凭据'),
                      ),
                      PocketButton(
                        key: const ValueKey('credential-confirm-remove'),
                        onPressed: !available
                            ? null
                            : () {
                                setState(() => removalReview = false);
                                unawaited(
                                  controller.remove(
                                    row.reference,
                                    confirmed: true,
                                  ),
                                );
                              },
                        child: const Text('确认移除'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
