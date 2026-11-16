// 共享悬浮输入卡：三态布局、工具条、发送/停止圆钮、推理面板与强度滑杆。
//
// 组件是受控的：这里用一个小 harness 持有状态与控制器，把状态切换、回调都
// 交给测试驱动，验证组件只按传入的状态绘制、只把点击回调出去。

import 'package:dsh_android/pocket_composer.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// 一个最小的受控宿主：状态、文本与焦点都在这里，组件本身不持有。
class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    this.initialMode = PocketComposerMode.browse,
    this.placeholder = '在 云端 上工作',
    this.onSend,
    this.onStop,
    this.onAdd,
    this.onPermissions,
    this.permissionsLabel = '权限预设：工作区内修改',
    this.onReasoning,
    this.reasoningDisabledReason,
    this.reasoning,
    this.onMic,
    this.actions = const <PocketComposerAction>[],
    this.top,
    this.hasDraft = false,
    this.sending = false,
    this.enabled = true,
    this.disableAnimations = false,
  });

  final PocketComposerMode initialMode;
  final String placeholder;
  final VoidCallback? onSend;
  final VoidCallback? onStop;
  final VoidCallback? onAdd;
  final VoidCallback? onPermissions;
  final String? permissionsLabel;
  final VoidCallback? onReasoning;
  final String? reasoningDisabledReason;
  final PocketReasoningPanel? reasoning;
  final VoidCallback? onMic;
  final List<PocketComposerAction> actions;
  final Widget? top;
  final bool hasDraft;
  final bool sending;
  final bool enabled;
  final bool disableAnimations;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late PocketComposerMode mode = widget.initialMode;
  final controller = TextEditingController();
  final focus = FocusNode();

  bool get hasDraft => widget.hasDraft || controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    focus.removeListener(_onFocusChanged);
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  /// 与页面同一条规则：聚焦输入即展开。
  void _onFocusChanged() {
    if (!mounted) return;
    if (focus.hasFocus && mode == PocketComposerMode.browse) {
      setState(() => mode = PocketComposerMode.composing);
    }
  }

  void _togglePanel() {
    widget.onReasoning?.call();
    final next = mode == PocketComposerMode.picker
        ? PocketComposerMode.composing
        : PocketComposerMode.picker;
    setState(() => mode = next);
    // 与页面一致：面板打开期间焦点留在输入框上（键盘不收起）。
    if (next == PocketComposerMode.picker && !focus.hasFocus) {
      focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: pocketTheme(Brightness.light),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: widget.disableAnimations),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: PocketComposer(
              mode: mode,
              controller: controller,
              focusNode: focus,
              placeholder: widget.placeholder,
              enabled: widget.enabled,
              onChanged: (_) => setState(() {}),
              onAdd: widget.onAdd,
              onPermissions: widget.onPermissions,
              permissionsLabel: widget.permissionsLabel,
              onReasoning:
                  widget.onReasoning == null &&
                      widget.reasoningDisabledReason == null
                  ? null
                  : _togglePanel,
              reasoningDisabledReason: widget.reasoningDisabledReason,
              reasoningActive: mode == PocketComposerMode.picker,
              actions: widget.actions,
              onMic: widget.onMic,
              onSend: widget.onSend,
              onStop: widget.onStop,
              sending: widget.sending,
              hasDraft: hasDraft,
              reasoning: mode == PocketComposerMode.picker
                  ? widget.reasoning
                  : null,
              top: widget.top,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<_HarnessState> _pump(
  WidgetTester tester, {
  Key? harnessKey,
  PocketComposerMode initialMode = PocketComposerMode.browse,
  String placeholder = '在 云端 上工作',
  VoidCallback? onSend,
  VoidCallback? onStop,
  VoidCallback? onAdd,
  VoidCallback? onPermissions,
  String? permissionsLabel = '权限预设：工作区内修改',
  VoidCallback? onReasoning,
  String? reasoningDisabledReason,
  PocketReasoningPanel? reasoning,
  VoidCallback? onMic,
  List<PocketComposerAction> actions = const <PocketComposerAction>[],
  Widget? top,
  bool hasDraft = false,
  bool sending = false,
  bool enabled = true,
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    _Harness(
      key: harnessKey,
      initialMode: initialMode,
      placeholder: placeholder,
      onSend: onSend,
      onStop: onStop,
      onAdd: onAdd,
      onPermissions: onPermissions,
      permissionsLabel: permissionsLabel,
      onReasoning: onReasoning,
      reasoningDisabledReason: reasoningDisabledReason,
      reasoning: reasoning,
      onMic: onMic,
      actions: actions,
      top: top,
      hasDraft: hasDraft,
      sending: sending,
      enabled: enabled,
      disableAnimations: disableAnimations,
    ),
  );
  // 发送中会一直显示进度动画，pumpAndSettle 不会收敛。
  if (sending) {
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }
  return tester.state<_HarnessState>(find.byType(_Harness));
}

Widget _topSlot() => const Padding(
  key: ValueKey('test-top-slot'),
  padding: EdgeInsets.only(bottom: 2),
  child: Text('attachments'),
);

const PocketReasoningStop _low = PocketReasoningStop(id: 'low', label: '低');
const PocketReasoningStop _medium = PocketReasoningStop(
  id: 'medium',
  label: '中',
);
const PocketReasoningStop _high = PocketReasoningStop(id: 'high', label: '高');

void main() {
  testWidgets('缩小态是一行悬浮卡：加号、占位与发送圆钮，没有权限与工具条动作', (tester) async {
    await _pump(tester);

    expect(find.byKey(PocketComposer.rootKey), findsOneWidget);
    expect(find.byKey(PocketComposer.cardKey), findsOneWidget);
    expect(find.text('在 云端 上工作'), findsOneWidget);
    expect(find.byTooltip('添加与指令'), findsOneWidget);
    // 参照图的缩小态没有权限按钮：权限预设只在展开态的工具条里。
    expect(find.byTooltip('权限预设：工作区内修改'), findsNothing);
    // 推理按钮只在展开态的工具条里。
    expect(find.byTooltip('推理强度'), findsNothing);
    // 没有草稿时不出现发送圆钮（既有页面断言依赖这里）。
    expect(find.byKey(PocketComposer.defaultSendKey), findsNothing);

    // 缩小态加号也是紧凑按钮：40dp 热区、没有 44dp 大圆底。
    expect(
      tester.getSize(find.byTooltip('添加与指令')),
      const Size(
        PocketComposer.toolbarButtonSize,
        PocketComposer.toolbarButtonSize,
      ),
    );

    // 卡片不贴边：左右各 16。
    final card = tester.getRect(find.byKey(PocketComposer.cardKey));
    expect(card.left, closeTo(16, .5));
    expect(
      card.right,
      closeTo(
        tester.view.physicalSize.width / tester.view.devicePixelRatio - 16,
        .5,
      ),
    );
  });

  testWidgets('缩小态没有权限预设按钮，展开后出现且小热区可点', (tester) async {
    var permissions = 0;
    await _pump(tester, onPermissions: () => permissions++, onReasoning: () {});
    expect(find.byTooltip('权限预设：工作区内修改'), findsNothing);

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('权限预设：工作区内修改'), findsOneWidget);

    // 工具条动作用小图标：40dp 热区（视觉只有 20dp 图标、无大圆底）。
    final add = tester.getSize(find.byTooltip('添加与指令'));
    expect(add, const Size(40, 40));
    final permissionsButton = tester.getSize(find.byTooltip('权限预设：工作区内修改'));
    expect(permissionsButton, const Size(40, 40));

    await tester.tap(find.byTooltip('权限预设：工作区内修改'));
    await tester.pump();
    expect(permissions, 1);
  });

  testWidgets('没有权限回调也没有置灰原因时，工具条不画权限按钮', (tester) async {
    await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onReasoning: () {},
      permissionsLabel: null,
    );
    expect(find.byTooltip('权限预设'), findsNothing, reason: '首页没有会话，不画死按钮');
    expect(find.byTooltip('推理强度'), findsOneWidget);
  });

  testWidgets('右侧发送圆钮是强调色实心圆，直径 44dp', (tester) async {
    await _pump(
      tester,
      onSend: () {},
      initialMode: PocketComposerMode.composing,
    );
    await tester.enterText(find.byKey(PocketComposer.inputKey), '你好');
    await tester.pump();

    final send = tester.getRect(find.byKey(PocketComposer.defaultSendKey));
    expect(send.width, PocketComposer.actionButtonSize);
    expect(send.height, PocketComposer.actionButtonSize);
  });

  testWidgets('聚焦展开：工具条出现，卡片向上生长', (tester) async {
    await _pump(tester, onReasoning: () {});
    final collapsed = tester.getSize(find.byKey(PocketComposer.cardKey)).height;

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();

    expect(find.byTooltip('推理强度'), findsOneWidget);
    final expanded = tester.getSize(find.byKey(PocketComposer.cardKey)).height;
    expect(expanded, greaterThan(collapsed));

    // 展开态是「输入区 + 工具条」两行：输入框仍在，且可用。
    expect(find.byKey(PocketComposer.inputKey), findsOneWidget);
  });

  testWidgets('有草稿时发送圆钮出现并回调；清空后收起', (tester) async {
    var sends = 0;
    await _pump(tester, onSend: () => sends++);

    await tester.enterText(find.byKey(PocketComposer.inputKey), '你好');
    await tester.pump();
    expect(find.byKey(PocketComposer.defaultSendKey), findsOneWidget);

    await tester.tap(find.byKey(PocketComposer.defaultSendKey));
    await tester.pump();
    expect(sends, 1);

    await tester.enterText(find.byKey(PocketComposer.inputKey), '');
    await tester.pump();
    expect(find.byKey(PocketComposer.defaultSendKey), findsNothing);
  });

  testWidgets('停止圆钮优先于发送；发送中只剩进度且不可重复点', (tester) async {
    var stops = 0;
    await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onStop: () => stops++,
      onSend: () {},
    );

    expect(find.byKey(PocketComposer.defaultStopKey), findsOneWidget);
    await tester.tap(find.byKey(PocketComposer.defaultStopKey));
    await tester.pump();
    expect(stops, 1);

    await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onStop: () {},
      onSend: () {},
      sending: true,
    );
    expect(find.byKey(PocketComposer.defaultStopKey), findsNothing);
    expect(find.byKey(PocketComposer.defaultSendKey), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开态工具条：加号、权限、推理、麦克风与额外动作都可点', (tester) async {
    final tapped = <String>[];
    await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onAdd: () => tapped.add('add'),
      onPermissions: () => tapped.add('permissions'),
      onReasoning: () => {},
      onMic: () => tapped.add('mic'),
      actions: <PocketComposerAction>[
        PocketComposerAction(
          icon: Icons.terminal_rounded,
          label: '终端',
          onPressed: () => tapped.add('terminal'),
        ),
        const PocketComposerAction(icon: Icons.archive_outlined, label: '归档会话'),
      ],
    );

    expect(find.byTooltip('添加与指令'), findsOneWidget);
    expect(find.byTooltip('权限预设：工作区内修改'), findsOneWidget);
    expect(find.byTooltip('推理强度'), findsOneWidget);
    expect(find.byTooltip('语音输入'), findsOneWidget);
    expect(find.byTooltip('终端'), findsOneWidget);
    expect(find.byTooltip('归档会话'), findsOneWidget);

    for (final tooltip in <String>['添加与指令', '权限预设：工作区内修改', '语音输入', '终端']) {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump();
    }
    expect(tapped, <String>['add', 'permissions', 'mic', 'terminal']);
    // 没有回调的额外动作置灰，点了不产生动作也不抛异常。
    await tester.tap(find.byTooltip('归档会话'), warnIfMissed: false);
    await tester.pump();
    expect(tapped, hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('推理面板：显示当前模型与档位，点档位回调，模型行可打开选择', (tester) async {
    final selected = <String>[];
    var openedModels = 0;
    var toggles = 0;
    await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onReasoning: () => toggles++,
      reasoning: PocketReasoningPanel(
        modelLabel: 'DeepSeek V4 Pro',
        effortLabel: '高',
        stops: const <PocketReasoningStop>[_low, _medium, _high],
        selectedId: 'high',
        onOpenModels: () => openedModels++,
        onSelected: selected.add,
      ),
    );

    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();

    expect(toggles, 1);
    expect(find.text('DeepSeek V4 Pro'), findsOneWidget);
    expect(find.text('高'), findsOneWidget);
    expect(find.byType(ReasoningEffortSlider), findsOneWidget);
    for (final stop in <PocketReasoningStop>[_low, _medium, _high]) {
      expect(find.byKey(PocketComposer.stopKeyFor(stop.id)), findsOneWidget);
    }

    await tester.tap(find.byKey(PocketComposer.stopKeyFor('medium')));
    await tester.pump();
    expect(selected, <String>['medium']);

    await tester.tap(find.byKey(PocketComposer.modelsKey));
    await tester.pump();
    expect(openedModels, 1);

    // 再次点推理按钮收起面板，回到输入态。
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();
    expect(find.text('DeepSeek V4 Pro'), findsNothing);
    expect(find.byType(ReasoningEffortSlider), findsNothing);
    expect(find.byKey(PocketComposer.inputKey), findsOneWidget);
  });

  testWidgets('推理面板用透明覆盖保留输入框与焦点，键盘不会因切换而收起', (tester) async {
    final state = await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onReasoning: () {},
      reasoning: const PocketReasoningPanel(modelLabel: 'DeepSeek V4 Pro'),
    );

    state.focus.requestFocus();
    await tester.pump();
    expect(state.focus.hasFocus, isTrue);

    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();

    expect(find.text('DeepSeek V4 Pro'), findsOneWidget);
    // 输入框仍然挂在树上、也在布局里（透明覆盖），所以输入法连接不会断；只是
    // 不再接受点击。
    expect(find.byKey(PocketComposer.inputKey), findsOneWidget);
    expect(
      find.byKey(PocketComposer.inputKey).hitTestable(),
      findsNothing,
      reason: '面板打开时输入框被透明层盖住，不接受点击',
    );
    expect(state.focus.hasFocus, isTrue);
  });

  testWidgets('模型没有声明强度时面板只显示模型名，不画空滑杆', (tester) async {
    await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onReasoning: () {},
      reasoning: const PocketReasoningPanel(
        modelLabel: 'DeepSeek Flash',
        effortLabel: '默认',
      ),
    );

    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();

    expect(find.text('DeepSeek Flash'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);
    expect(find.byType(ReasoningEffortSlider), findsNothing);
  });

  testWidgets('推理面板读取中显示进度，失败显示原因并可重试', (tester) async {
    var retries = 0;
    final stops = const <PocketReasoningStop>[_low, _high];

    await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onReasoning: () {},
      reasoning: const PocketReasoningPanel(
        modelLabel: 'DeepSeek V4 Pro',
        loading: true,
      ),
    );
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pump();
    expect(find.text('正在读取推理强度…'), findsOneWidget);

    await _pump(
      tester,
      harnessKey: const ValueKey('reasoning-error'),
      initialMode: PocketComposerMode.composing,
      onReasoning: () {},
      reasoning: PocketReasoningPanel(
        modelLabel: 'DeepSeek V4 Pro',
        stops: stops,
        error: '电脑上的 DSH 暂时不可用，请稍后重试。',
        onRetry: () => retries++,
      ),
    );
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();
    expect(find.textContaining('电脑上的 DSH 暂时不可用'), findsOneWidget);
    expect(find.byType(ReasoningEffortSlider), findsNothing);

    await tester.tap(find.byKey(PocketComposer.reasoningRetryKey));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('滑杆 busy 时忽略点击，松手后按档位回调', (tester) async {
    final selected = <String>[];
    await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onReasoning: () {},
      reasoning: PocketReasoningPanel(
        modelLabel: 'DeepSeek V4 Pro',
        effortLabel: '高',
        stops: const <PocketReasoningStop>[_low, _medium, _high],
        selectedId: 'high',
        busy: true,
        onSelected: selected.add,
      ),
    );
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(PocketComposer.stopKeyFor('low')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(selected, isEmpty, reason: '正在提交上一次切换时不接受新的点击');
    expect(tester.takeException(), isNull);
  });

  testWidgets('附件插槽显示在悬浮卡上方', (tester) async {
    await _pump(tester, top: _topSlot());

    final top = tester.getRect(find.byKey(const ValueKey('test-top-slot')));
    final card = tester.getRect(find.byKey(PocketComposer.cardKey));
    expect(top.bottom, lessThanOrEqualTo(card.top));
    expect(find.text('attachments'), findsOneWidget);
  });

  testWidgets('没有插槽时不占高度；有插槽整块变高', (tester) async {
    await _pump(tester);
    final withoutSlot = tester
        .getSize(find.byKey(PocketComposer.rootKey))
        .height;

    await _pump(tester, top: _topSlot());
    final withSlot = tester.getSize(find.byKey(PocketComposer.rootKey)).height;
    expect(withSlot, greaterThan(withoutSlot));
  });

  testWidgets('关闭玻璃时回退为实心表面，仍可交互', (tester) async {
    await _pump(
      tester,
      onSend: () {},
      initialMode: PocketComposerMode.composing,
    );
    await tester.enterText(find.byKey(PocketComposer.inputKey), '你好');
    await tester.pump();
    expect(find.byKey(PocketComposer.defaultSendKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果时不做尺寸过渡', (tester) async {
    await _pump(tester, disableAnimations: true);
    expect(
      find.byType(AnimatedSize),
      findsNothing,
      reason: '减少动态效果时直接换尺寸，不挂过渡动画',
    );

    await _pump(tester);
    expect(
      find.byType(AnimatedSize),
      findsOneWidget,
      reason: '尺寸过渡只有这一个 AnimatedSize，不做逐帧动画',
    );
    final normal = tester.widget<AnimatedSize>(find.byType(AnimatedSize));
    expect(normal.duration, const Duration(milliseconds: 200));
    expect(normal.alignment, Alignment.bottomCenter);
  });

  testWidgets('窄屏手机宽度下缩小、展开与面板都不溢出', (tester) async {
    // 402dp 逻辑宽度（常见手机），确认卡片宽度与换行在窄屏下成立。
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(
      tester,
      placeholder: '在 DESKTOP-DCVQRNSPC-2026 上工作',
      onReasoning: () {},
      onSend: () {},
      permissionsLabel: '权限预设：完全权限',
    );
    expect(tester.takeException(), isNull);
    final card = tester.getRect(find.byKey(PocketComposer.cardKey));
    expect(card.width, closeTo(370, .5), reason: '左右各 16dp 外边距');

    await tester.tap(find.byKey(PocketComposer.inputKey));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(PocketComposer.inputKey),
      '这是一段比较长的草稿，用来确认窄屏下多行输入不会把工具条挤出卡片。',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _pump(
      tester,
      harnessKey: const ValueKey('narrow-picker'),
      initialMode: PocketComposerMode.composing,
      onReasoning: () {},
      reasoning: PocketReasoningPanel(
        modelLabel: 'DeepSeek V4 Pro',
        effortLabel: '高',
        stops: const <PocketReasoningStop>[_low, _medium, _high],
        selectedId: 'high',
        onSelected: (_) {},
      ),
    );
    await tester.tap(find.byTooltip('推理强度'));
    await tester.pumpAndSettle();
    expect(find.byType(ReasoningEffortSlider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点卡片空白处也会请求输入焦点并展开', (tester) async {
    final state = await _pump(tester, onReasoning: () {});
    expect(state.focus.hasFocus, isFalse);

    // 卡片底部内边距是卡片空白区（不属于输入框与按钮）：点它也要能进入输入。
    final card = tester.getRect(find.byKey(PocketComposer.cardKey));
    await tester.tapAt(Offset(card.center.dx, card.bottom - 4));
    await tester.pumpAndSettle();

    expect(state.focus.hasFocus, isTrue);
    expect(find.byTooltip('推理强度'), findsOneWidget, reason: '点卡片空白处同样展开工具条');
  });

  testWidgets('工具条按钮不会抢走输入框焦点', (tester) async {
    final state = await _pump(
      tester,
      initialMode: PocketComposerMode.composing,
      onReasoning: () {},
      onAdd: () {},
      onPermissions: () {},
    );
    state.focus.requestFocus();
    await tester.pump();
    expect(state.focus.hasFocus, isTrue);

    await tester.tap(find.byTooltip('添加与指令'));
    await tester.pump();
    expect(state.focus.hasFocus, isTrue, reason: '点加号不应让输入框失焦');

    await tester.tap(find.byTooltip('权限预设：工作区内修改'));
    await tester.pump();
    expect(state.focus.hasFocus, isTrue, reason: '点盾牌不应让输入框失焦');
  });

  testWidgets('enabled 为 false 时输入框与工具条动作都不可用', (tester) async {
    await _pump(tester, enabled: false, onReasoning: () {});
    expect(
      tester.widget<TextField>(find.byKey(PocketComposer.inputKey)).enabled,
      isFalse,
    );
    final add = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('添加与指令'),
        matching: find.byType(IconButton),
      ),
    );
    expect(add.onPressed, isNull);
    expect(find.byKey(PocketComposer.defaultSendKey), findsNothing);
  });
}
