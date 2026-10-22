import 'package:material_ui/material_ui.dart';

import 'chat_goal_plan_state.dart';
import 'confirmation.dart';
import 'entry_motion.dart';
import 'models.dart' show ModelDraftGuard;
import 'text_document_page.dart';
import 'ui.dart';

String chatGoalPhaseLabel(ChatGoalPlanController state) =>
    switch (state.goal?.phase) {
      'active' =>
        !state.fresh
            ? '状态待确认'
            : state.activation == 'armed'
            ? '进行中'
            : state.activation == 'disarmed' || !state.attached
            ? '等待继续'
            : '正在确认运行状态',
      'paused' => '已暂停',
      'blocked' => '遇到阻碍',
      'complete' => '已完成',
      _ => '未设置目标',
    };

/// Compact goal dock; viewing it never activates or resumes a Session.
class ChatGoalDock extends StatelessWidget {
  const ChatGoalDock({required this.controller, super.key});
  final ChatGoalPlanController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final goal = controller.goal;
      if (goal == null || goal.phase == 'complete') {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: PocketReveal(
          child: GlassSurface(
            radius: 26,
            child: PocketTile(
              leading: const Icon(Icons.track_changes_rounded, size: 22),
              title: Text(chatGoalPhaseLabel(controller)),
              subtitle: Text(
                goal.objective,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () => openChatGoal(context, controller),
            ),
          ),
        ),
      );
    },
  );
}

Future<void> openChatGoal(
  BuildContext context,
  ChatGoalPlanController controller,
) => Navigator.of(
  context,
).push<void>(PocketRoute(builder: (_) => ChatGoalPage(controller: controller)));

/// Current goal management keeps decisions on the original service methods.
class ChatGoalPage extends StatefulWidget {
  const ChatGoalPage({required this.controller, super.key});
  final ChatGoalPlanController controller;
  @override
  State<ChatGoalPage> createState() => _ChatGoalPageState();
}

class _ChatGoalPageState extends State<ChatGoalPage> {
  bool confirmClear = false;
  ChatGoalState? clearBase;
  ChatGoalPlanController get state => widget.controller;

  Future<void> edit() => Navigator.of(context).push<void>(
    PocketRoute(
      builder: (_) => ChatGoalEditorPage(controller: state, base: state.goal),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final goal = state.goal;
      return PocketConfirmationLayer(
        confirmation: confirmClear
            ? PocketConfirmation(
                title: '清除当前目标？',
                message: '清除后不再按此目标继续。已经记录的会话内容会保留。',
                secondaryLabel: '取消',
                onSecondary: () => setState(() => confirmClear = false),
                primaryLabel: '清除目标',
                onPrimary: state.canMutate
                    ? () async {
                        setState(() => confirmClear = false);
                        await state.clear(clearBase);
                      }
                    : null,
              )
            : null,
        child: PocketScaffold(
          title: const Text('目标'),
          trailing: GlassButton(
            icon: Icons.refresh_rounded,
            label: '刷新目标',
            onPressed: state.loading || state.busy ? null : state.refresh,
          ),
          body: PocketList(
            children: [
              if (goal != null) ...[
                PocketSection(
                  divided: true,
                  children: [
                    PocketRow(
                      icon: Icons.track_changes_rounded,
                      title: '任务目标',
                      subtitle: goal.objective,
                      onTap: state.canMutate && goal.phase != 'complete'
                          ? edit
                          : null,
                    ),
                    PocketRow(
                      icon: Icons.timelapse_rounded,
                      title: '状态',
                      subtitle: chatGoalPhaseLabel(state),
                    ),
                    PocketRow(
                      icon: Icons.repeat_rounded,
                      title: '执行轮次',
                      subtitle: '${goal.roundsStarted} / ${goal.maxGoalRounds}',
                    ),
                  ],
                ),
                if (goal.blockedReason != null)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(goal.blockedReason!),
                  ),
                const SizedBox(height: 22),
                PocketSection(
                  divided: true,
                  children: [
                    if (goal.phase == 'active' && state.activation == 'armed')
                      PocketRow(
                        icon: Icons.pause_rounded,
                        title: '暂停目标',
                        onTap: state.canPause ? state.pause : null,
                      ),
                    if (goal.phase == 'paused' ||
                        goal.phase == 'blocked' ||
                        (goal.phase == 'active' && state.activation != 'armed'))
                      PocketRow(
                        icon: Icons.play_arrow_rounded,
                        title: '继续目标',
                        onTap: state.canResume ? state.resume : null,
                      ),
                    PocketRow(
                      icon: Icons.edit_outlined,
                      title: goal.phase == 'complete' ? '设置新目标' : '编辑目标',
                      onTap: state.canMutate ? edit : null,
                    ),
                    PocketRow(
                      icon: Icons.delete_outline_rounded,
                      title: '清除目标',
                      onTap: state.canMutate
                          ? () => setState(() {
                              clearBase = goal;
                              confirmClear = true;
                            })
                          : null,
                    ),
                  ],
                ),
              ] else
                PocketSection(
                  children: [
                    PocketRow(
                      icon: Icons.track_changes_rounded,
                      title: state.loading ? '正在读取目标' : '设置任务目标',
                      subtitle: '目标会在同一会话中持续推进。',
                      onTap: state.canMutate ? edit : null,
                    ),
                  ],
                ),
              if (state.busy)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('正在更新…'),
                ),
              if (!state.alive)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('已离开此会话，请返回重新打开。'),
                ),
              for (final text in [state.error, state.actionError])
                if (text != null)
                  Padding(padding: const EdgeInsets.all(20), child: Text(text)),
            ],
          ),
        ),
      );
    },
  );
}

/// Draft and its CAS ref are retained independently of live goal updates.
class ChatGoalEditorPage extends StatefulWidget {
  const ChatGoalEditorPage({required this.controller, this.base, super.key});
  final ChatGoalPlanController controller;
  final ChatGoalState? base;
  @override
  State<ChatGoalEditorPage> createState() => _ChatGoalEditorPageState();
}

class _ChatGoalEditorPageState extends State<ChatGoalEditorPage> {
  late ChatGoalState? base = widget.base?.phase == 'complete'
      ? null
      : widget.base;
  late String objective = base?.objective ?? '';
  late int? roundLimit = base?.maxGoalRounds;
  bool saved = false;
  ChatGoalPlanController get state => widget.controller;
  bool get conflict =>
      base != null &&
      (state.goal?.id != base!.id || state.goal?.revision != base!.revision);
  bool get dirty =>
      !saved &&
      (objective != (base?.objective ?? '') ||
          roundLimit != base?.maxGoalRounds);

  Future<void> editObjective() async {
    final value = await Navigator.of(context).push<String>(
      PocketRoute(
        builder: (_) => TextDocumentPage(
          title: '任务目标',
          text: objective,
          readOnly: false,
          validate: (value) => value.trim().isEmpty ? '请填写需要完成的目标。' : null,
        ),
      ),
    );
    if (mounted && value != null) setState(() => objective = value);
  }

  Future<void> editLimit() async {
    final value = await Navigator.of(context).push<String>(
      PocketRoute(
        builder: (_) => TextDocumentPage(
          title: '最多执行轮次',
          text: '$roundLimit',
          readOnly: false,
          keyboardType: TextInputType.number,
          helperText: '达到轮次上限后停止自动继续，可增加上限后继续。',
          validate: (value) {
            final number = int.tryParse(value.trim());
            return number == null || number < 1 || number > 9007199254740991
                ? '请输入大于 0 的有效整数。'
                : null;
          },
        ),
      ),
    );
    if (mounted && value != null) {
      setState(() => roundLimit = int.parse(value.trim()));
    }
  }

  Future<void> save() async {
    if (objective.trim().isEmpty || conflict || !state.canMutate) return;
    final accepted = base == null
        ? await state.create(objective)
        : await state.edit(
            base!,
            objective: objective,
            maxGoalRounds: roundLimit!,
          );
    if (!mounted || !accepted) return;
    setState(() => saved = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => ModelDraftGuard(
      hasEdits: () => dirty,
      busy: state.busy,
      child: PocketScaffold(
        title: Text(base == null ? '设置目标' : '编辑目标'),
        trailing: GlassButton(
          icon: Icons.check_rounded,
          label: '保存目标',
          solid: true,
          onPressed: state.canMutate && !conflict && objective.trim().isNotEmpty
              ? save
              : null,
        ),
        body: PocketList(
          children: [
            PocketSection(
              divided: true,
              children: [
                PocketRow(
                  icon: Icons.track_changes_rounded,
                  title: '任务目标',
                  subtitle: objective.isEmpty ? '描述需要完成的工作' : objective,
                  onTap: state.busy ? null : editObjective,
                ),
                if (roundLimit != null)
                  PocketRow(
                    icon: Icons.repeat_rounded,
                    title: '最多执行轮次',
                    subtitle: '$roundLimit',
                    onTap: state.busy ? null : editLimit,
                  ),
              ],
            ),
            if (conflict) ...[
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('目标已在另一处更改。你的编辑已保留，请先比较最新内容。'),
              ),
              if (state.goal != null)
                PocketSection(
                  children: [
                    PocketRow(
                      icon: Icons.article_outlined,
                      title: '最新目标',
                      subtitle: state.goal!.objective,
                    ),
                    if (state.goal!.id == base?.id &&
                        state.goal!.phase != 'complete')
                      PocketRow(
                        icon: Icons.compare_arrows_rounded,
                        title: '保留草稿，采用最新版本继续编辑',
                        onTap: state.canMutate
                            ? () => setState(() => base = state.goal)
                            : null,
                      ),
                  ],
                ),
            ],
            for (final text in [state.error, state.actionError])
              if (text != null)
                Padding(padding: const EdgeInsets.all(20), child: Text(text)),
          ],
        ),
      ),
    ),
  );
}
