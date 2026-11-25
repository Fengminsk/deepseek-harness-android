import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'attachment_surface.dart';
import 'image_preview.dart';
import 'runtime.dart';
import 'ui.dart';

class AttachmentDraft {
  AttachmentDraft({
    required this.id,
    required this.name,
    required this.bytes,
    required this.mediaType,
    this.previewPath,
  });

  final String id, mediaType;
  final String? previewPath;
  String name;
  int bytes;
  String status = 'uploading';
  String? error;
  bool removing = false;

  bool get isImage => pocketImageMediaTypes.contains(mediaType);
}

/// One composer draft owns each native selection, including while a different chat is open.
///
/// 调用面是本地运行时或远程连接面；本类只依赖 [AttachmentCallSurface]，因此上传
/// 状态机、重试与移除语义在本地与远程完全一致（见
/// `docs/remote-dsh/p5-remaining-design.md` §3.1、§3.4.5）。
class AttachmentDrafts extends ChangeNotifier {
  AttachmentDrafts(this.surface)
    : _generation = surface.connectionGeneration,
      _ready = surface.ready {
    surface.addListener(_connectionChanged);
  }

  /// 上传与释放请求的出口。
  final AttachmentCallSurface surface;
  final _drafts = <String, List<AttachmentDraft>>{};
  final _messages = <String, String>{};
  String? pickingSession;
  bool _closed = false;
  int _generation;
  bool _ready;

  /// 旧草稿缺少设备缓存路径时，本地会话仍可向运行时读取图片。
  RuntimeController? get localRuntime =>
      surface is RuntimeController ? surface as RuntimeController : null;

  void _connectionChanged() {
    if (_closed) return;
    final changed = _generation != surface.connectionGeneration;
    final disconnected = _ready && !surface.ready;
    _generation = surface.connectionGeneration;
    _ready = surface.ready;
    if (changed || disconnected) invalidateReceipts();
  }

  List<AttachmentDraft> items(String sessionId) =>
      List.unmodifiable(_drafts[sessionId] ?? const <AttachmentDraft>[]);
  String? message(String sessionId) => _messages[sessionId];
  bool ready(String sessionId) =>
      pickingSession != sessionId &&
      items(sessionId)
          .every((item) => item.status == 'ready' && !item.removing);
  List<String> snapshotIds(String sessionId) {
    if (!ready(sessionId)) throw StateError('附件尚未准备完成，请重试或移除失败项。');
    return items(sessionId).map((item) => item.id).toList(growable: false);
  }

  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<void> pick(String sessionId) async {
    if (_closed || pickingSession != null) return;
    pickingSession = sessionId;
    _messages.remove(sessionId);
    _changed();
    try {
      final raw = await RuntimeController.channel.invokeMethod<String>(
        'attachment.pick',
      );
      final result = jsonDecode(raw!) as Json;
      if (result['cancelled'] == true) return;
      final selections = (result['items'] as List? ?? const []).cast<Json>();
      if (_closed) {
        for (final selection in selections) {
          await surface.call('attachments.release', {
            'sessionId': sessionId,
            'id': selection['id'],
          });
        }
        return;
      }
      final added = selections
          .map(
            (item) => AttachmentDraft(
              id: item['id'] as String,
              name: item['name'] as String,
              bytes: (item['bytes'] as num).toInt(),
              mediaType: item['mediaType'] as String,
              previewPath: item['previewPath'] as String?,
            ),
          )
          .toList();
      _drafts.putIfAbsent(sessionId, () => []).addAll(added);
      final failures = (result['failures'] as List? ?? const []).cast<Json>();
      if (failures.isNotEmpty) {
        _messages[sessionId] = failures
            .map((failure) => '${failure['name']}: ${failure['message']}')
            .join('\n');
      }
      _changed();
      // Large ordinary files stay streamed on both sides; only one upload is active per pick.
      for (final item in added) {
        if (_closed) break;
        await _prepare(sessionId, item);
      }
    } catch (failure) {
      if (!_closed) _messages[sessionId] = '添加附件未完成，可重新选择文件。\n$failure';
    } finally {
      pickingSession = null;
      _changed();
    }
  }

  bool _contains(String sessionId, AttachmentDraft item) =>
      !_closed && (_drafts[sessionId]?.contains(item) ?? false);

  Future<void> _prepare(String sessionId, AttachmentDraft item) async {
    if (!_contains(sessionId, item) || item.removing) return;
    item.status = 'uploading';
    item.error = null;
    _changed();
    final generation = surface.connectionGeneration;
    final params = <String, dynamic>{
      'sessionId': sessionId,
      'id': item.id,
      // 远程宿主没有设备侧缓存，只有这些声明能让它命名收据并对账字节数（§3.4.2）；
      // 本地运行时直接从设备缓存读，不实现该接口，参数保持原样。
      if (surface is AttachmentMetadataSurface) ...{
        'name': item.name,
        'mediaType': item.mediaType,
        'bytes': item.bytes,
      },
    };
    try {
      final receipt = await surface.call('attachments.prepare', params) as Json;
      if (!_contains(sessionId, item) || item.removing) return;
      if (generation != surface.connectionGeneration || !surface.ready) {
        throw StateError('运行服务已重启，请重试准备此附件后发送。');
      }
      final kind = receipt['kind'];
      final validImage =
          kind == 'image' &&
          item.isImage &&
          receipt['mediaType'] == item.mediaType;
      final validFile =
          kind == 'file' &&
          !item.isImage &&
          receipt['receiptId'] is String &&
          (receipt['receiptId'] as String).isNotEmpty;
      if (receipt['id'] != item.id ||
          (!validImage && !validFile) ||
          receipt['name'] is! String ||
          (receipt['name'] as String).isEmpty ||
          receipt['bytes'] is! int ||
          (receipt['bytes'] as int) < (item.isImage ? 1 : 0)) {
        throw const FormatException('未能确认附件上传，请重试');
      }
      item.name = receipt['name'] as String;
      item.bytes = (receipt['bytes'] as num).toInt();
      item.status = 'ready';
    } catch (failure) {
      if (_contains(sessionId, item) && !item.removing) {
        item.status = 'error';
        item.error = '$failure';
      }
    }
    _changed();
  }

  Future<void> retry(String sessionId, String id) async {
    final item = items(sessionId).where((item) => item.id == id).firstOrNull;
    if (item == null || item.status == 'uploading' || item.removing) return;
    await _prepare(sessionId, item);
  }

  Future<void> remove(String sessionId, String id) async {
    final item = items(sessionId).where((item) => item.id == id).firstOrNull;
    if (item == null || item.removing) return;
    item.removing = true;
    _changed();
    try {
      await surface.call('attachments.release', {
        'sessionId': sessionId,
        'id': id,
      });
      if (_contains(sessionId, item)) _drafts[sessionId]!.remove(item);
    } catch (failure) {
      if (_contains(sessionId, item)) {
        item.removing = false;
        item.status = 'error';
        item.error = '附件移除未完成，请重试移除。\n$failure';
      }
    }
    _changed();
  }

  /// Only consume the exact IDs whose prompt the shared DSH controller accepted.
  Future<void> consume(String sessionId, List<String> ids) async {
    final consumed = items(sessionId)
        .where((item) => ids.contains(item.id))
        .toList();
    _drafts[sessionId]?.removeWhere(consumed.contains);
    _changed();
    for (final item in consumed) {
      try {
        await surface.call('attachments.release', {
          'sessionId': sessionId,
          'id': item.id,
        });
      } catch (failure) {
        if (!_closed) {
          _messages[sessionId] = '消息已提交，附件临时副本清理尚未确认。已提交的附件不受影响。';
          _changed();
        }
      }
    }
  }

  /// A restart invalidates Session receipts; selected copies can be re-uploaded without selecting again.
  void invalidateReceipts() {
    for (final item in _drafts.values.expand((items) => items)) {
      if (item.status == 'ready') {
        item.status = 'error';
        item.error = '运行服务已重启，请重试上传此附件后发送。';
      }
    }
    _changed();
  }

  @override
  void dispose() {
    _closed = true;
    surface.removeListener(_connectionChanged);
    for (final entry in _drafts.entries) {
      for (final item in entry.value) {
        unawaited(
          surface
              .call('attachments.release', {
                'sessionId': entry.key,
                'id': item.id,
              })
              .catchError((Object failure) {
                // The service may have stopped. Its private cache is never a sent-message attachment.
                return null;
              }),
        );
      }
    }
    super.dispose();
  }
}

class PocketAttachmentRail extends StatelessWidget {
  const PocketAttachmentRail({
    super.key,
    required this.drafts,
    required this.sessionId,
  });
  final AttachmentDrafts drafts;
  final String sessionId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: drafts,
    builder: (context, _) {
      final items = drafts.items(sessionId);
      final previewRuntime = drafts.localRuntime;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (drafts.pickingSession == sessionId && items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('正在选择并导入附件…'),
            ),
          if (items.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: items
                    .map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(right: 8, bottom: 8),
                        child: item.isImage && item.previewPath != null
                            ? _DraftThumbnail(
                                item: item,
                                drafts: drafts,
                                sessionId: sessionId,
                              )
                            : SizedBox(
                                width: 250,
                                child: PocketCard(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            item.isImage
                                                ? Icons.image_outlined
                                                : Icons
                                                      .insert_drive_file_outlined,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              item.name,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          GlassButton(
                                            onPressed: item.removing
                                                ? null
                                                : () => drafts.remove(
                                                    sessionId,
                                                    item.id,
                                                  ),
                                            icon: Icons.close,
                                            label: '移除 ${item.name}',
                                          ),
                                        ],
                                      ),
                                      Text(
                                        '${item.bytes} B · ${item.removing
                                            ? '正在移除'
                                            : item.status == 'ready'
                                            ? '已就绪'
                                            : item.status == 'uploading'
                                            ? '正在上传'
                                            : '上传失败'}',
                                      ),
                                      if (item.error != null)
                                        Text(
                                          item.error!,
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      if (item.isImage &&
                                          item.status == 'ready' &&
                                          !item.removing &&
                                          previewRuntime != null)
                                        PocketButton.tonal(
                                          onPressed: () => showPocketDraftImage(
                                            context,
                                            previewRuntime,
                                            sessionId,
                                            item.id,
                                            item.name,
                                          ),
                                          child: const Text('查看图片'),
                                        ),
                                      if (item.status == 'error' &&
                                          !item.removing)
                                        PocketButton.tonal(
                                          onPressed: () =>
                                              drafts.retry(sessionId, item.id),
                                          child: const Text('重试上传'),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                      ),
                    )
                    .toList(),
              ),
            ),
          if (drafts.message(sessionId) case final message?)
            Padding(padding: const EdgeInsets.all(8), child: Text(message)),
        ],
      );
    },
  );
}

class _DraftThumbnail extends StatelessWidget {
  const _DraftThumbnail({
    required this.item,
    required this.drafts,
    required this.sessionId,
  });
  final AttachmentDraft item;
  final AttachmentDrafts drafts;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final file = File(item.previewPath!);
    final source = PocketImageSource(
      name: item.name,
      load: () async {
        if (await file.length() > pocketPreviewMaxBytes) {
          throw const FormatException('图片超过预览大小上限。');
        }
        return PocketImagePayload(
          bytes: await file.readAsBytes(),
          mediaType: item.mediaType,
          name: item.name,
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox.square(
          dimension: 94,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Semantics(
                button: true,
                label: '预览 ${item.name}',
                child: InkWell(
                  onTap: () => Navigator.of(context).push<void>(
                    PocketRoute<void>(
                      builder: (_) => PocketImagePreview(source: source),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image(
                      image: ResizeImage(
                        FileImage(file),
                        width: 300,
                        height: 300,
                        policy: ResizeImagePolicy.fit,
                      ),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: IconButton(
                  tooltip: '移除 ${item.name}',
                  onPressed: item.removing
                      ? null
                      : () => drafts.remove(sessionId, item.id),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(32, 32),
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ),
              if (item.status == 'uploading')
                const Positioned(
                  left: 8,
                  bottom: 8,
                  child: SizedBox.square(
                    dimension: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
        if (item.status == 'error')
          SizedBox(
            width: 155,
            child: Column(
              children: [
                Text(
                  item.error ?? '上传失败',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                TextButton(
                  onPressed: () => drafts.retry(sessionId, item.id),
                  child: const Text('重试上传'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
