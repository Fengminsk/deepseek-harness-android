import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

/// Decodes only bounded native App artwork; legacy rows retain a local glyph.
class NetworkProxyToolIcon extends StatefulWidget {
  const NetworkProxyToolIcon({super.key, this.base64, this.size = 28});
  final String? base64;
  final double size;
  @override
  State<NetworkProxyToolIcon> createState() => _NetworkProxyToolIconState();
}

class _NetworkProxyToolIconState extends State<NetworkProxyToolIcon> {
  Uint8List? bytes;
  void read() {
    final value = widget.base64;
    bytes = null;
    if (value == null || value.isEmpty || value.length > 256 * 1024) return;
    try {
      bytes = base64Decode(value);
    } on FormatException {
      /* Invalid optional artwork falls back to the local icon. */
    }
  }

  @override
  void initState() {
    super.initState();
    read();
  }

  @override
  void didUpdateWidget(covariant NetworkProxyToolIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.base64 != widget.base64) read();
  }

  Widget fallback() => Icon(Icons.vpn_key_outlined, size: widget.size);
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: bytes == null
        ? fallback()
        : ClipRRect(
            borderRadius: BorderRadius.circular(widget.size * .24),
            child: Image.memory(
              bytes!,
              fit: BoxFit.contain,
              cacheWidth: 96,
              cacheHeight: 96,
              errorBuilder: (_, error, stack) => fallback(),
            ),
          ),
  );
}
