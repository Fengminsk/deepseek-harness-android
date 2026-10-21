import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'models.dart' show ModelDraftGuard;
import 'ui.dart';

/// A document owns only a local text buffer. Returning text never writes a
/// service: the calling form keeps its revision, validation and save workflow.
class TextDocumentPage extends StatefulWidget {
  const TextDocumentPage({
    super.key,
    required this.title,
    required this.text,
    this.readOnly = true,
    this.monospace = false,
    this.helperText,
    this.fieldKey,
    this.editingState,
    this.canEdit,
    this.validate,
    this.selectable = false,
    this.obscureText = false,
    this.keyboardType = TextInputType.multiline,
  });
  final String title, text;
  final bool readOnly, monospace;
  final String? helperText;
  final Key? fieldKey;
  final Listenable? editingState;
  final bool Function()? canEdit;
  final String? Function(String)? validate;

  /// Read-only explanations are plain text. Data/log viewers can explicitly
  /// enable selection and the copy action.
  final bool selectable;
  final bool obscureText;
  final TextInputType keyboardType;

  @override
  State<TextDocumentPage> createState() => _TextDocumentPageState();
}

class _TextDocumentPageState extends State<TextDocumentPage> {
  late final input = TextEditingController(text: widget.text);
  String? error;
  bool copied = false;
  bool revealSecret = false;
  bool get editable => !widget.readOnly && (widget.canEdit?.call() ?? true);

  @override
  void initState() {
    super.initState();
    widget.editingState?.addListener(ownerChanged);
  }

  void ownerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.editingState?.removeListener(ownerChanged);
    input.dispose();
    super.dispose();
  }

  void finish() {
    if (!editable) return;
    final failure = widget.validate?.call(input.text);
    if (failure != null) {
      setState(() => error = failure);
      return;
    }
    Navigator.of(context).pop(input.text);
  }

  @override
  Widget build(BuildContext context) => ModelDraftGuard(
    hasEdits: () => !widget.readOnly && input.text != widget.text,
    child: PocketScaffold(
      title: Text(widget.title),
      trailing: widget.readOnly
          ? widget.selectable && !widget.obscureText
                ? GlassButton(
                    icon: copied ? Icons.check_rounded : Icons.copy_rounded,
                    label: copied ? '已复制' : '复制全文',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: input.text));
                      if (mounted) setState(() => copied = true);
                    },
                  )
                : null
          : GlassButton(
              icon: Icons.check_rounded,
              label: '完成编辑',
              solid: true,
              onPressed: editable ? finish : null,
            ),
      // The body fills the viewport even when a short document leaves a large
      // blank area. Child text/selection gestures still win their own taps.
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: PocketList(
          children: [
            if (widget.readOnly && !widget.selectable)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  widget.obscureText ? '凭据内容已隐藏' : widget.text,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontFamily: widget.monospace ? 'monospace' : null,
                    height: 1.6,
                  ),
                ),
              )
            else
              TextDocumentField(
                fieldKey: widget.fieldKey,
                controller: input,
                readOnly: !editable,
                monospace: widget.monospace,
                sensitive: widget.obscureText,
                obscureText: widget.obscureText && !revealSecret,
                keyboardType: widget.keyboardType,
                errorText: error,
                onChanged: (_) => setState(() => error = null),
              ),
            if (widget.obscureText && !widget.readOnly)
              PocketSwitchRow(
                title: const Text('显示凭据'),
                value: revealSecret,
                onChanged: (value) => setState(() => revealSecret = value),
              ),
            if (widget.helperText != null || !widget.readOnly && !editable)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: Text(
                  !widget.readOnly && !editable
                      ? '当前暂不能完成编辑，输入已保留。连接恢复后可继续。'
                      : widget.helperText!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// One field grows with its contents. The page scrolls, rather than constraining
/// long text to a second fixed-height scroll area inside the page.
class TextDocumentField extends StatelessWidget {
  const TextDocumentField({
    super.key,
    required this.controller,
    this.fieldKey,
    this.readOnly = false,
    this.monospace = false,
    this.errorText,
    this.onChanged,
    this.hintText,
    this.keyboardType = TextInputType.multiline,
    this.sensitive = false,
    this.obscureText = false,
  });
  final TextEditingController controller;
  final Key? fieldKey;
  final bool readOnly, monospace;
  final String? errorText, hintText;
  final ValueChanged<String>? onChanged;
  final TextInputType keyboardType;
  final bool sensitive, obscureText;

  @override
  Widget build(BuildContext context) => TextField(
    key: fieldKey,
    controller: controller,
    readOnly: readOnly,
    minLines: 1,
    maxLines: sensitive ? 1 : null,
    keyboardType: sensitive ? TextInputType.visiblePassword : keyboardType,
    obscureText: obscureText,
    enableIMEPersonalizedLearning: !sensitive,
    textCapitalization: TextCapitalization.none,
    autocorrect: false,
    enableSuggestions: false,
    // Obscured fields already suppress copy/cut. Keep selection enabled so
    // credentials can be pasted and their insertion point can be adjusted.
    enableInteractiveSelection: true,
    // Flutter's default outside action deliberately keeps focus for touch.
    // Document editors use the same dismissal rule for touch and mouse.
    onTapOutside: (_) => FocusScope.of(context).unfocus(),
    style: Theme.of(context).textTheme.bodyLarge
        ?.copyWith(fontFamily: monospace ? 'monospace' : null, height: 1.55),
    decoration: InputDecoration(errorText: errorText, hintText: hintText),
    onChanged: readOnly ? null : onChanged,
  );
}

class TextDocumentRow extends StatelessWidget {
  const TextDocumentRow({
    super.key,
    required this.title,
    required this.text,
    this.subtitle,
    this.icon = Icons.description_outlined,
    this.monospace = false,
    this.helperText,
    this.selectable = false,
  });
  final String title, text;
  final String? subtitle, helperText;
  final IconData icon;
  final bool monospace;
  final bool selectable;
  @override
  Widget build(BuildContext context) => PocketRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    onTap: () => Navigator.of(context).push<void>(
      PocketRoute(
        builder: (_) => TextDocumentPage(
          title: title,
          text: text,
          monospace: monospace,
          helperText: helperText,
          selectable: selectable,
        ),
      ),
    ),
  );
}
