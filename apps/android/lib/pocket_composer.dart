// 共享的悬浮输入卡：缩小的浏览态、展开的输入态与按钮触发的推理强度面板。
//
// 组件是受控的：状态由父页面通过 [PocketComposerMode] 持有，输入文本与焦点由
// 外部传入的 [TextEditingController] / [FocusNode] 持有，组件自己只画界面并把
// 点击交给回调。三种状态：
//
// - [PocketComposerMode.browse]：一行悬浮卡（加号、占位文案、可选麦克风、发送
//   圆钮），用于浏览对话、键盘收起时；
// - [PocketComposerMode.composing]：卡片向上生长为「输入区 + 工具条一行」（加号、
//   可选动作、发送/停止圆钮），用于聚焦输入或键盘弹起时；
// - [PocketComposerMode.picker]：输入区被「当前模型 + 推理强度滑杆」面板替换，
//   输入框仍然挂载并被面板透明覆盖（不移出布局、不失焦），键盘因此保持；工具条
//   保留以便再次点推理按钮收起面板。
//
// 高度只在状态切换时变化，由一次 [AnimatedSize] 过渡（200ms；减少动态效果时不
// 挂这个动画，直接换尺寸）；组件不使用定时器，也不做逐帧动画。输入多行时卡片会
// 随文本增高，同样交给这一个 [AnimatedSize]。
//
// 外观沿用 App 既有约定：颜色只从 Theme 取（含纯黑变体），玻璃开关看
// [LiquidGlassScope]（[GlassSurface] 自己处理），字号走 [AppTextStyle]，减少
// 动态效果看 `MediaQuery.disableAnimations`。圆钮复用既有 [GlassButton]，因此
// 按压反馈与页面其它圆形按钮一致。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'flclash/surface.dart';
import 'flclash/typography.dart';
import 'ui.dart';

/// 输入卡的三种状态。
enum PocketComposerMode {
  /// 缩小态：单行悬浮卡，浏览对话时使用。
  browse,

  /// 展开态：输入区加工具条一行，聚焦输入或键盘弹起时使用。
  composing,

  /// 推理面板态：输入区被「当前模型 + 推理强度滑杆」替换。
  picker,
}

/// 推理强度面板里的一档强度。
///
/// [label] 是调用方给的显示名（例如「低 / 中 / 高 / 最高」），同时用作这一档的
/// 无障碍文案与长按提示；[id] 是点选后回传的标识（进入 `selectModel` 的
/// `reasoningEffort`）。
@immutable
class PocketReasoningStop {
  const PocketReasoningStop({required this.id, required this.label});

  /// 档位标识，点选时通过 `PocketReasoningPanel.onSelected` 回传。
  final String id;

  /// 档位显示名。
  final String label;
}

/// 推理面板（[PocketComposerMode.picker]）的数据与回调。
///
/// 只做展示与回调：当前模型名、可选档位与选中档位由调用方从模型目录与当前会话
/// 选择投影传入，点选某个档位由 [onSelected] 提交；面板不读目录、不发请求。
@immutable
class PocketReasoningPanel {
  const PocketReasoningPanel({
    required this.modelLabel,
    this.effortLabel = '默认',
    this.stops = const <PocketReasoningStop>[],
    this.selectedId,
    this.loading = false,
    this.error,
    this.busy = false,
    this.onOpenModels,
    this.onRetry,
    this.onSelected,
  });

  /// 当前模型显示名，显示在面板第一行。
  final String modelLabel;

  /// 当前推理强度的显示名，显示在模型名之后；模型没有声明强度时为「默认」。
  final String effortLabel;

  /// 可选档位；为空表示这个模型没有可调的推理强度，面板只显示模型名。
  final List<PocketReasoningStop> stops;

  /// 当前选中档位的标识；为 null 时滑杆停在第一档。
  final String? selectedId;

  /// 是否正在读取模型目录；读取期间显示一行进度而不是滑杆。
  final bool loading;

  /// 读取或切换失败的可见原因；非空时显示原因与重试入口。
  final String? error;

  /// 是否正在提交一次强度切换；期间滑杆不可点。
  final bool busy;

  /// 点按模型名：打开完整的模型选择弹层；为 null 时这一行只展示。
  final VoidCallback? onOpenModels;

  /// 失败后的重试入口；为 null 时不显示重试。
  final VoidCallback? onRetry;

  /// 点选某个强度档位；为 null 时滑杆只展示不可点。
  final ValueChanged<String>? onSelected;
}

/// 工具条上的一个额外动作。
///
/// 权限预设、推理强度与麦克风有专门的参数；这个类型留给调用方追加自己的入口
/// （例如本地的命令 chip），避免每加一个动作就改一次组件 API。
@immutable
class PocketComposerAction {
  const PocketComposerAction({
    required this.icon,
    required this.label,
    this.onPressed,
    this.active = false,
  });

  /// 动作图标。
  final IconData icon;

  /// 无障碍文案与长按提示，同时也是按钮的点击语义。
  final String label;

  /// 点按回调；为 null 时按钮置灰。
  final VoidCallback? onPressed;

  /// 是否处于高亮态（例如对应的面板已经打开）。
  final bool active;
}

/// 悬浮输入卡：三态、工具条与推理强度面板。
///
/// 组件不持有业务状态、不发请求、不设置 autofocus；进入页面不会自动弹出键盘。
/// 父页面根据焦点、草稿与键盘决定 [mode]，并在 [PocketComposerMode.picker] 时
/// 提供 [reasoning] 面板数据。整张卡在非 picker 态可点：点空白处会把焦点交给
/// 输入框并显式请求输入法显示，避免真机上「点了没反应」。输入框多行增高与状态
/// 切换的高度变化都由组件内部唯一的 [AnimatedSize] 过渡（减少动态效果时直接换
/// 尺寸，不挂这个动画）。
class PocketComposer extends StatelessWidget {
  const PocketComposer({
    super.key,
    required this.mode,
    required this.controller,
    this.focusNode,
    this.placeholder = '',
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
    this.onAdd,
    this.addLabel = '添加与指令',
    this.onPermissions,
    this.permissionsLabel,
    this.onReasoning,
    this.reasoningLabel = '推理强度',
    this.reasoningDisabledReason,
    this.reasoningActive = false,
    this.actions = const <PocketComposerAction>[],
    this.onMic,
    this.micLabel = '语音输入',
    this.onSend,
    this.onStop,
    this.sending = false,
    this.hasDraft = false,
    this.sendKey,
    this.stopKey,
    this.reasoning,
    this.top,
    this.margin,
  });

  /// 组件根节点的稳定标识（测试与无障碍定位用）。
  static const Key rootKey = ValueKey('pocket-composer');

  /// 悬浮玻璃卡的标识；父页面测试用它量高度、确认缩小/展开。
  static const Key cardKey = ValueKey('pocket-composer-card');

  /// 输入框的标识。
  static const Key inputKey = ValueKey('pocket-composer-input');

  /// 默认的发送圆钮标识；调用方传 [sendKey] 时改用调用方的标识。
  static const Key defaultSendKey = ValueKey('pocket-composer-send');

  /// 默认的停止圆钮标识；调用方传 [stopKey] 时改用调用方的标识。
  static const Key defaultStopKey = ValueKey('pocket-composer-stop');

  /// 推理面板里模型名那一行的标识（点按打开完整模型选择）。
  static const Key modelsKey = ValueKey('pocket-composer-models');

  /// 推理面板读取失败后的重试入口标识。
  static const Key reasoningRetryKey = ValueKey(
    'pocket-composer-reasoning-retry',
  );

  /// 强度滑杆中某一档的标识前缀。
  static const String stopKeyPrefix = 'pocket-reasoning-stop-';

  /// 某一档强度滑杆档位的标识。
  static Key stopKeyFor(String id) => ValueKey('$stopKeyPrefix$id');

  /// 卡片状态；由父页面持有。
  final PocketComposerMode mode;

  /// 输入框控制器；由父页面持有，组件不释放。
  final TextEditingController controller;

  /// 输入框焦点节点；由父页面持有，组件不会主动请求焦点。为 null 时输入框使用
  /// 自己的焦点节点（调用方也就无法从外部控制展开/收起，一般应传入）。
  final FocusNode? focusNode;

  /// 占位文案，例如「在 云端 上工作」。
  final String placeholder;

  /// 为 false 时输入框与全部按钮都不可用。
  final bool enabled;

  /// 输入变化回调。
  final ValueChanged<String>? onChanged;

  /// 键盘提交回调。
  final ValueChanged<String>? onSubmitted;

  /// 加号回调：展开添加/指令菜单。
  final VoidCallback? onAdd;

  /// 加号的无障碍文案。
  final String addLabel;

  /// 权限预设回调；为 null 时盾牌置灰。
  final VoidCallback? onPermissions;

  /// 盾牌的完整无障碍文案（例如「权限预设：工作区内修改」）；为空时用「权限预设」。
  final String? permissionsLabel;

  /// 推理强度按钮回调：进入或退出 [PocketComposerMode.picker]。
  ///
  /// 为 null 且 [reasoningDisabledReason] 非空时按钮置灰并把原因写进提示。
  final VoidCallback? onReasoning;

  /// 推理强度按钮的无障碍文案。
  final String reasoningLabel;

  /// 推理强度按钮不可用的原因；为 null 且 [onReasoning] 为 null 时不显示按钮。
  final String? reasoningDisabledReason;

  /// 推理按钮是否高亮（面板已展开）。
  final bool reasoningActive;

  /// 调用方追加的工具条动作，排在推理按钮之后。
  final List<PocketComposerAction> actions;

  /// 麦克风回调；为 null 时不显示麦克风（远程会话没有录音实现）。
  final VoidCallback? onMic;

  /// 麦克风的无障碍文案。
  final String micLabel;

  /// 发送回调；为 null 时发送圆钮永远置灰。
  final VoidCallback? onSend;

  /// 停止回调；非 null 时右侧圆钮显示停止。
  final VoidCallback? onStop;

  /// 是否正在发送/提交：右侧圆钮换成进度，不回传点击。
  final bool sending;

  /// 是否有可发送内容（草稿文本或附件）；决定发送圆钮是否可点与是否带 [sendKey]。
  final bool hasDraft;

  /// 发送圆钮的标识；为 null 时用 [defaultSendKey]。只有可发送时才带这个标识，
  /// 「没有草稿时发送按钮不存在」的既有断言依赖这一点。
  final Key? sendKey;

  /// 停止圆钮的标识；为 null 时用 [defaultStopKey]。
  final Key? stopKey;

  /// [PocketComposerMode.picker] 状态的面板数据；其它状态忽略。
  final PocketReasoningPanel? reasoning;

  /// 卡片上方的插槽（附件 rail、命令 chip 等）；为 null 时不占高度。
  final Widget? top;

  /// 卡片外边距；为 null 时用默认值（左右 16、上下 12）。
  ///
  /// 页面自己已经让出水平边距时（例如本地聊天页的 `PocketScaffold.bottom` 自带
  /// 左右 16），传更小的值可以避免两处边距叠加；远程会话页不传，保持默认外观。
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final top = this.top;
    final card = _card(context);
    return Padding(
      key: rootKey,
      // 悬浮卡不贴边：左右 16；上下 12（安全区由页面自己的 SafeArea 让出）。
      padding: margin ?? const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (top != null) ...[top, const SizedBox(height: 8)],
          // 减少动态效果时不挂 AnimatedSize：框架在「零时长 + 同一帧尺寸变化」
          // 下会断言（RenderAnimatedSize 在 layout 里重入），且此时本来就不该有
          // 过渡动画。
          if (reduceMotion)
            card
          else
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.bottomCenter,
              // 阴影画在卡片外面，过渡期间不能被裁剪掉。
              clipBehavior: Clip.none,
              child: card,
            ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final picking = mode == PocketComposerMode.picker;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: AppRadius.xxl,
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: dark ? .38 : .12),
            blurRadius: 24,
            spreadRadius: -6,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: GlassSurface(
        key: cardKey,
        radius: AppCorner.xxl,
        // 缩小时整卡可点：点卡片空白处（占位文案两侧、内边距里）也把焦点交给
        // 输入框并显式请求一次 IME 显示，避免「点了没反应」。picker 态卡片交给
        // 面板自己的点击目标处理。
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: picking ? null : _requestInputFocus,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Stack(
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.none,
                  children: [
                    // 输入行永远在树上、也在布局里（picker 态透明且不吃指针）：
                    // 不卸载子树、不移出布局，焦点与输入法连接因此不断，键盘不会
                    // 因为切到面板而被系统收起。
                    IgnorePointer(
                      ignoring: picking,
                      child: Opacity(
                        opacity: picking ? 0 : 1,
                        child: _inputRow(context),
                      ),
                    ),
                    // 面板叠在输入行上方：模型行与滑杆从卡片顶部开始，视觉上就是
                    // 「输入区被替换」。
                    if (picking) _pickerPanel(context),
                  ],
                ),
                if (mode != PocketComposerMode.browse) ...[
                  const SizedBox(height: 2),
                  _toolbar(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 把焦点交给输入框，并显式请求一次输入法显示。
  ///
  /// 真机上出现过「点按后卡片展开了，但键盘没起来」：一是聚焦与系统输入法的
  /// 时序抖动，二是输入框已经聚焦、但 IME 被系统藏起来时再点不会自动重新显示。
  /// 这里先 requestFocus，再补一次 `TextInput.show`（没有活动输入连接时是空
  /// 操作），保证从缩小态点按一定能进入输入且弹出键盘。
  void _requestInputFocus() {
    final node = focusNode;
    if (node == null) return;
    node.requestFocus();
    // 等这一帧结束（输入框完成聚焦、输入连接重建）再补一次显示请求：输入框已经
    // 聚焦但 IME 被系统藏起来时，再 requestFocus 不会自动弹键盘，只有显式 show
    // 才能让「点一下」重新进入输入。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!node.hasFocus) return;
      unawaited(_showInput());
    });
  }

  Future<void> _showInput() async {
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } on Object {
      // 测试环境或输入连接尚未建立时通道可能不可用：忽略即可，点按展开不依赖它。
    }
  }

  // ------------------------------------------------------------ 输入行

  Widget _inputRow(BuildContext context) {
    final browse = mode == PocketComposerMode.browse;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 缩小时加号在行内；展开时它移到下方工具条，这里留零宽占位以保持
        // 输入框在同一个 Row 槽位（元素的父子关系不变，焦点不闪断）。
        SizedBox(
          width: browse ? 46 : 0,
          height: 44,
          child: browse
              ? _iconButton(
                  context,
                  icon: Icons.add_rounded,
                  label: addLabel,
                  onPressed: onAdd,
                )
              : null,
        ),
        Expanded(
          key: const ValueKey('pocket-composer-input-slot'),
          child: _input(context),
        ),
        if (browse)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: _browseTrailing(context),
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }

  Widget _input(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextField(
      key: inputKey,
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      minLines: 1,
      maxLines: 4,
      textInputAction: TextInputAction.newline,
      textAlignVertical: TextAlignVertical.center,
      style: AppTextStyle.subheadline.of(context),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: placeholder,
        hintMaxLines: 1,
        hintStyle: AppTextStyle.subheadline
            .of(context)
            .copyWith(color: colors.onSurfaceVariant),
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
      ),
    );
  }

  /// 缩小态里输入框右侧的按钮：盾牌（保持既有权限入口）、可选麦克风、发送。
  List<Widget> _browseTrailing(BuildContext context) {
    final permissions = _permissionsButton(context);
    final mic = _micButton(context);
    return <Widget>[
      permissions,
      if (mic != null) ...[const SizedBox(width: 2), mic],
      const SizedBox(width: 2),
      _trailingAction(context),
    ];
  }

  // ------------------------------------------------------------ 工具条

  Widget _toolbar(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      _iconButton(
        context,
        icon: Icons.add_rounded,
        label: addLabel,
        onPressed: onAdd,
      ),
      const SizedBox(width: 2),
      _permissionsButton(context),
      ..._reasoningToolbarItems(context),
      for (final action in actions) ...[
        const SizedBox(width: 2),
        _actionButton(context, action),
      ],
      const Spacer(),
      if (_micButton(context) case final mic?) ...[
        mic,
        const SizedBox(width: 2),
      ],
      _trailingAction(context),
    ],
  );

  List<Widget> _reasoningToolbarItems(BuildContext context) {
    final button = _reasoningButton(context);
    if (button == null) return const <Widget>[];
    return <Widget>[const SizedBox(width: 2), button];
  }

  Widget? _reasoningButton(BuildContext context) {
    final onReasoning = this.onReasoning;
    final disabledReason = reasoningDisabledReason?.trim();
    if (onReasoning == null &&
        (disabledReason == null || disabledReason.isEmpty)) {
      return null;
    }
    return GlassButton(
      icon: Icons.speed_rounded,
      label: onReasoning == null ? disabledReason! : reasoningLabel,
      solid: reasoningActive,
      onPressed: enabled ? onReasoning : null,
    );
  }

  Widget _permissionsButton(BuildContext context) {
    final label = permissionsLabel?.trim();
    return GlassButton(
      icon: Icons.shield_outlined,
      label: label == null || label.isEmpty ? '权限预设' : label,
      onPressed: enabled ? onPermissions : null,
    );
  }

  Widget? _micButton(BuildContext context) {
    final onMic = this.onMic;
    if (onMic == null) return null;
    return GlassButton(
      icon: Icons.mic_none_rounded,
      label: micLabel,
      onPressed: enabled ? onMic : null,
    );
  }

  Widget _actionButton(BuildContext context, PocketComposerAction action) =>
      GlassButton(
        icon: action.icon,
        label: action.label,
        solid: action.active,
        onPressed: enabled ? action.onPressed : null,
      );

  Widget _iconButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => GlassButton(
    icon: icon,
    label: label,
    onPressed: enabled ? onPressed : null,
  );

  /// 右侧主圆钮：发送中显示进度；可停止时显示停止；否则是发送。
  ///
  /// 发送圆钮只在 [hasDraft] 时可点并带 [sendKey]，与既有「没有草稿时发送按钮
  /// 不存在」的页面断言一致。
  Widget _trailingAction(BuildContext context) {
    if (sending) {
      return const SizedBox.square(
        dimension: 44,
        child: Center(
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final onStop = enabled ? this.onStop : null;
    if (onStop != null) {
      return GlassButton(
        key: stopKey ?? defaultStopKey,
        icon: Icons.stop_rounded,
        label: '停止任务',
        solid: true,
        onPressed: onStop,
      );
    }
    final canSend = enabled && hasDraft && onSend != null;
    return GlassButton(
      key: canSend ? (sendKey ?? defaultSendKey) : null,
      icon: Icons.arrow_upward_rounded,
      label: '发送',
      solid: true,
      onPressed: canSend ? onSend : null,
    );
  }

  // ------------------------------------------------------------ 推理面板

  Widget _pickerPanel(BuildContext context) {
    final data = reasoning;
    if (data == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final error = data.error?.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: _modelRow(context, data)),
        const SizedBox(height: 10),
        if (data.loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  '正在读取推理强度…',
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          )
        else if (error != null && error.isNotEmpty)
          Row(
            children: [
              Expanded(
                child: Text(
                  error,
                  key: const ValueKey('pocket-composer-reasoning-error'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colors.error),
                ),
              ),
              if (data.onRetry != null)
                TextButton(
                  key: reasoningRetryKey,
                  onPressed: data.onRetry,
                  child: const Text('重试'),
                ),
            ],
          )
        else if (data.stops.isNotEmpty)
          ReasoningEffortSlider(
            stops: data.stops,
            selectedId: data.selectedId,
            busy: data.busy,
            onSelected: data.onSelected,
          ),
      ],
    );
  }

  Widget _modelRow(BuildContext context, PocketReasoningPanel data) {
    final colors = Theme.of(context).colorScheme;
    final labelStyle = AppTextStyle.headline.of(context, emphasized: true);
    final onOpenModels = data.onOpenModels;
    return Semantics(
      button: onOpenModels != null,
      label: '选择模型：${data.modelLabel}',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: modelsKey,
          customBorder: AppShape.full,
          onTap: onOpenModels,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    data.modelLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  data.effortLabel,
                  maxLines: 1,
                  style: AppTextStyle.headline
                      .of(context)
                      .copyWith(color: colors.onSurfaceVariant),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 推理强度滑杆：按档位画点与滑块，点选一档回调该档标识。
///
/// 视觉是一颗胶囊形的玻璃底槽、一段 App 强调色填充与一枚白色滑钮；档位数量与
/// 显示名来自 [stops]，当前档位来自 [selectedId]。没有档位时由调用方不渲染本
/// 组件（面板只显示模型名）；[busy] 为 true 时忽略点击，避免一次切换未完成时
/// 重复提交。
class ReasoningEffortSlider extends StatelessWidget {
  const ReasoningEffortSlider({
    super.key,
    required this.stops,
    this.selectedId,
    this.onSelected,
    this.busy = false,
  });

  /// 可选档位，按由弱到强排列。
  final List<PocketReasoningStop> stops;

  /// 当前选中档位的标识；没有匹配时停在第一档。
  final String? selectedId;

  /// 点选回调；为 null 时只展示。
  final ValueChanged<String>? onSelected;

  /// 是否正在提交上一次切换；为 true 时不可点。
  final bool busy;

  /// 滑杆高度。
  static const double height = 44;

  /// 滑钮直径。
  static const double _knob = 26;

  /// 档位圆点直径。
  static const double _dot = 6;

  /// 单档触摸宽度；档位中心之间的留白之外的点击落到最近的档。
  static const double _hitWidth = 44;

  @override
  Widget build(BuildContext context) {
    if (stops.isEmpty) return const SizedBox.shrink();
    final onSelected = busy ? null : this.onSelected;
    final selected = _selectedIndex();
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '推理强度',
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final centers = _centers(constraints.maxWidth);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 档位之间的空白落到最近的一档：整条滑杆都是可点区域。单档的
              // 触摸区压在它上面，精确点某一档时优先命中那一档。
              onTapUp: onSelected == null
                  ? null
                  : (details) {
                      final nearest = _nearest(
                        centers,
                        details.localPosition.dx,
                      );
                      onSelected(stops[nearest].id);
                    },
              child: _track(context, centers, selected, onSelected),
            );
          },
        ),
      ),
    );
  }

  int _selectedIndex() {
    if (stops.isEmpty) return 0;
    final index = stops.indexWhere((stop) => stop.id == selectedId);
    return index < 0 ? 0 : index;
  }

  /// 每一档圆点的水平中心；首尾各留半个触摸宽度，避免触摸区越界。
  List<double> _centers(double width) {
    if (stops.length == 1) return <double>[width / 2];
    final inset = math.min(_hitWidth / 2, width / 2);
    final usable = math.max(0.0, width - inset * 2);
    return <double>[
      for (var index = 0; index < stops.length; index++)
        inset + usable * index / (stops.length - 1),
    ];
  }

  Widget _track(
    BuildContext context,
    List<double> centers,
    int selected,
    ValueChanged<String>? onSelected,
  ) {
    final colors = Theme.of(context).colorScheme;
    final track = SurfaceLevel.inset.colorOf(colors);
    final accent = colors.primary;
    final dotColor = colors.onSurfaceVariant.withValues(alpha: .45);
    final activeDotColor = colors.onPrimary.withValues(alpha: .7);
    final knobColor = colors.onPrimary;
    final knobShadow = colors.shadow.withValues(alpha: .18);
    final knobX = centers.isEmpty ? 0.0 : centers[selected];
    final stopCount = stops.length;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: track,
              borderRadius: AppRadius.full,
            ),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: knobX,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: accent,
              borderRadius: AppRadius.full,
            ),
          ),
        ),
        for (var index = 0; index < stopCount; index++)
          Positioned(
            left: centers[index] - _dot / 2,
            top: (height - _dot) / 2,
            child: IgnorePointer(
              child: Container(
                width: _dot,
                height: _dot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: index <= selected ? activeDotColor : dotColor,
                ),
              ),
            ),
          ),
        Positioned(
          left: knobX - _knob / 2,
          top: (height - _knob) / 2,
          child: IgnorePointer(
            child: Container(
              width: _knob,
              height: _knob,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: knobColor,
                boxShadow: [
                  BoxShadow(
                    color: knobShadow,
                    blurRadius: 6,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 每一档一个 44dp 宽的透明触摸区：无障碍上是一组可选中按钮。
        for (var index = 0; index < stopCount; index++)
          Positioned(
            key: PocketComposer.stopKeyFor(stops[index].id),
            left: math.max(0.0, centers[index] - _hitWidth / 2),
            top: 0,
            width: _hitWidth,
            height: height,
            child: Semantics(
              button: onSelected != null,
              selected: index == selected,
              label: stops[index].label,
              child: Tooltip(
                message: stops[index].label,
                waitDuration: const Duration(milliseconds: 500),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onSelected == null
                      ? null
                      : () => onSelected(stops[index].id),
                ),
              ),
            ),
          ),
      ],
    );
  }

  int _nearest(List<double> centers, double x) {
    var nearest = 0;
    var distance = double.infinity;
    for (var index = 0; index < centers.length; index++) {
      final delta = (centers[index] - x).abs();
      if (delta < distance) {
        distance = delta;
        nearest = index;
      }
    }
    return nearest;
  }
}
