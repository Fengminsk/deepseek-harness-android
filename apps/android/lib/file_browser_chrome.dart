import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'flclash/popup.dart';
import 'flclash/surface.dart';
import 'flclash/typography.dart';
import 'entry_motion.dart';
import 'ui.dart';

class FileBreadcrumb {
  const FileBreadcrumb(this.label, this.onTap);
  final String label;
  final VoidCallback? onTap;
}

/// One scroll viewport passes behind the floating controls and breadcrumb trail.
class FileBrowserChrome extends StatelessWidget {
  const FileBrowserChrome({
    super.key,
    required this.title,
    required this.count,
    required this.breadcrumbs,
    required this.controller,
    required this.children,
    required this.onBack,
    required this.onMore,
    this.onSearch,
    this.onAdd,
  });
  final String title, count;
  final List<FileBreadcrumb> breadcrumbs;
  final ScrollController controller;
  final List<Widget> children;
  final VoidCallback onBack;
  final VoidCallback? onSearch;
  final ValueChanged<BuildContext>? onAdd;
  final ValueChanged<BuildContext> onMore;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final scale = MediaQuery.textScalerOf(context);
    final head = math.max(
      64.0,
      scale.scale(AppTextStyle.title3.leading) +
          scale.scale(AppTextStyle.caption1.leading) +
          16,
    );
    final trail = math.max(
      44.0,
      scale.scale(AppTextStyle.subheadline.leading) + 24,
    );
    final top = safe.top + head + trail + 14;
    final colors = Theme.of(context).colorScheme;
    return PocketReveal(
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            ListView.builder(
              key: const Key('file-browser-list'),
              controller: controller,
              padding: EdgeInsets.fromLTRB(16, top + 12, 16, safe.bottom + 24),
              itemCount: children.length,
              itemBuilder: (_, index) => PocketReveal(
                key: children[index].key == null
                    ? null
                    : ValueKey<Key>(children[index].key!),
                child: children[index],
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: top + 28,
              child: FloatingEdgeScrim(
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                overhang: 28,
              ),
            ),
            Positioned(
              top: safe.top + 8,
              left: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: head,
                    child: Row(
                      children: [
                        GlassButton(
                          icon: Icons.arrow_back_rounded,
                          label: '返回上级',
                          onPressed: onBack,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyle.title3.of(
                                  context,
                                  emphasized: true,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                count,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyle.caption1
                                    .of(context)
                                    .copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        if (onAdd != null) ...[
                          const SizedBox(width: 8),
                          Builder(
                            builder: (anchor) => GlassButton(
                              icon: Icons.add_rounded,
                              label: '添加文件位置',
                              onPressed: () => onAdd!(anchor),
                            ),
                          ),
                        ],
                        if (onSearch != null) ...[
                          const SizedBox(width: 8),
                          GlassButton(
                            icon: Icons.search_rounded,
                            label: '搜索此目录',
                            onPressed: onSearch,
                          ),
                        ],
                        const SizedBox(width: 8),
                        Builder(
                          builder: (anchor) => GlassButton(
                            icon: Icons.more_horiz_rounded,
                            label: '文件菜单',
                            onPressed: () => onMore(anchor),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: trail,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < breadcrumbs.length; i++) ...[
                            if (i > 0)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: colors.outline,
                                ),
                              ),
                            Semantics(
                              button: breadcrumbs[i].onTap != null,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: breadcrumbs[i].onTap,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                    vertical: 10,
                                  ),
                                  child: Text(
                                    breadcrumbs[i].label,
                                    style: AppTextStyle.subheadline
                                        .of(context, emphasized: true)
                                        .copyWith(
                                          color: i == breadcrumbs.length - 1
                                              ? colors.primary
                                              : colors.onSurface,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FileBrowserEntry extends StatelessWidget {
  const FileBrowserEntry({
    super.key,
    required this.name,
    required this.detail,
    required this.directory,
    this.onTap,
    this.onLongPress,
    this.thumbnail,
    this.blocked = false,
    this.mediaType,
  });
  final String name, detail;
  final String? mediaType;
  final bool directory, blocked;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onLongPress;
  final Widget? thumbnail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: onTap != null,
      onLongPress: onLongPress == null
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox;
              onLongPress!(box.localToGlobal(box.size.center(Offset.zero)));
            },
      child: GestureDetector(
        onLongPressStart: onLongPress == null
            ? null
            : (details) => onLongPress!(details.globalPosition),
        child: FocusRing(
          shape: AppShape.none,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              customBorder: AppShape.none,
              splashFactory: NoSplash.splashFactory,
              highlightColor: colors.onSurface.withValues(alpha: .08),
              child: Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Row(
                  children: [
                    Opacity(
                      opacity: blocked ? .4 : 1,
                      child: SizedBox(
                        width: 54,
                        height: 60,
                        child:
                            thumbnail ??
                            Icon(
                              fileTypeIcon(
                                name,
                                directory: directory,
                                mediaType: mediaType,
                              ),
                              size: directory ? 50 : 37,
                              color: directory
                                  ? const Color(0xff4caeda)
                                  : colors.onSurfaceVariant,
                            ),
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: colors.outlineVariant.withValues(
                                alpha: .45,
                              ),
                              width: .5,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyle.body
                                        .of(context, emphasized: true)
                                        .copyWith(
                                          color: blocked
                                              ? colors.outline
                                              : colors.onSurface,
                                        ),
                                  ),
                                  if (detail.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      detail,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTextStyle.footnote
                                          .of(context)
                                          .copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (directory)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Icon(
                                  Icons.chevron_right_rounded,
                                  color: colors.outline,
                                  size: 20,
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
    );
  }
}

IconData fileTypeIcon(
  String name, {
  bool directory = false,
  String? mediaType,
}) {
  if (directory) return Icons.folder_rounded;
  final ext = name.toLowerCase().split('.').last;
  if (mediaType?.startsWith('image/') == true ||
      ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'bmp'].contains(ext)) {
    return Icons.image_outlined;
  }
  if (ext == 'pdf' || mediaType == 'application/pdf') {
    return Icons.picture_as_pdf_outlined;
  }
  if (['mp4', 'mov', 'mkv', 'webm'].contains(ext) ||
      mediaType?.startsWith('video/') == true) {
    return Icons.movie_outlined;
  }
  if (['mp3', 'm4a', 'wav', 'ogg', 'flac'].contains(ext) ||
      mediaType?.startsWith('audio/') == true) {
    return Icons.audio_file_outlined;
  }
  if (['zip', 'tar', 'gz', '7z', 'rar'].contains(ext)) {
    return Icons.folder_zip_outlined;
  }
  if ([
    'json',
    'yaml',
    'yml',
    'js',
    'ts',
    'dart',
    'py',
    'sh',
    'html',
    'css',
  ].contains(ext)) {
    return Icons.code_rounded;
  }
  if (['xls', 'xlsx', 'csv'].contains(ext)) return Icons.table_chart_outlined;
  if (['ppt', 'pptx'].contains(ext)) return Icons.slideshow_rounded;
  return Icons.description_outlined;
}

String fileModifiedDate(Object? value) {
  if (value is! num || value <= 0) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(value.toInt()).toLocal();
  final today = DateTime.now();
  return '${date.year == today.year ? '' : '${date.year}年 '}${date.month}月${date.day}日';
}

class FileBrowserEmpty extends StatelessWidget {
  const FileBrowserEmpty({super.key, this.message = '此目录为空。', this.hint});
  final String message;
  final String? hint;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .55,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_rounded,
            size: 58,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: AppTextStyle.headline.of(context, emphasized: true),
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    ),
  );
}

Future<int?> showFileBrowserMenu(
  BuildContext context,
  List<CommonPopupMenuItem> items, {
  Offset? position,
}) async {
  final box = context.findRenderObject();
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay?.context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || overlay is! RenderBox) return null;
  final point = overlay.globalToLocal(
    position ?? box.localToGlobal(box.size.center(Offset.zero)),
  );
  int? selected;
  final route = CommonPopupRoute<void>(
    anchorOf: () => point & const Size(1, 1),
    placement: PopupPlacement.belowPoint,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    reduceMotion: MediaQuery.disableAnimationsOf(context),
    builder: (_) => CommonPopupMenu(
      items: [
        for (var i = 0; i < items.length; i++)
          CommonPopupMenuItem(
            label: items[i].label,
            glyph: items[i].glyph,
            onPressed: items[i].onPressed == null ? null : () => selected = i,
          ),
      ],
    ),
  );
  await navigator.push<void>(route);
  await route.completed;
  return selected;
}
