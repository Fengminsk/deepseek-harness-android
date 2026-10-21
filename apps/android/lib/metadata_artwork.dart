import 'dart:typed_data';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

/// Displays the original DSH metadata image without requesting a URL or file.
/// The Host admits at most 256 KiB of SVG, PNG, JPEG or WebP per icon.
class MetadataArtwork extends StatefulWidget {
  const MetadataArtwork({
    super.key,
    required this.source,
    this.fallback = Icons.extension_outlined,
    this.size = 36,
  });

  final Object? source;
  final IconData fallback;
  final double size;

  @override
  State<MetadataArtwork> createState() => _MetadataArtworkState();
}

class _MetadataArtworkState extends State<MetadataArtwork> {
  ({String type, Uint8List bytes})? _image;

  @override
  void initState() {
    super.initState();
    _image = _decode(widget.source);
  }

  @override
  void didUpdateWidget(MetadataArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _image = _decode(widget.source);
  }

  static ({String type, Uint8List bytes})? _decode(Object? source) {
    const maxBytes = 256 * 1024;
    if (source is! String || source.length > (maxBytes * 4 / 3).ceil() + 100) {
      return null;
    }
    try {
      final data = UriData.parse(source);
      if (!data.isBase64 ||
          !const {
            'image/svg+xml',
            'image/png',
            'image/jpeg',
            'image/webp',
          }.contains(data.mimeType)) {
        return null;
      }
      final bytes = data.contentAsBytes();
      if (bytes.isEmpty || bytes.length > maxBytes) return null;
      return (type: data.mimeType, bytes: bytes);
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final iconSize = IconTheme.of(context).size ?? 22.0;
    Widget fallback() => Icon(
      widget.fallback,
      size: iconSize > widget.size ? widget.size : iconSize,
    );
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: widget.size,
        child: image == null
            ? fallback()
            : image.type == 'image/svg+xml'
            ? SvgPicture.memory(
                image.bytes,
                key: ValueKey(widget.source),
                width: widget.size,
                height: widget.size,
                fit: BoxFit.contain,
                theme: SvgTheme(
                  currentColor:
                      IconTheme.of(context).color ??
                      Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                placeholderBuilder: (_) => fallback(),
                errorBuilder: (_, _, _) => fallback(),
              )
            : Image.memory(
                image.bytes,
                key: ValueKey(widget.source),
                width: widget.size,
                height: widget.size,
                fit: BoxFit.contain,
                cacheWidth:
                    (widget.size * MediaQuery.devicePixelRatioOf(context))
                        .ceil(),
                cacheHeight:
                    (widget.size * MediaQuery.devicePixelRatioOf(context))
                        .ceil(),
                errorBuilder: (_, _, _) => fallback(),
              ),
      ),
    );
  }
}

/// Exact configured entry IDs; unknown third-party entries retain a neutral glyph.
IconData configurationIcon(String namespace) => switch (namespace) {
  'session-log-deepseek' => Icons.history_rounded,
  'agent-default-model' ||
  'subagent-model-selection-settings' => Icons.model_training_rounded,
  'llm-deepseek' || 'llm-deepseek-account' || 'llm-pi-ai' => Icons.hub_outlined,
  'subagent' => Icons.group_work_outlined,
  'web' || 'web-deepseek-api' => Icons.language_rounded,
  'web-search-deepseek' || 'web-search-exa' => Icons.search_rounded,
  'web-fetch-http' => Icons.travel_explore_rounded,
  'android-runtime' => Icons.phone_android_rounded,
  'ui-settings-account' => Icons.account_circle_outlined,
  'ui-theme' => Icons.palette_outlined,
  'ui-settings' => Icons.code_rounded,
  'ui-conversation' || 'ui-chat' => Icons.chat_bubble_outline_rounded,
  _ => Icons.tune_rounded,
};

Widget configurationArtwork(Map<String, dynamic> descriptor) => MetadataArtwork(
  source: (descriptor['display'] as Map?)?['icon'],
  fallback: configurationIcon('${descriptor['ns'] ?? ''}'),
);

Widget pluginArtwork(Map<String, dynamic> item, {double size = 36}) =>
    MetadataArtwork(
      source: (item['meta'] as Map?)?['icon'],
      fallback: switch (item['moduleName'] ?? item['name']) {
        '@minnnng/dsh-android-runtime' => Icons.phone_android_rounded,
        '@deepseek-ai/dsh-base' => Icons.hub_outlined,
        '@deepseek-ai/dsh-web-app' => Icons.language_rounded,
        '@deepseek-ai/dsh-headless' => Icons.terminal_rounded,
        '@deepseek-ai/dsh-acp-app' ||
        '@deepseek-ai/dsh-sdk-app' ||
        '@deepseek-ai/dsh-sdk-minimal' => Icons.code_rounded,
        _ => Icons.extension_outlined,
      },
      size: size,
    );
