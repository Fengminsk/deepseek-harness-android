import 'package:material_ui/material_ui.dart';

import 'chat_reply_sources.dart';
import 'chat_source_identity.dart';
import 'entry_motion.dart';
import 'flclash/surface.dart';
import 'ui.dart';

/// A route is returned to the owning reply row so changing/removing that row
/// can dismiss this snapshot instead of leaving sources from another answer.
PopupRoute<void> chatReplySourcesRoute(
  BuildContext context,
  ChatReplySources sources, {
  required Set<String> answerLinks,
  required Future<void> Function(Uri) onOpenSource,
}) => _ReplySourcesRoute(
  sources: sources,
  answerLinks: answerLinks,
  onOpenSource: onOpenSource,
  themes: InheritedTheme.capture(
    from: context,
    to: Navigator.of(context).context,
  ),
  reduceMotion: MediaQuery.disableAnimationsOf(context),
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
);

class _ReplySourcesRoute extends PopupRoute<void> {
  _ReplySourcesRoute({
    required this.sources,
    required this.answerLinks,
    required this.onOpenSource,
    required this.themes,
    required this.reduceMotion,
    required this.barrierLabel,
  });
  final ChatReplySources sources;
  final Set<String> answerLinks;
  final Future<void> Function(Uri) onOpenSource;
  final CapturedThemes themes;
  final bool reduceMotion;
  @override
  final String barrierLabel;
  @override
  bool get barrierDismissible => true;
  @override
  Color get barrierColor => const Color(0x66000000);
  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 320);
  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 220);
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => reduceMotion
      ? child
      : SlideTransition(
          position: animation
              .drive(CurveTween(curve: Curves.easeOutCubic))
              .drive(Tween(begin: const Offset(0, 1), end: Offset.zero)),
          child: PocketBlurTransition(animation: animation, child: child),
        );
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(
    _ReplySourcesSheet(
      sources: sources,
      answerLinks: answerLinks,
      onOpenSource: onOpenSource,
    ),
  );
}

class _ReplySourcesSheet extends StatefulWidget {
  const _ReplySourcesSheet({
    required this.sources,
    required this.answerLinks,
    required this.onOpenSource,
  });
  final ChatReplySources sources;
  final Set<String> answerLinks;
  final Future<void> Function(Uri) onOpenSource;
  @override
  State<_ReplySourcesSheet> createState() => _ReplySourcesSheetState();
}

class _ReplySourcesSheetState extends State<_ReplySourcesSheet> {
  final _extent = DraggableScrollableController();
  String? _failure, _failureUrl;
  bool _opening = false;
  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

  Future<void> _open(Uri uri) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _failure = null;
      _failureUrl = null;
    });
    try {
      await widget.onOpenSource(uri);
    } catch (_) {
      if (mounted) {
        setState(() {
          _failure = '无法打开此来源，请重试。';
          _failureUrl = uri.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final surface = SurfaceLevel.floatingOf(colors).colorOf(colors);
    final ordered = widget.sources.forAnswer(widget.answerLinks);
    final cited = ordered
        .where((source) => widget.answerLinks.contains(source.url))
        .toList();
    final other = ordered
        .where((source) => !widget.answerLinks.contains(source.url))
        .toList();
    final toolbarHeight = MediaQuery.textScalerOf(context)
        .scale(22)
        .clamp(48.0, 88.0);
    final headerHeight = 28 + toolbarHeight + 10;
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, viewport) => Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: DraggableScrollableSheet(
                controller: _extent,
                expand: false,
                initialChildSize: .64,
                minChildSize: .34,
                maxChildSize: .96,
                shouldCloseOnMinExtent: false,
                builder: (context, scroll) => Material(
                  key: const Key('reply-sources-sheet'),
                  color: surface,
                  shape: const RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(AppCorner.xxl),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: SurfaceScope(
                    level: SurfaceLevel.floatingOf(colors),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ListView(
                            key: const Key('reply-sources-body'),
                            controller: scroll,
                            padding: EdgeInsets.fromLTRB(
                              20,
                              headerHeight + 4,
                              20,
                              24 + MediaQuery.paddingOf(context).bottom,
                            ),
                            children: [
                              if (cited.isNotEmpty) ...[
                                _sourceHeading(context, '回答中引用'),
                                PocketSection(
                                  divided: true,
                                  children: [
                                    for (final source in cited) _row(source),
                                  ],
                                ),
                              ],
                              if (other.isNotEmpty) ...[
                                if (cited.isNotEmpty)
                                  _sourceHeading(context, '其他检索结果'),
                                PocketSection(
                                  divided: true,
                                  children: [
                                    for (final source in other) _row(source),
                                  ],
                                ),
                              ],
                              if (widget.sources.truncated)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    '工具返回的来源或内容已截取。',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: FloatingHeader(
                            key: const Key('reply-sources-header'),
                            backgroundColor: surface,
                            overhang: 28,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  key: const Key('reply-sources-drag-handle'),
                                  behavior: HitTestBehavior.opaque,
                                  onVerticalDragUpdate: (details) {
                                    if (_extent.isAttached) {
                                      _extent.jumpTo(
                                        (_extent.size -
                                                details.delta.dy /
                                                    viewport.maxHeight)
                                            .clamp(.34, .96),
                                      );
                                    }
                                  },
                                  onVerticalDragEnd: (details) {
                                    if (_extent.isAttached &&
                                        (_extent.size <= .35 ||
                                            (details.primaryVelocity ?? 0) >
                                                900)) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                                  child: SizedBox(
                                    height: 28,
                                    width: double.infinity,
                                    child: Center(
                                      child: Container(
                                        width: 32,
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: colors.onSurfaceVariant
                                              .withValues(alpha: .5),
                                          borderRadius: AppRadius.full,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    10,
                                  ),
                                  child: SizedBox(
                                    height: toolbarHeight,
                                    child: Row(
                                      children: [
                                        const SizedBox(width: 48),
                                        Expanded(
                                          child: Text(
                                            '来源',
                                            textAlign: TextAlign.center,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                        ),
                                        SizedBox(
                                          width: 48,
                                          child: GlassButton(
                                            icon: Icons.close_rounded,
                                            label: '关闭来源',
                                            onPressed: () =>
                                                Navigator.of(context).pop(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
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
    );
  }

  Widget _sourceHeading(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 20, 8, 10),
    child: Text(title, style: Theme.of(context).textTheme.labelMedium),
  );

  Widget _row(ChatReplySource source) => _SourceRow(
    source: source,
    failure: source.destination?.toString() == _failureUrl ? _failure : null,
    onTap: !_opening && source.destination != null
        ? () => _open(source.destination!)
        : null,
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, required this.onTap, this.failure});
  final ChatReplySource source;
  final VoidCallback? onTap;
  final String? failure;
  @override
  Widget build(BuildContext context) {
    final failedStatus = source.records
        .where(
          (record) =>
              record.kind == ChatReplySourceKind.fetch &&
              record.statusCode != null &&
              record.statusCode! >= 400,
        )
        .map((record) => record.statusCode)
        .firstOrNull;
    return PocketTile(
      leading: source.host.isEmpty
          ? const Icon(Icons.public_rounded)
          : ChatSourceHostMark(host: source.host),
      title: Text(source.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(source.url, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (source.snippet?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                source.snippet!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (source.publishedAt?.isNotEmpty == true) Text(source.publishedAt!),
          if (failedStatus != null) Text('网页状态 · HTTP $failedStatus'),
          if (failure != null)
            PocketReveal(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  failure!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      ),
      trailing: source.destination == null
          ? null
          : const Icon(Icons.open_in_new_rounded, size: 18),
      onTap: onTap,
    );
  }
}
