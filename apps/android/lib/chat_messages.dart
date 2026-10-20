import 'dart:async';
import 'dart:convert';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_projection.dart';
import 'runtime.dart';
import 'tool_activity.dart';
import 'ui.dart';

typedef ChatOpenLink = Future<void> Function(Uri uri);
typedef ChatOpenAttachment = Future<void> Function(Json attachment);

/// Only ordinary web destinations may reach MainActivity.openUrl. Relative
/// document paths and content/file/intent URLs require an explicit file flow.
Uri? chatExternalUri(String destination) {
  if (RegExp(r'[\x00-\x20\x7f]').hasMatch(destination)) return null;
  final uri = Uri.tryParse(destination);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

/// An attempt-correlated snapshot from the original assistant stream. The
/// carrier owns accumulation and retries; rendering never joins text by guess.
class ChatLiveMessage {
  const ChatLiveMessage({
    required this.identity,
    required this.content,
    required this.turn,
    required this.step,
    this.interrupted = false,
    this.unconfirmed = false,
  });
  final String identity;
  final List<dynamic> content;
  final int turn, step;
  final bool interrupted, unconfirmed;
}

/// Lazy transcript sharing PocketScaffold's floating chrome insets.
class ChatTimeline extends StatelessWidget {
  const ChatTimeline({
    required this.sessionId,
    required this.projection,
    required this.controller,
    this.live,
    this.footer,
    this.onOpenLink,
    this.onOpenAttachment,
    super.key,
  });
  final String sessionId;
  final ChatProjection projection;
  final ScrollController controller;
  final ChatLiveMessage? live;
  final Widget? footer;
  final ChatOpenLink? onOpenLink;
  final ChatOpenAttachment? onOpenAttachment;

  @override
  Widget build(BuildContext context) {
    final rows = projection.entries;
    final stream = live;
    final showLive =
        stream != null &&
        !projection.hasFinalAssistant(turn: stream.turn, step: stream.step);
    final liveKey = showLive ? 'live:${stream.identity}' : null;
    final count = rows.length + (showLive ? 1 : 0) + (footer == null ? 0 : 1);
    return PocketList.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: count,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<(String, String)> || key.value.$1 != sessionId) {
          return null;
        }
        final identity = key.value.$2;
        if (identity == liveKey) return rows.length;
        if (identity == 'footer' && footer != null) return count - 1;
        return projection.indexOfKey(identity);
      },
      itemBuilder: (context, index) {
        if (index < rows.length) {
          final row = rows[index];
          return ChatMessage(
            key: ValueKey((sessionId, row.key)),
            entry: row,
            storageId: '$sessionId:${row.key}',
            onOpenLink: onOpenLink,
            onOpenAttachment: onOpenAttachment,
          );
        }
        if (showLive && index == rows.length) {
          return Padding(
            key: ValueKey((sessionId, liveKey!)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChatContent(
                  content: stream.content,
                  storageId: '$sessionId:$liveKey',
                  onOpenLink: onOpenLink,
                  onOpenAttachment: onOpenAttachment,
                ),
                if (stream.unconfirmed)
                  Text('回复状态待确认', style: Theme.of(context).textTheme.labelSmall)
                else if (stream.interrupted)
                  Text('回复已中断', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          );
        }
        return KeyedSubtree(
          key: ValueKey((sessionId, 'footer')),
          child: footer!,
        );
      },
    );
  }
}

class ChatMessage extends StatelessWidget {
  const ChatMessage({
    required this.entry,
    required this.storageId,
    this.onOpenLink,
    this.onOpenAttachment,
    super.key,
  });
  final ChatEntry entry;
  final String storageId;
  final ChatOpenLink? onOpenLink;
  final ChatOpenAttachment? onOpenAttachment;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    switch (entry.kind) {
      case ChatEntryKind.tool:
        return ToolActivityCard(activity: entry.tool!);
      case ChatEntryKind.systemPrompt:
      case ChatEntryKind.context:
      case ChatEntryKind.unknown:
        return _ChatDisclosure(
          storageId: storageId,
          title: entry.title ?? '上下文',
          icon: entry.kind == ChatEntryKind.systemPrompt
              ? Icons.tune_rounded
              : Icons.info_outline_rounded,
          body: (context) => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              primary: false,
              child: entry.kind == ChatEntryKind.unknown
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (entry.text != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: SelectableText(
                              entry.text!,
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                        SelectableText(_json(entry.event['data'])),
                      ],
                    )
                  : entry.text != null
                  ? SelectableText(entry.text!)
                  : ChatContent(
                      content: entry.content,
                      storageId: storageId,
                      opaqueText: true,
                      onOpenLink: onOpenLink,
                      onOpenAttachment: onOpenAttachment,
                    ),
            ),
          ),
        );
      case ChatEntryKind.command:
      case ChatEntryKind.notice:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: PocketCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  entry.title ?? '会话状态',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: entry.error ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
                if (entry.text?.isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  PocketMarkdown(data: entry.text!, onOpenLink: onOpenLink),
                ],
                if (entry.details != null)
                  _ChatDisclosure(
                    storageId: '$storageId:details',
                    title: entry.detailsTitle ?? '详情',
                    icon: Icons.history_rounded,
                    body: (_) => SelectableText(entry.details!),
                  ),
              ],
            ),
          ),
        );
      case ChatEntryKind.user:
      case ChatEntryKind.assistant:
        final user = entry.kind == ChatEntryKind.user;
        return Align(
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * (user ? .8 : 1),
            ),
            margin: const EdgeInsets.symmetric(vertical: 10),
            padding: EdgeInsets.symmetric(
              horizontal: user ? 18 : 0,
              vertical: 14,
            ),
            decoration: user
                ? BoxDecoration(
                    color: colors.surfaceContainer,
                    borderRadius: BorderRadius.circular(24),
                  )
                : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ChatContent(
                  content: entry.content,
                  storageId: storageId,
                  opaqueText: user,
                  onOpenLink: onOpenLink,
                  onOpenAttachment: onOpenAttachment,
                ),
                if (entry.interrupted)
                  Text('回复已中断', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        );
    }
  }
}

/// Blocks stay in authored order; unsupported blocks remain inspectable.
class ChatContent extends StatelessWidget {
  const ChatContent({
    required this.content,
    required this.storageId,
    this.opaqueText = false,
    this.onOpenLink,
    this.onOpenAttachment,
    super.key,
  });
  final List<dynamic> content;
  final String storageId;
  final bool opaqueText;
  final ChatOpenLink? onOpenLink;
  final ChatOpenAttachment? onOpenAttachment;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var index = 0; index < content.length; index++)
        _block(context, content[index], index),
    ],
  );

  Widget _block(BuildContext context, dynamic value, int index) {
    final block = value is Json ? value : null;
    final key = ValueKey('$storageId:block:$index');
    switch (block?['type']) {
      case 'text':
        final text = block!['text'] as String? ?? '';
        return Padding(
          key: key,
          padding: const EdgeInsets.only(bottom: 6),
          child: opaqueText
              ? SelectableText(
                  text,
                  style: const TextStyle(fontSize: 16, height: 1.6),
                )
              : PocketMarkdown(data: text, onOpenLink: onOpenLink),
        );
      case 'reasoning':
        final text = block!['text'] as String? ?? '';
        if (text.trim().isEmpty) return SizedBox.shrink(key: key);
        return _ChatDisclosure(
          key: key,
          storageId: '$storageId:reasoning:$index',
          title: '思考过程',
          icon: Icons.psychology_outlined,
          body: (context) => PocketMarkdown(data: text, onOpenLink: onOpenLink),
        );
      case 'image':
      case 'file':
        final attachment = block!['attachment'];
        return _AttachmentRow(
          key: key,
          attachment: attachment is Json ? attachment : block,
          image: block['type'] == 'image',
          onOpen: onOpenAttachment,
        );
      case 'tool-call':
        // The durable tool/call/result projection owns this protocol block.
        return SizedBox.shrink(key: key);
      default:
        return _ChatDisclosure(
          key: key,
          storageId: '$storageId:unknown:$index',
          title: '内容详情 · ${block?['type'] ?? '未知类型'}',
          icon: Icons.data_object_rounded,
          body: (context) => SelectableText(_json(value)),
        );
    }
  }
}

/// The maintained Markdown renderer receives Pocket's explicit theme. It never
/// invokes a default image loader, so model-authored paths cannot read files.
class PocketMarkdown extends StatefulWidget {
  const PocketMarkdown({required this.data, this.onOpenLink, super.key});
  final String data;
  final ChatOpenLink? onOpenLink;
  @override
  State<PocketMarkdown> createState() => _PocketMarkdownState();
}

class _PocketMarkdownState extends State<PocketMarkdown> {
  late MarkdownStyleSheet _style;
  String? _linkError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context), colors = theme.colorScheme;
    final body = theme.textTheme.bodyLarge!.copyWith(
      color: colors.onSurface,
      fontSize: 16,
      height: 1.6,
    );
    // Keep this object stable across delta-only rebuilds. MarkdownBody reparses
    // changed text, while settled rows reuse their parsed widget trees.
    _style = MarkdownStyleSheet(
      p: body,
      a: body.copyWith(
        color: colors.primary,
        decoration: TextDecoration.underline,
      ),
      h1: theme.textTheme.headlineMedium?.copyWith(color: colors.onSurface),
      h2: theme.textTheme.headlineSmall?.copyWith(color: colors.onSurface),
      h3: theme.textTheme.titleLarge?.copyWith(color: colors.onSurface),
      h4: theme.textTheme.titleMedium?.copyWith(color: colors.onSurface),
      h5: body.copyWith(fontWeight: FontWeight.w600),
      h6: body.copyWith(fontWeight: FontWeight.w600),
      strong: const TextStyle(fontWeight: FontWeight.w700),
      em: const TextStyle(fontStyle: FontStyle.italic),
      del: const TextStyle(decoration: TextDecoration.lineThrough),
      code: body.copyWith(fontFamily: 'monospace', fontSize: 14),
      codeblockPadding: const EdgeInsets.all(14),
      codeblockDecoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      blockquote: body.copyWith(color: colors.onSurfaceVariant),
      blockquotePadding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
      ),
      listBullet: body,
      listIndent: 22,
      tableHead: body.copyWith(fontWeight: FontWeight.w600),
      tableBody: body,
      tableBorder: TableBorder.all(color: colors.outlineVariant),
      tableCellsPadding: const EdgeInsets.all(8),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      blockSpacing: 12,
    );
  }

  Future<void> _open(String destination) async {
    final uri = chatExternalUri(destination);
    if (uri == null || widget.onOpenLink == null) {
      setState(
        () => _linkError = uri == null
            ? '此链接不能直接打开；本地文件请通过文件授权入口访问。'
            : '当前无法打开链接。',
      );
      return;
    }
    try {
      await widget.onOpenLink!(uri);
      if (mounted) setState(() => _linkError = null);
    } catch (_) {
      // The opener owns platform diagnostics; avoid echoing a URL's secrets.
      if (mounted) setState(() => _linkError = '链接打开失败，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MarkdownBody(
        data: widget.data,
        selectable: true,
        styleSheet: _style,
        onTapLink: (_, href, _) {
          if (href != null) unawaited(_open(href));
        },
        checkboxBuilder: (checked) => Icon(
          checked ? Icons.check_box_outlined : Icons.check_box_outline_blank,
          size: 18,
          color: Theme.of(context).colorScheme.primary,
        ),
        imageBuilder: (uri, title, alt) => PocketTile(
          leading: const Icon(Icons.image_outlined),
          title: Text(alt?.isNotEmpty == true ? alt! : title ?? '图片链接'),
          subtitle: Text(
            chatExternalUri(uri.toString()) == null ? '需要通过文件入口访问' : '点击打开图片链接',
          ),
          onTap: () => unawaited(_open(uri.toString())),
        ),
      ),
      if (_linkError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _linkError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );
}

class _AttachmentRow extends StatefulWidget {
  const _AttachmentRow({
    super.key,
    required this.attachment,
    required this.image,
    this.onOpen,
  });
  final Json attachment;
  final bool image;
  final ChatOpenAttachment? onOpen;
  @override
  State<_AttachmentRow> createState() => _AttachmentRowState();
}

class _AttachmentRowState extends State<_AttachmentRow> {
  String? error;
  bool busy = false;
  Future<void> open() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onOpen!(widget.attachment);
    } catch (_) {
      if (mounted) setState(() => error = '附件打开失败，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PocketTile(
    leading: Icon(
      widget.image ? Icons.image_outlined : Icons.attach_file_rounded,
    ),
    title: Text(
      '${widget.attachment['name'] ?? (widget.image ? '图片附件' : '文件附件')}',
    ),
    subtitle: Text(
      error ??
          (busy
              ? '正在打开…'
              : widget.onOpen == null
              ? '附件已随会话保存'
              : '查看附件'),
    ),
    onTap: widget.onOpen == null || busy ? null : open,
  );
}

/// Only expanded content is built. PageStorage preserves disclosures across
/// lazy row eviction without keeping every long conversation row alive.
class _ChatDisclosure extends StatefulWidget {
  const _ChatDisclosure({
    super.key,
    required this.storageId,
    required this.title,
    required this.icon,
    required this.body,
  });
  final String storageId, title;
  final IconData icon;
  final WidgetBuilder body;
  @override
  State<_ChatDisclosure> createState() => _ChatDisclosureState();
}

class _ChatDisclosureState extends State<_ChatDisclosure> {
  bool expanded = false;
  bool restored = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!restored) {
      expanded =
          PageStorage.maybeOf(context)
              ?.readState(context, identifier: widget.storageId) ==
          true;
      restored = true;
    }
  }

  void toggle() {
    setState(() => expanded = !expanded);
    PageStorage.maybeOf(context)
        ?.writeState(context, expanded, identifier: widget.storageId);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: PocketCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PocketRow(
            icon: widget.icon,
            title: widget.title,
            onTap: toggle,
            trailing: AnimatedRotation(
              turns: expanded ? .25 : 0,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              child: const Icon(Icons.chevron_right_rounded),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: widget.body(context),
            ),
        ],
      ),
    ),
  );
}

String _json(dynamic value) =>
    const JsonEncoder.withIndent('  ').convert(value);
