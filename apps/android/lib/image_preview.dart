import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

const pocketImageMediaTypes = {
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
};

// These match the original attachment owner's defaults. Preview never admits
// a prompt or changes that owner's configured upload/normalization policy.
const pocketPreviewMaxBytes = 20 * 1024 * 1024;
const pocketPreviewMaxPixels = 64000000;
const pocketPreviewMaxDimension = 8192;
const _decodedPixelBudget = 4 * 1024 * 1024;

class PocketImagePayload {
  const PocketImagePayload({
    required this.bytes,
    required this.mediaType,
    required this.name,
    this.width,
    this.height,
  });
  final Uint8List bytes;
  final String mediaType, name;
  final int? width, height;
}

/// Each source is bound to one conversation. No file/network image provider is
/// accepted; historical images must be authorized by the original Session log.
class PocketImageSource {
  const PocketImageSource({required this.name, required this.load});
  final String name;
  final Future<PocketImagePayload> Function() load;

  factory PocketImageSource.session(
    RuntimeController runtime,
    String sessionId,
    Json attachment,
  ) {
    final attachmentId = attachment['attachmentId'];
    final name = attachment['name'] is String
        ? attachment['name'] as String
        : '图片附件';
    return PocketImageSource(
      name: name,
      load: () async {
        if (sessionId.isEmpty ||
            attachmentId is! String ||
            attachmentId.isEmpty) {
          throw const FormatException('这张图片缺少有效的会话引用。');
        }
        final generation = runtime.connectionGeneration;
        final value = await runtime.call('api.call', {
          'namespace': 'session',
          'method': 'attachment',
          'args': {
            'request': {'sessionId': sessionId, 'attachmentId': attachmentId},
          },
        });
        if (generation != runtime.connectionGeneration) {
          throw StateError('服务连接已变化，请重试读取图片。');
        }
        if (value is! Json || value['attachment'] is! Json) {
          throw const FormatException('图片读取结果不完整。');
        }
        final ref = value['attachment'] as Json;
        if (ref['attachmentId'] != attachmentId) {
          throw const FormatException('图片引用不匹配。');
        }
        final payload = await _payload(
          ref,
          value['data'],
          name,
          dimensionsRequired: true,
        );
        if (generation != runtime.connectionGeneration) {
          throw StateError('服务连接已变化，请重试读取图片。');
        }
        return payload;
      },
    );
  }

  factory PocketImageSource.draft(
    RuntimeController runtime,
    String sessionId,
    String id,
    String name,
  ) => PocketImageSource(
    name: name,
    load: () async {
      if (sessionId.isEmpty || id.isEmpty) {
        throw const FormatException('图片草稿不可用。');
      }
      final generation = runtime.connectionGeneration;
      final value = await runtime.call('attachments.preview', {
        'sessionId': sessionId,
        'id': id,
      });
      if (generation != runtime.connectionGeneration) {
        throw StateError('服务连接已变化，请重试读取图片。');
      }
      if (value is! Json || value['id'] != id || value['kind'] != 'image') {
        throw const FormatException('图片草稿读取结果不匹配。');
      }
      final payload = await _payload(value, value['data'], name);
      if (generation != runtime.connectionGeneration) {
        throw StateError('服务连接已变化，请重试读取图片。');
      }
      return payload;
    },
  );
}

Future<PocketImagePayload> _payload(
  Json metadata,
  dynamic data,
  String name, {
  bool dimensionsRequired = false,
}) async {
  final count = metadata['bytes'];
  final mediaType = metadata['mediaType'];
  if (count is! int || count < 1 || count > pocketPreviewMaxBytes) {
    throw const FormatException('图片超过预览大小限制（20 MiB），或内容为空。');
  }
  if (!pocketImageMediaTypes.contains(mediaType)) {
    throw const FormatException('暂不支持预览此图片格式。');
  }
  // Check the encoded bound before allocating decoded bytes. Canonical base64
  // also excludes data URLs, local paths and ambiguous whitespace encodings.
  if (data is! String || data.length != ((count + 2) ~/ 3) * 4) {
    throw const FormatException('图片内容长度不匹配。');
  }
  final width = metadata['width'], height = metadata['height'];
  if (dimensionsRequired || width != null || height != null) {
    _checkDimensions(width, height);
  }
  final bytes = await compute(_decodeImageBytes, (data: data, count: count));
  return PocketImagePayload(
    bytes: bytes,
    mediaType: mediaType as String,
    name: metadata['name'] is String ? metadata['name'] as String : name,
    width: width as int?,
    height: height as int?,
  );
}

Uint8List _decodeImageBytes(({String data, int count}) wire) {
  final bytes = base64Decode(wire.data);
  if (bytes.length != wire.count || base64Encode(bytes) != wire.data) {
    throw const FormatException('图片内容不完整。');
  }
  return bytes;
}

void _checkDimensions(dynamic width, dynamic height) {
  if (width is! int ||
      height is! int ||
      width < 1 ||
      height < 1 ||
      width > pocketPreviewMaxDimension ||
      height > pocketPreviewMaxDimension ||
      width * height > pocketPreviewMaxPixels) {
    throw const FormatException('图片尺寸超过预览限制（单边 8192 像素，总计 6400 万像素）。');
  }
}

class _PreparedImage {
  const _PreparedImage(this.payload, this.width, this.height, this.provider);
  final PocketImagePayload payload;
  final int width, height;
  final ImageProvider provider;
}

Future<_PreparedImage> _prepareImage(PocketImagePayload payload) async {
  if (payload.bytes.isEmpty ||
      payload.bytes.length > pocketPreviewMaxBytes ||
      !pocketImageMediaTypes.contains(payload.mediaType)) {
    throw const FormatException('图片内容无效或超过预览大小限制。');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(payload.bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width, height = descriptor.height;
    _checkDimensions(width, height);
    if (payload.width != null &&
        (payload.width != width || payload.height != height)) {
      throw const FormatException('图片实际尺寸与附件信息不匹配。');
    }
    final scale = math.min(
      1.0,
      math.sqrt(_decodedPixelBudget / (width * height)),
    );
    final provider = ResizeImage.resizeIfNeeded(
      math.max(1, (width * scale).floor()),
      math.max(1, (height * scale).floor()),
      MemoryImage(payload.bytes),
    );
    return _PreparedImage(payload, width, height, provider);
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<void> showPocketSessionImage(
  BuildContext context,
  RuntimeController runtime,
  String sessionId,
  Json attachment,
) => Navigator.of(context).push<void>(
  PocketRoute<void>(
    builder: (_) => PocketImagePreview(
      source: PocketImageSource.session(runtime, sessionId, attachment),
    ),
  ),
);

Future<void> showPocketDraftImage(
  BuildContext context,
  RuntimeController runtime,
  String sessionId,
  String id,
  String name,
) => Navigator.of(context).push<void>(
  PocketRoute<void>(
    builder: (_) => PocketImagePreview(
      source: PocketImageSource.draft(runtime, sessionId, id, name),
    ),
  ),
);

class PocketImagePreview extends StatefulWidget {
  const PocketImagePreview({super.key, required this.source});
  final PocketImageSource source;
  @override
  State<PocketImagePreview> createState() => _PocketImagePreviewState();
}

class _PocketImagePreviewState extends State<PocketImagePreview>
    with SingleTickerProviderStateMixin {
  final transform = TransformationController();
  late final AnimationController zoom =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 220),
      )..addListener(() {
        if (zoomFrames != null) transform.value = zoomFrames!.value;
      });
  Animation<Matrix4>? zoomFrames;
  Offset doubleTapPosition = Offset.zero;
  _PreparedImage? image;
  String? error;
  int epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(PocketImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) unawaited(load());
  }

  Future<void> load() async {
    final request = ++epoch;
    zoom.stop();
    transform.value = Matrix4.identity();
    final previous = image;
    setState(() {
      image = null;
      error = null;
    });
    if (previous != null) unawaited(previous.provider.evict());
    try {
      final payload = await widget.source.load();
      if (!mounted || request != epoch) return;
      final loaded = await _prepareImage(payload);
      if (!mounted || request != epoch) {
        unawaited(loaded.provider.evict());
        return;
      }
      setState(() => image = loaded);
    } catch (failure) {
      if (!mounted || request != epoch) return;
      setState(
        () => error = failure is FormatException
            ? failure.message
            : '暂时无法读取这张图片，请重试。',
      );
    }
  }

  void animateTo(Matrix4 target) {
    zoom.stop();
    if (MediaQuery.disableAnimationsOf(context)) {
      transform.value = target;
      return;
    }
    zoomFrames = Matrix4Tween(
      begin: transform.value.clone(),
      end: target,
    ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(zoom);
    zoom.forward(from: 0);
  }

  void toggleZoom() {
    if (transform.value.getMaxScaleOnAxis() > 1.01) {
      animateTo(Matrix4.identity());
      return;
    }
    const scale = 2.5;
    animateTo(
      Matrix4.identity()
        ..setEntry(0, 0, scale)
        ..setEntry(1, 1, scale)
        ..setEntry(0, 3, -doubleTapPosition.dx * (scale - 1))
        ..setEntry(1, 3, -doubleTapPosition.dy * (scale - 1)),
    );
  }

  Widget failure(String message) => PocketEmpty(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.broken_image_outlined,
          size: 42,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 16),
        const Text(
          '图片未能打开',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        PocketButton.tonal(
          onPressed: () => unawaited(load()),
          child: const Text('重新加载'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final loaded = image;
    return PocketScaffold(
      title: Text(loaded?.payload.name ?? widget.source.name),
      leading: GlassButton(
        icon: Icons.close_rounded,
        label: '关闭图片',
        onPressed: () => Navigator.maybePop(context),
      ),
      trailing: loaded == null
          ? null
          : GlassButton(
              icon: Icons.fit_screen_rounded,
              label: '还原图片大小',
              onPressed: () => animateTo(Matrix4.identity()),
            ),
      bottom: loaded == null
          ? null
          : Center(
              child: GlassSurface(
                radius: 24,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  child: Text(
                    '${loaded.width} × ${loaded.height} · 双指缩放，双击放大',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
      body: error != null
          ? failure(error!)
          : loaded == null
          ? PocketEmpty(
              child: Semantics(liveRegion: true, child: const Text('正在加载图片…')),
            )
          : GestureDetector(
              onDoubleTapDown: (details) =>
                  doubleTapPosition = details.localPosition,
              onDoubleTap: toggleZoom,
              child: InteractiveViewer(
                key: const ValueKey('pocket-image-zoom'),
                transformationController: transform,
                minScale: 1,
                maxScale: 8,
                onInteractionStart: (_) => zoom.stop(),
                child: SizedBox.expand(
                  child: Image(
                    key: ValueKey(loaded),
                    image: loaded.provider,
                    fit: BoxFit.contain,
                    semanticLabel: loaded.payload.name,
                    frameBuilder: (_, child, frame, synchronous) =>
                        frame != null || synchronous
                        ? child
                        : const Center(child: Text('正在解码图片…')),
                    errorBuilder: (_, _, _) => failure('图片内容无法解码，请重试。'),
                  ),
                ),
              ),
            ),
    );
  }

  @override
  void dispose() {
    epoch++;
    zoom.dispose();
    transform.dispose();
    final previous = image;
    if (previous != null) unawaited(previous.provider.evict());
    super.dispose();
  }
}
