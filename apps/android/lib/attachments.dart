import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

class AttachmentDraft {
  AttachmentDraft({
    required this.id,
    required this.name,
    required this.bytes,
    required this.mediaType,
  });

  final String id, mediaType;
  String name;
  int bytes;
  String status = 'uploading';
  String? error;
  bool removing = false;

  bool get isImage => const {
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
  }.contains(mediaType);
}

/// One composer draft owns each native selection, including while a different chat is open.
class AttachmentDrafts extends ChangeNotifier {
  AttachmentDrafts(this.runtime);

  final RuntimeController runtime;
  final _drafts = <String, List<AttachmentDraft>>{};
  final _messages = <String, String>{};
  String? pickingSession;
  bool _closed = false;

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
          await runtime.call('attachments.release', {
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
    try {
      final receipt = await runtime.call('attachments.prepare', {
        'sessionId': sessionId,
        'id': item.id,
      }) as Json;
      if (!_contains(sessionId, item) || item.removing) return;
      if (receipt['id'] != item.id || receipt['receiptId'] is! String) {
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
      await runtime.call('attachments.release', {
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
        await runtime.call('attachments.release', {
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
    for (final entry in _drafts.entries) {
      for (final item in entry.value) {
        unawaited(
          runtime
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (drafts.pickingSession == sessionId)
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
                        child: SizedBox(
                          width: 250,
                          child: PocketCard(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      item.isImage
                                          ? Icons.image_outlined
                                          : Icons.insert_drive_file_outlined,
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
                                if (item.status == 'error' && !item.removing)
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
