import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'configuration_value_row.dart';
import 'confirmation.dart';
import 'credentials_data.dart';
import 'text_document_page.dart';
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
  String reference = '';
  bool loading = false;
  String? error;

  Future<void> editReference() async {
    final value = await Navigator.of(context).push<String>(
      PocketRoute(
        builder: (_) => TextDocumentPage(
          title: '凭据引用名称',
          text: reference,
          readOnly: false,
          fieldKey: const ValueKey('credential-reference-input'),
          helperText: '例如 DEEPSEEK_API_KEY。这里只填写引用名称，不填写密钥。',
          validate: (value) => validCredentialReference(value)
              ? null
              : '使用字母或下划线开头，后续可包含字母、数字、下划线。',
        ),
      ),
    );
    if (mounted && value != null) {
      setState(() {
        reference = value;
        error = null;
      });
    }
  }

  Future<void> open() async {
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
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('指定凭据引用'),
    body: PocketList(
      children: [
        PocketSection(
          children: [
            ConfigurationValueRow(
              key: const ValueKey('credential-reference-row'),
              title: '引用名称',
              summary: reference.isEmpty ? '未填写' : reference,
              onTap: loading ? null : editReference,
            ),
          ],
        ),
        _notice('填写工具配置中声明的引用名称。查看引用不会修改工具配置。'),
        if (error != null) _notice(error!),
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
  CredentialEntry get row => widget.controller.entry(widget.reference);
  bool removalReview = false, overwriteReview = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> editCredential() async {
    final revision = row.draftRevision;
    bool editable() =>
        row.write?.inFlight != true && row.draftRevision == revision;
    if (!editable()) return;
    final value = await Navigator.of(context).push<String>(
      PocketRoute(
        builder: (_) => TextDocumentPage(
          title: '新凭据',
          text: row.draft,
          readOnly: false,
          obscureText: true,
          fieldKey: const ValueKey('credential-value-input'),
          helperText: '已有凭据不会回填。完成后只保留本次输入，返回管理页再保存。',
          editingState: widget.controller,
          canEdit: editable,
        ),
      ),
    );
    if (!mounted || value == null || !editable()) return;
    widget.controller.edit(widget.reference, value);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void dismissReview() => setState(() {
    removalReview = false;
    overwriteReview = false;
  });

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final available = controller.canWrite(row);
    final unknown = row.write?.state == 'unconfirmed';
    final reviewing = removalReview || overwriteReview;
    return PopScope(
      canPop: !reviewing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && reviewing) dismissReview();
      },
      child: PocketConfirmationLayer(
        confirmation: removalReview
            ? PocketConfirmation(
                title: '移除保存的凭据？',
                message: '确认移除 ${row.reference}？所有使用此引用的功能都会受到影响。',
                secondaryLabel: '保留凭据',
                onSecondary: dismissReview,
                primaryLabel: '确认移除',
                onPrimary: !available
                    ? null
                    : () {
                        dismissReview();
                        unawaited(
                          controller.remove(row.reference, confirmed: true),
                        );
                      },
              )
            : overwriteReview
            ? PocketConfirmation(
                title: '重新保存凭据？',
                message: '当前配置状态不能证明此前输入已写入。再次保存将用本次填写内容覆盖此共享引用。',
                secondaryLabel: '继续核对',
                onSecondary: dismissReview,
                primaryLabel: '确认重新保存',
                onPrimary: !available || row.draft.isEmpty || !unknown
                    ? null
                    : () {
                        dismissReview();
                        unawaited(
                          controller.save(
                            row.reference,
                            acknowledgeUnknown: true,
                          ),
                        );
                      },
              )
            : null,
        child: PocketScaffold(
          title: const Text('管理凭据'),
          trailing: GlassButton(
            icon: Icons.refresh_rounded,
            label: '核对凭据状态',
            onPressed: row.reading
                ? null
                : () => controller.readReference(row.reference),
          ),
          body: PocketList(
            key: PageStorageKey('credential-${row.reference}'),
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
                  ConfigurationValueRow(
                    key: const ValueKey('credential-value-row'),
                    title: '新凭据',
                    summary: row.draft.isEmpty ? '未填写' : '已填写',
                    protected: true,
                    onTap: row.write?.inFlight == true ? null : editCredential,
                  ),
                ],
              ),
              _notice('已有密钥不会显示。本次填写内容只保留在 App 内存中，留空不更改。'),
              if (row.readError != null) _notice(row.readError!),
              if (row.write?.notice != null) _notice(row.write!.notice!),
              PocketButton(
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
              PocketSection(
                title: '使用位置',
                children: [
                  if (row.uses.isEmpty)
                    const PocketRow(
                      icon: Icons.link_rounded,
                      title: '配置中未列出使用位置',
                      subtitle: '其他手工配置也可能使用此引用。',
                    )
                  else
                    for (final use in row.uses)
                      PocketRow(
                        icon: Icons.link_rounded,
                        title: use.namespace,
                        subtitle: use.path.join('.'),
                      ),
                ],
              ),
              if (!controller.catalogFresh) _notice('使用位置尚未同步，请返回目录刷新核对。'),
              PocketSection(
                children: [
                  PocketRow(
                    icon: Icons.delete_outline_rounded,
                    title: '移除保存的凭据',
                    subtitle: '保留引用名称，使用它的功能可能需要重新授权。',
                    onTap: available && row.status?.configured == true
                        ? () => setState(() => removalReview = true)
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
