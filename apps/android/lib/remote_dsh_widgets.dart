// 远程 DSH 的共享展示组件：设备胶囊与胶囊条、分组标题、会话行、项目分组、
// 远程首页标题栏、底部输入条（首页的紧凑单行与会话页的悬浮三态卡），以及权限
// 预设与指令菜单两个底部弹层。
//
// 这些组件只负责绘制与回调：不读取运行时、不发起请求、不持有业务状态。
// 颜色一律取自当前 Theme，排版比例取自 AppTextStyle；玻璃开关、纯黑模式、
// 减少动态效果与文字缩放沿用 App 既有的 FlClash 组件行为，关闭玻璃时回退为
// 实心表面。

import 'package:material_ui/material_ui.dart';

import 'composer_commands.dart';
import 'flclash/daylight.dart';
import 'flclash/surface.dart';
import 'flclash/typography.dart';
import 'pocket_composer.dart';
import 'remote_permissions.dart';
import 'ui.dart';

/// 设备胶囊上的在线状态，只影响状态点颜色与无障碍文案。
enum RemoteDeviceStatus { online, connecting, offline }

/// 设备胶囊：可选状态点、图标、名称与选中态，名称单行省略。
///
/// 只做展示与回调；[onTap] 为 null 时不可点，但仍以未选中的灰态显示。
class RemoteDeviceChip extends StatelessWidget {
  const RemoteDeviceChip({
    super.key,
    required this.label,
    this.icon,
    this.status,
    this.selected = false,
    this.onTap,
  });

  /// 设备显示名，过长时单行省略。
  final String label;

  /// 设备图标，可为空。
  final IconData? icon;

  /// 在线状态点；为 null 时不画状态点。
  final RemoteDeviceStatus? status;

  /// 是否为当前选中的设备。
  final bool selected;

  /// 点按回调；为 null 时胶囊处于不可点状态。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final status = this.status;
    // 选中态沿用分段选择器的高亮板面：浅色主题用 surfaceBright，深色主题
    // 抬高一级并叠一点 onSurface，保持和其余玻璃控件同一套层次。
    final fill = selected
        ? (dark
              ? Color.alphaBlend(
                  colors.onSurface.withValues(alpha: .2),
                  colors.surfaceContainerHighest,
                )
              : colors.surfaceBright)
        : SurfaceLevel.block.colorOf(colors);
    final foreground = selected ? colors.onSurface : colors.onSurfaceVariant;
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      label: status == null ? label : '$label，${_statusLabel(status)}',
      onTap: onTap,
      // 视觉子树只负责绘制，读屏文案由上面这一层统一给出。
      child: ExcludeSemantics(
        child: ElasticPress(
          enabled: onTap != null,
          child: ConstrainedBox(
            // 触摸目标不小于 48dp；名称单行省略，胶囊最宽 200dp。
            constraints: const BoxConstraints(minHeight: 48, maxWidth: 200),
            child: DaylightSurface(
              shape: AppShape.full,
              color: fill,
              enabled: LiquidGlassScope.of(context),
              shadows: selected
                  ? [
                      BoxShadow(
                        color: colors.shadow.withValues(alpha: .12),
                        blurRadius: 3,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : const [],
              child: Material(
                type: MaterialType.transparency,
                shape: AppShape.full,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  customBorder: AppShape.full,
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (status != null) ...[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _statusColor(colors, status),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (icon != null) ...[
                          Icon(icon, size: 18, color: foreground),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.subheadline
                                .of(context)
                                .copyWith(
                                  color: foreground,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
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
}

/// 设备胶囊条里的一台设备，只承载展示字段。
class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.label,
    this.icon,
    this.status,
  });

  /// 设备标识，用于和 [RemoteDeviceRail.selectedId] 比较。
  final String id;

  /// 设备显示名。
  final String label;

  /// 设备图标。
  final IconData? icon;

  /// 在线状态点。
  final RemoteDeviceStatus? status;
}

/// 横向滚动的设备胶囊条，首项固定为「全部」。
///
/// 选中态完全由 [selectedId] 决定：null 表示选中「全部」，与既有截图里
/// 「全部 = 当前电脑的全部项目」的语义一致（跨设备聚合不在 v1 范围内）。
class RemoteDeviceRail extends StatelessWidget {
  const RemoteDeviceRail({
    super.key,
    required this.devices,
    this.selectedId,
    this.onSelected,
    this.allLabel = '全部',
    this.padding = EdgeInsets.zero,
  });

  /// 「全部」之后的设备列表。
  final List<RemoteDevice> devices;

  /// 当前选中的设备 id；null 表示选中首项「全部」。
  final String? selectedId;

  /// 选中回调：传 null 表示选中「全部」。为 null 时整条都不可点。
  final ValueChanged<String?>? onSelected;

  /// 首项的文案，默认「全部」。
  final String allLabel;

  /// 胶囊内容的内边距；胶囊条铺满视口时由调用方补左右边距。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final onSelected = this.onSelected;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        children: [
          RemoteDeviceChip(
            label: allLabel,
            icon: Icons.devices_rounded,
            selected: selectedId == null,
            onTap: onSelected == null ? null : () => onSelected(null),
          ),
          for (final device in devices) ...[
            const SizedBox(width: 8),
            RemoteDeviceChip(
              label: device.label,
              icon: device.icon,
              status: device.status,
              selected: device.id == selectedId,
              onTap: onSelected == null ? null : () => onSelected(device.id),
            ),
          ],
        ],
      ),
    );
  }
}

/// 分组标题，例如「项目」。
///
/// 只画一行标题；标题文字过长时单行省略，读屏按标题分组朗读。
class RemoteSectionLabel extends StatelessWidget {
  const RemoteSectionLabel(this.label, {super.key});

  /// 标题文案。
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyle.footnote
            .of(context, emphasized: true)
            .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

/// 会话行：标题加可选右侧计数，带点击回调。
///
/// 标题最多两行后省略；[trailingCount] 为 null 或不大于 0 时不显示计数。
class RemoteSessionRow extends StatelessWidget {
  const RemoteSessionRow({
    super.key,
    required this.title,
    this.trailingCount,
    this.selected = false,
    this.onTap,
  });

  /// 会话标题。
  final String title;

  /// 可选的右侧计数，例如待办数量。
  final int? trailingCount;

  /// 是否为当前会话。
  final bool selected;

  /// 打开会话的回调；为 null 时不可点。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final count = trailingCount;
    return Semantics(
      selected: selected,
      child: ElasticPress(
        enabled: onTap != null,
        child: PocketTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 10,
          ),
          selected: selected,
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: count == null || count <= 0
              ? null
              : Text(
                  '$count',
                  maxLines: 1,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colors.onSurfaceVariant),
                ),
          onTap: onTap,
        ),
      ),
    );
  }
}

/// 可折叠的项目分组：文件夹图标、项目名与展开后的若干 [RemoteSessionRow]。
///
/// 折叠状态属于本组件的展示状态，只在首次挂载时读取 [initiallyExpanded]；
/// 之后完全由用户点按标题决定，不受父页面重建影响。
class RemoteProjectGroup extends StatefulWidget {
  const RemoteProjectGroup({
    super.key,
    required this.name,
    required this.children,
    this.initiallyExpanded = true,
    this.trailing,
  });

  /// 项目名，过长时单行省略。
  final String name;

  /// 展开后显示的内容，通常是若干 [RemoteSessionRow]。
  final List<Widget> children;

  /// 首次挂载时是否展开。
  final bool initiallyExpanded;

  /// 标题右侧、折叠箭头之前的附加信息，例如会话数量。
  final Widget? trailing;

  @override
  State<RemoteProjectGroup> createState() => _RemoteProjectGroupState();
}

class _RemoteProjectGroupState extends State<RemoteProjectGroup> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final trailing = widget.trailing;
    return PocketSection(
      children: [
        Semantics(
          expanded: _expanded,
          child: PocketTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              widget.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (trailing != null) ...[trailing, const SizedBox(width: 6)],
                AnimatedRotation(
                  turns: _expanded ? .25 : 0,
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  child: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
}

/// 远程首页标题栏：左侧菜单、中间标题加下拉箭头、右侧搜索。
///
/// 三个位置都是 48dp 触摸目标。标题区域铺满中间剩余宽度，点按即展开排序与
/// 设置菜单；[onTitle] 为 null 时标题只做展示。
class RemoteHomeHeader extends StatelessWidget {
  const RemoteHomeHeader({
    super.key,
    required this.title,
    this.onMenu,
    this.onTitle,
    this.onSearch,
    this.menuLabel = '打开菜单',
    this.searchLabel = '搜索',
  });

  /// 中间标题，过长时单行省略。
  final String title;

  /// 打开侧栏。
  final VoidCallback? onMenu;

  /// 展开排序与设置菜单。
  final VoidCallback? onTitle;

  /// 打开搜索。
  final VoidCallback? onSearch;

  /// 左侧按钮的无障碍文案。
  final String menuLabel;

  /// 右侧按钮的无障碍文案。
  final String searchLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          _RemoteCircleButton(
            icon: Icons.menu_rounded,
            label: menuLabel,
            onPressed: onMenu,
          ),
          Expanded(
            // 标题仍居中，但触摸区只有文字与箭头本身：整条中间区域可点会让
            // 用户误触下拉菜单。
            child: Center(
              child: Semantics(
                button: onTitle != null,
                enabled: onTitle != null,
                label: '$title，排序与设置菜单',
                onTap: onTitle,
                child: ExcludeSemantics(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTitle,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: AppTextStyle.headline.of(
                                context,
                                emphasized: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.expand_more_rounded,
                            size: 20,
                            color: colors.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          _RemoteCircleButton(
            icon: Icons.search_rounded,
            label: searchLabel,
            onPressed: onSearch,
          ),
        ],
      ),
    );
  }
}

/// 底部输入条：加号、输入框、审批盾牌与模型。
///
/// 有两种形态，由 [floating] 选择：
///
/// - `floating: true`：远程首页与会话页共用的悬浮三态卡（[PocketComposer]）。
///   状态由调用方通过 [mode] 持有；[onSend]/[onStop]/[onReasoning]/[reasoning]
///   缺省为 null 时对应入口按置灰或不显示处理，因此不会拿到死按钮。
/// - 缺省（`floating: false`）：紧凑单行输入条。远程页现在两处都用悬浮卡，这条
///   形态只留给需要单行输入的入口（例如「只用一行、发送按钮由外部摆放」的旧调用）。
///
/// 占位文案默认「在 设备名 上工作」，可用 [placeholder] 覆盖。组件不持有业务
/// 状态、不发请求；输入内容由调用方通过 [controller] 持有，未提供时使用内部
/// 控制器。进入页面不会自动弹出键盘（不设置 autofocus）。
///
/// 按钮的可用性完全由回调决定：传 null 即置灰且不可点。紧凑形态里没有数据源的
/// 入口由调用方传 null 并把可操作说明交给 [hint]，不再留「能点但没用」的入口
/// （设计文档 §4.2 第 4 条）。
///
/// 语音输入在远程页不做（设计文档 §4.4：手机侧没有录音实现，DSH 的语音是
/// experimental 组合），因此两种形态都不画麦克风按钮；系统输入法自带语音听写。
class RemoteComposer extends StatefulWidget {
  const RemoteComposer({
    super.key,
    required this.deviceLabel,
    this.controller,
    this.focusNode,
    this.modelLabel,
    this.approvalLabel,
    this.placeholder,
    this.hint,
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
    this.onAdd,
    this.onApproval,
    this.onModel,
    this.floating = false,
    this.mode = PocketComposerMode.browse,
    this.onSend,
    this.onStop,
    this.sending = false,
    this.hasDraft = false,
    this.onReasoning,
    this.reasoningDisabledReason,
    this.reasoning,
    this.sendKey,
    this.stopKey,
    this.top,
  });

  /// 目标设备显示名，用于默认占位文案。
  final String deviceLabel;

  /// 输入框控制器；未提供时由组件内部创建并在销毁时释放。
  final TextEditingController? controller;

  /// 输入框焦点节点；组件不会主动请求焦点。
  final FocusNode? focusNode;

  /// 当前模型名，作为模型按钮的提示文案。
  final String? modelLabel;

  /// 当前权限预设名，作为盾牌按钮的提示文案。
  final String? approvalLabel;

  /// 覆盖默认的占位文案。
  final String? placeholder;

  /// 输入条下方的可操作说明；为空时不显示。
  ///
  /// 会话页各控件都有数据源，不需要说明；首页用它统一给出「为什么这里用不了、
  /// 到哪里可以用」，避免把同一句原因重复写到每个按钮上。
  final String? hint;

  /// 为 false 时输入框与全部按钮都不可用。
  final bool enabled;

  /// 输入变化回调。
  final ValueChanged<String>? onChanged;

  /// 键盘提交回调。
  final ValueChanged<String>? onSubmitted;

  /// 点按加号：展开数据驱动的会话指令菜单（添加 / 指令 / 技能）。
  final VoidCallback? onAdd;

  /// 点按盾牌：展开权限预设列表。
  final VoidCallback? onApproval;

  /// 点按模型：选择模型或推理强度。
  ///
  /// 紧凑形态里是右侧的模型按钮；悬浮卡里是推理面板第一行的「打开完整模型
  /// 选择」，工具条上的推理按钮则用 [onReasoning]。
  final VoidCallback? onModel;

  /// 是否渲染为悬浮三态卡；首页传 false，会话页传 true。
  final bool floating;

  /// 悬浮卡的当前状态；[floating] 为 false 时忽略。
  final PocketComposerMode mode;

  /// 悬浮卡的发送回调；为 null 时发送圆钮永远置灰。
  final VoidCallback? onSend;

  /// 悬浮卡的停止回调；非 null 时右侧圆钮显示停止。
  ///
  /// 远程会话的数据源目前没有取消接口（见报告），页面传 null，因此不会出现
  /// 点了没反应的停止按钮。
  final VoidCallback? onStop;

  /// 是否正在发送/执行指令；为 true 时右侧圆钮换成进度。
  final bool sending;

  /// 是否有可发送内容（草稿文本或附件）；决定发送圆钮是否出现。
  final bool hasDraft;

  /// 推理强度按钮回调：进入或退出推理面板（[PocketComposerMode.picker]）。
  final VoidCallback? onReasoning;

  /// 推理强度按钮不可用的原因；与 [onReasoning] 同时为 null 时不显示按钮。
  final String? reasoningDisabledReason;

  /// 推理面板的数据；[mode] 不是 [PocketComposerMode.picker] 时忽略。
  final PocketReasoningPanel? reasoning;

  /// 发送圆钮的标识；不传时用 [PocketComposer.defaultSendKey]。
  final Key? sendKey;

  /// 停止圆钮的标识；不传时用 [PocketComposer.defaultStopKey]。
  final Key? stopKey;

  /// 悬浮卡上方的插槽（附件 rail、命令 chip 等）。
  final Widget? top;

  @override
  State<RemoteComposer> createState() => _RemoteComposerState();
}

class _RemoteComposerState extends State<RemoteComposer> {
  TextEditingController? _owned;

  TextEditingController get _controller =>
      widget.controller ?? (_owned ??= TextEditingController());

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  /// 默认占位文案：没有设备名时退化为通用说法。
  String get _placeholder {
    final device = widget.deviceLabel.trim();
    return widget.placeholder ??
        (device.isEmpty ? '在远程设备上工作' : '在 $device 上工作');
  }

  /// 盾牌的完整提示文案；当前预设为空时返回 null（组件用「权限预设」）。
  String? get _permissionsLabel {
    final approval = widget.approvalLabel?.trim();
    if (approval == null || approval.isEmpty) return null;
    return '权限预设：$approval';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.floating) return _floating(context);
    return _inline(context);
  }

  /// 会话页的悬浮三态卡。
  Widget _floating(BuildContext context) => PocketComposer(
    mode: widget.mode,
    controller: _controller,
    focusNode: widget.focusNode,
    placeholder: _placeholder,
    enabled: widget.enabled,
    onChanged: widget.onChanged,
    onSubmitted: widget.onSubmitted,
    onAdd: widget.onAdd,
    onPermissions: widget.onApproval,
    permissionsLabel: _permissionsLabel,
    onReasoning: widget.onReasoning,
    reasoningDisabledReason: widget.reasoningDisabledReason,
    reasoningActive: widget.mode == PocketComposerMode.picker,
    onSend: widget.onSend,
    onStop: widget.onStop,
    sending: widget.sending,
    hasDraft: widget.hasDraft,
    sendKey: widget.sendKey,
    stopKey: widget.stopKey,
    reasoning: widget.mode == PocketComposerMode.picker
        ? widget.reasoning
        : null,
    top: widget.top,
  );

  /// 首页使用的紧凑单行输入条（与引入悬浮卡之前的形态一致）。
  Widget _inline(BuildContext context) {
    final enabled = widget.enabled;
    final model = widget.modelLabel?.trim();
    final hint = widget.hint?.trim();
    final colors = Theme.of(context).colorScheme;
    return GlassSurface(
      key: const ValueKey('remote-composer'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _RemoteCircleButton(
                  icon: Icons.add_rounded,
                  label: '添加与指令',
                  onPressed: enabled ? widget.onAdd : null,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: widget.focusNode,
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    textAlignVertical: TextAlignVertical.center,
                    style: AppTextStyle.subheadline.of(context),
                    onChanged: widget.onChanged,
                    onSubmitted: widget.onSubmitted,
                    decoration: InputDecoration(
                      hintText: _placeholder,
                      hintMaxLines: 1,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _RemoteCircleButton(
                  icon: Icons.shield_outlined,
                  label: _permissionsLabel ?? '权限预设',
                  onPressed: enabled ? widget.onApproval : null,
                ),
                const SizedBox(width: 2),
                _RemoteCircleButton(
                  icon: Icons.auto_awesome_outlined,
                  label: model == null || model.isEmpty ? '选择模型' : '模型：$model',
                  onPressed: enabled ? widget.onModel : null,
                ),
              ],
            ),
            if (hint != null && hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                child: Text(
                  hint,
                  key: const ValueKey('remote-composer-hint'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.caption1
                      .of(context)
                      .copyWith(color: colors.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 权限预设底部弹层：真实目录、当前项打勾，风险预设走二次确认。
///
/// 只做展示与弹层内的确认状态：目录、当前值与加载/失败状态由调用方从
/// `RemotePermissionController` 投影传入；选中一项后通过 [onApply] 提交。
/// 需要风险确认的预设（`danger-full-access` / `auto`）先在弹层内勾选确认再提交，
/// 与本地 `SessionPermissionPage` 用同一个确认面板。提交成功由弹层自己收起；
/// 失败保留弹层并显示原因，用户可以重试。
class RemotePermissionSheet extends StatefulWidget {
  const RemotePermissionSheet({
    super.key,
    required this.options,
    this.currentValue,
    this.loading = false,
    this.error,
    this.onRetry,
    this.onApply,
  });

  /// 电脑上的预设目录；为空且 [loading] 为 false 时显示空态。
  final List<RemotePermissionOption> options;

  /// 当前生效的预设值；null 表示还没读到投影，此时不打勾。
  final String? currentValue;

  /// 是否正在读取目录。
  final bool loading;

  /// 目录读取失败的原因；null 表示没有失败。
  final String? error;

  /// 目录读取失败后的重试；为 null 时不给重试入口。
  final VoidCallback? onRetry;

  /// 提交一次预设切换，返回失败原因；null 表示成功，弹层随之收起。
  final Future<String?> Function(String value)? onApply;

  @override
  State<RemotePermissionSheet> createState() => _RemotePermissionSheetState();
}

class _RemotePermissionSheetState extends State<RemotePermissionSheet> {
  /// 等待风险确认的预设值；null 表示正在展示预设列表。
  String? _pending;
  bool _acknowledged = false;
  bool _applying = false;
  String? _failure;

  Future<void> _pick(String value) async {
    if (widget.onApply == null || _applying) return;
    if (permissionPresetNeedsConfirmation(value)) {
      setState(() {
        _pending = value;
        _acknowledged = false;
        _failure = null;
      });
      return;
    }
    await _submit(value);
  }

  Future<void> _submit(String value) async {
    final apply = widget.onApply;
    if (apply == null || _applying) return;
    setState(() {
      _applying = true;
      _failure = null;
    });
    final failure = await apply(value);
    if (!mounted) return;
    if (failure == null) {
      // 切换成功：页面已经刷新投影并给出状态提示，这里只负责收起弹层。
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _applying = false;
      _failure = failure;
      _pending = null;
      _acknowledged = false;
    });
  }

  void _cancelPending() => setState(() {
    _pending = null;
    _acknowledged = false;
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _RemoteSheet(
      title: '权限预设',
      closeLabel: '关闭权限预设',
      children: [
        if (_pending case final value?)
          SessionPermissionRiskConfirmation(
            value: value,
            acknowledged: _acknowledged,
            onAcknowledged: (acknowledged) =>
                setState(() => _acknowledged = acknowledged),
            onCancel: _cancelPending,
            onConfirm: _acknowledged ? () => _submit(value) : null,
          )
        else
          ..._list(context),
        if (_failure case final failure?)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              failure,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colors.error),
            ),
          ),
      ],
    );
  }

  List<Widget> _list(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final options = widget.options;
    final error = widget.error;
    return <Widget>[
      if (error != null)
        PocketSection(
          children: [
            PocketTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 12,
              ),
              leading: Icon(Icons.error_outline_rounded, color: colors.error),
              title: const Text('无法读取权限预设'),
              subtitle: Text(
                error,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.onRetry != null)
              PocketTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('重新读取'),
                onTap: widget.onRetry,
              ),
          ],
        )
      else if (options.isEmpty && widget.loading)
        const PocketSection(
          children: [
            PocketTile(
              contentPadding: EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 12,
              ),
              leading: Icon(Icons.verified_user_outlined),
              title: Text('正在读取权限预设…'),
            ),
          ],
        )
      else if (options.isEmpty)
        const PocketSection(
          children: [
            PocketTile(
              contentPadding: EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 12,
              ),
              leading: Icon(Icons.verified_user_outlined),
              title: Text('电脑上没有可用的权限预设'),
            ),
          ],
        )
      else
        PocketSection(
          children: [for (final option in options) _option(context, option)],
        ),
      if (widget.currentValue == 'custom')
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 4, 18, 0),
          child: Text('当前使用自定义权限：沙箱模式与审批策略的组合不在预设表里。'),
        ),
      if (widget.loading && options.isNotEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                '正在更新权限预设…',
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      if (_applying)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                '正在切换权限预设…',
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _option(BuildContext context, RemotePermissionOption option) {
    final colors = Theme.of(context).colorScheme;
    final risk = permissionPresetNeedsConfirmation(option.value);
    final tint = risk ? colors.error : null;
    final selected = option.value == widget.currentValue;
    return PocketTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      leading: Icon(_permissionPresetIcon(option.value), color: tint),
      title: Text(
        permissionPresetLabel(option.value, option.name),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tint == null ? null : TextStyle(color: tint),
      ),
      subtitle: option.description == null
          ? null
          : Text(
              option.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: selected ? const Icon(Icons.check_rounded) : null,
      onTap: _applying ? null : () => _pick(option.value),
    );
  }
}

IconData _permissionPresetIcon(String value) => switch (value) {
  'read-only' => Icons.visibility_outlined,
  'workspace-write' => Icons.edit_outlined,
  'danger-full-access' => Icons.gpp_maybe_outlined,
  'auto' => Icons.auto_awesome_outlined,
  _ => Icons.verified_user_outlined,
};

/// 打开权限预设弹层。
///
/// 弹层本体由调用方给出（远程会话页放 `RemotePermissionSheet`，并用
/// `ListenableBuilder` 跟随 `RemotePermissionController` 刷新）；这里只负责模态
/// 路由、遮罩与减少动态效果。遮罩、返回手势与关闭按钮都不回调。
Future<void> showRemotePermissionSheet(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .4),
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: builder,
);

/// 打开「+」的会话指令菜单弹层。
///
/// 菜单本体由调用方给出（远程会话页放本地那套数据驱动的 `ComposerCommands`），
/// 这里只提供与权限预设弹层同一套外壳：超椭圆顶角、标题、关闭按钮、可滚动
/// 内容与减少动态效果。收起规则与 [showRemotePermissionSheet] 相同：遮罩、返回
/// 手势与关闭按钮都不回调，选中某一项由菜单自己的回调处理。
Future<void> showRemoteCommandsSheet(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .4),
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (sheetContext) => _RemoteSheet(
    title: '添加与指令',
    closeLabel: '关闭添加菜单',
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: builder(sheetContext),
      ),
    ],
  ),
);

/// 底部弹层的共同外壳：超椭圆顶角、玻璃或实心底色、把手、标题与关闭按钮。
///
/// 内容区可滚动，因此放大字体时仍然完整可达；底部安全区由内层 SafeArea 让出。
class _RemoteSheet extends StatelessWidget {
  const _RemoteSheet({
    required this.title,
    required this.closeLabel,
    required this.children,
  });

  /// 弹层标题。
  final String title;

  /// 关闭按钮的无障碍文案。
  final String closeLabel;

  /// 弹层正文，通常是若干 PocketSection。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final level = SurfaceLevel.floatingOf(colors);
    final shape = AppShape.top(AppCorner.xxl);
    return Semantics(
      container: true,
      scopesRoute: true,
      explicitChildNodes: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        child: DaylightSurface(
          shape: shape,
          color: level.colorOf(colors),
          enabled: LiquidGlassScope.of(context),
          child: Material(
            type: MaterialType.transparency,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 18,
                    child: Center(
                      child: Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colors.onSurfaceVariant.withValues(alpha: .5),
                          borderRadius: AppRadius.full,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        const SizedBox(width: 48),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: AppTextStyle.headline.of(
                              context,
                              emphasized: true,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: _RemoteCircleButton(
                            icon: Icons.close_rounded,
                            label: closeLabel,
                            onPressed: () => Navigator.maybePop(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: children,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 48dp 触摸区域的圆形玻璃按钮。
///
/// 共享的 [GlassButton] 视觉尺寸上限为 44dp，达不到远程外壳要求的 48dp 触摸
/// 目标，因此这里用同一套 FlClash 基元（[LiquidGlass]、[ElasticPress]）按
/// 48dp 重建同等外观：玻璃开启时是一块玻璃面，关闭时回退为透明底，按下由
/// 弹性缩放给出反馈，与 [GlassButton] 的规则一致。
class _RemoteCircleButton extends StatelessWidget {
  const _RemoteCircleButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;

  /// 无障碍文案，同时作为长按提示。
  final String label;

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final glass = LiquidGlassScope.of(context);
    final colors = Theme.of(context).colorScheme;
    return ElasticPress(
      enabled: onPressed != null,
      preserveAspectRatio: true,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: Icon(icon),
        style:
            IconButton.styleFrom(
              fixedSize: const Size.square(48),
              minimumSize: const Size.square(48),
              maximumSize: const Size.square(48),
              iconSize: 24,
              padding: EdgeInsets.zero,
              shape: const CircleBorder(),
              backgroundColor: glass ? Colors.transparent : null,
              disabledBackgroundColor: glass ? Colors.transparent : null,
              // 玻璃面自己负责按下时的亮度，水波纹只会在玻璃后面留下多余的
              // 痕迹，因此两种模式都不画水波纹，与 TonalButtonTheme 一致。
              overlayColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
            ).copyWith(
              backgroundBuilder: glass
                  ? (context, states, child) => LiquidGlass(
                      style: LiquidGlassStyle.regular(colors),
                      pressed: states.contains(WidgetState.pressed),
                      borderRadius: AppRadius.full,
                      child: child,
                    )
                  : null,
            ),
      ),
    );
  }
}

String _statusLabel(RemoteDeviceStatus status) => switch (status) {
  RemoteDeviceStatus.online => '在线',
  RemoteDeviceStatus.connecting => '连接中',
  RemoteDeviceStatus.offline => '离线',
};

Color _statusColor(ColorScheme colors, RemoteDeviceStatus status) =>
    switch (status) {
      RemoteDeviceStatus.online => colors.primary,
      RemoteDeviceStatus.connecting => colors.tertiary,
      RemoteDeviceStatus.offline => colors.outline,
    };
