import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'account_presentation.dart';
import 'runtime.dart';
import 'ui.dart';

/// One live quota failure. The source event is already recorded in the
/// Session, so this notice never submits, resumes, or replays an Agent turn.
class AccountQuotaNotice {
  const AccountQuotaNotice(this.sessionId, this.sequence, this.code);
  final String sessionId;
  final int sequence;
  final String code;
}

/// Mirrors the original ui-chat append-only QUOTA/ACCOUNT_QUOTA trigger. A
/// replacement history page cannot publish here: the runtime feeds only new
/// carrier events, and an open notice is retained until the user acts.
class AccountQuotaNoticeController extends ChangeNotifier {
  AccountQuotaNoticeController(Stream<Json> liveEvents) {
    _subscription = liveEvents.listen(_accept);
  }

  late final StreamSubscription<Json> _subscription;
  Timer? _toastTimer;
  AccountQuotaNotice? current;
  bool _disposed = false;

  void _accept(Json frame) {
    if (_disposed || current != null) return;
    final event = frame['event'];
    if (event is! Json || event['type'] != 'turn/end') return;
    final data = event['data'];
    if (data is! Json) return;
    final reason = data['reason'];
    if (reason is! Json || reason['kind'] != 'error') return;
    final error = reason['error'];
    if (error is! Json) return;
    final code = error['code'];
    if (code != 'QUOTA' && code != 'ACCOUNT_QUOTA') return;
    final sessionId = frame['sessionId'];
    final seq = event['seq'];
    if (sessionId is! String || seq is! int) return;
    current = AccountQuotaNotice(sessionId, seq, code as String);
    if (code == 'QUOTA') {
      _toastTimer = Timer(const Duration(seconds: 5), dismiss);
    }
    notifyListeners();
  }

  void dismiss() {
    if (current == null || _disposed) return;
    _toastTimer?.cancel();
    _toastTimer = null;
    current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _toastTimer?.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

typedef AccountQuotaPageOpener = Future<void> Function(
  String url,
  Brightness brightness,
);

Future<void> openAccountQuotaTopUp(String url, Brightness brightness) async {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('充值页面地址无效');
  }
  await RuntimeController.channel.invokeMethod<void>('account.openPage', {
    'url': accountAuthorizeUrl(url, brightness),
    'dark': brightness == Brightness.dark,
  });
}

/// Frame-wide notice remains visible over secondary pages and presents the
/// native account action only while a current signed-in snapshot confirms it.
class AccountQuotaNoticeHost extends StatefulWidget {
  const AccountQuotaNoticeHost({
    super.key,
    required this.runtime,
    required this.notices,
    required this.child,
    this.openTopUp = openAccountQuotaTopUp,
    this.openAccount,
  });
  final RuntimeController runtime;
  final AccountQuotaNoticeController notices;
  final Widget child;
  final AccountQuotaPageOpener openTopUp;
  final VoidCallback? openAccount;

  @override
  State<AccountQuotaNoticeHost> createState() => _AccountQuotaNoticeHostState();
}

class _AccountQuotaNoticeHostState extends State<AccountQuotaNoticeHost> {
  bool opening = false;
  String? error;

  @override
  void initState() {
    super.initState();
    widget.notices.addListener(_noticeChanged);
  }

  @override
  void didUpdateWidget(AccountQuotaNoticeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notices != widget.notices) {
      oldWidget.notices.removeListener(_noticeChanged);
      widget.notices.addListener(_noticeChanged);
      _noticeChanged();
    }
  }

  void _noticeChanged() {
    if (mounted) setState(() => error = null);
  }

  Future<void> _open(String url) async {
    if (opening) return;
    final notice = widget.notices.current;
    setState(() {
      opening = true;
      error = null;
    });
    try {
      await widget.openTopUp(url, Theme.of(context).brightness);
      if (mounted && identical(widget.notices.current, notice)) {
        widget.notices.dismiss();
      }
    } catch (_) {
      if (mounted && identical(widget.notices.current, notice)) {
        setState(() => error = '无法打开官方充值页面，请检查浏览器或网络后重试。');
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  void dispose() {
    widget.notices.removeListener(_noticeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) {
      final notice = widget.notices.current;
      final account = widget.runtime.accountSnapshot;
      final signedIn = account?.connected == true && account?.signedIn == true;
      final links = account?.view?['links'];
      final topUp = signedIn && links is Json && links['topUpUrl'] is String
          ? links['topUpUrl'] as String
          : null;
      return Stack(
        children: [
          ExcludeSemantics(
            excluding: notice?.code == 'ACCOUNT_QUOTA',
            child: widget.child,
          ),
          if (notice?.code == 'QUOTA')
            Positioned(
              left: 24,
              right: 24,
              bottom: 24,
              child: SafeArea(
                child: GlassSurface(
                  radius: 24,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Expanded(child: Text('当前模型额度不足')),
                        PocketButton.tonal(
                          onPressed: widget.notices.dismiss,
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (notice?.code == 'ACCOUNT_QUOTA') ...[
            const ModalBarrier(dismissible: false, color: Color(0x99000000)),
            Positioned.fill(
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (context, viewport) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: viewport.maxHeight,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 12,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: BlockSemantics(
                              child: Semantics(
                                scopesRoute: true,
                                explicitChildNodes: true,
                                child: GlassSurface(
                                  radius: 28,
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '当前无可用额度',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge,
                                        ),
                                        const SizedBox(height: 12),
                                        const Text(
                                          '这次任务因账号额度不足而停止。可前往 DeepSeek 官方平台充值，或稍后在“账号与余额”中处理。',
                                        ),
                                        if (!signedIn) ...[
                                          const SizedBox(height: 12),
                                          const Text('账号状态尚未确认，请在“账号与余额”中查看。'),
                                        ],
                                        if (error != null) ...[
                                          const SizedBox(height: 12),
                                          Text(
                                            error!,
                                            key: const Key('quota-open-error'),
                                          ),
                                        ],
                                        const SizedBox(height: 18),
                                        Wrap(
                                          alignment: WrapAlignment.end,
                                          spacing: 10,
                                          runSpacing: 10,
                                          children: [
                                            PocketButton.tonal(
                                              onPressed: opening
                                                  ? null
                                                  : widget.notices.dismiss,
                                              child: const Text('稍后处理'),
                                            ),
                                            if (topUp != null) ...[
                                              PocketButton(
                                                onPressed: opening
                                                    ? null
                                                    : () => _open(topUp),
                                                child: Text(
                                                  opening ? '正在打开' : '去充值',
                                                ),
                                              ),
                                            ] else if (widget.openAccount !=
                                                null) ...[
                                              PocketButton(
                                                onPressed: opening
                                                    ? null
                                                    : () {
                                                        widget.notices
                                                            .dismiss();
                                                        widget.openAccount!();
                                                      },
                                                child: const Text('账号与余额'),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}
