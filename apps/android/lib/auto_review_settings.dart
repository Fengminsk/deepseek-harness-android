import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'configuration_boolean_preference.dart';
import 'runtime.dart';
import 'ui.dart';

/// The Android Auto review switch, stored in the profile's plugin configuration.
class AutoReviewPreference extends ConfigurationBooleanPreference {
  AutoReviewPreference(super.runtime) : super(namespace: 'android-auto-review');

  bool get enabled => value;
  Future<bool> setEnabled(bool next) => setValue(next);
}

/// Default-off Auto review page: the accepted switch state, its failure path,
/// and the complete risk note stay on one second-level page.
class AutoReviewSettingsPage extends StatefulWidget {
  const AutoReviewSettingsPage({required this.runtime, super.key});
  final RuntimeController runtime;

  @override
  State<AutoReviewSettingsPage> createState() => _AutoReviewSettingsPageState();
}

class _AutoReviewSettingsPageState extends State<AutoReviewSettingsPage> {
  late AutoReviewPreference preference;

  @override
  void initState() {
    super.initState();
    preference = AutoReviewPreference(widget.runtime);
    unawaited(preference.start());
  }

  @override
  void didUpdateWidget(AutoReviewSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime) return;
    preference.dispose();
    preference = AutoReviewPreference(widget.runtime);
    unawaited(preference.start());
  }

  @override
  void dispose() {
    preference.dispose();
    super.dispose();
  }

  String get _subtitle => preference.needsReview
      ? '保存结果待核对；请刷新后再操作'
      : preference.failed
      ? '设置暂不可用，请刷新后重试'
      : preference.enabled
      ? '已开启：通过评审的工具调用直接执行，其余仍由你确认'
      : '已关闭：所有需要审批的调用仍由你决定';

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('自动审批'),
    trailing: GlassButton(
      icon: Icons.refresh_rounded,
      label: '刷新自动审批设置',
      onPressed: preference.busy
          ? null
          : () => unawaited(preference.refresh()),
    ),
    body: ListenableBuilder(
      listenable: preference,
      builder: (context, _) => PocketList(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          PocketSection(
            title: '开关',
            children: [
              PocketSwitchRow(
                key: const ValueKey('auto-review-switch'),
                title: const Text('自动审批'),
                subtitle: Text(_subtitle),
                value: preference.enabled,
                onChanged: preference.canChange
                    ? (value) => unawaited(preference.setEnabled(value))
                    : null,
              ),
              if (preference.failed || preference.needsReview)
                PocketRow(
                  key: const ValueKey('auto-review-refresh'),
                  icon: Icons.refresh_rounded,
                  title: '重新核对自动审批',
                  onTap: preference.busy
                      ? null
                      : () => unawaited(preference.refresh()),
                ),
              if (preference.canAdoptCurrent)
                PocketRow(
                  icon: Icons.check_circle_outline_rounded,
                  title: '以当前配置为准',
                  subtitle: '放弃尚未确认的本次修改',
                  onTap: preference.adoptCurrent,
                ),
            ],
          ),
          PocketSection(
            title: '简介',
            divided: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
                child: Text(
                  '自动审批是实验性功能，默认关闭。开启后，工具管线原本要询问你的调用，以及文件写入或编辑请求的沙箱升级，'
                  '会先交给当前会话的模型评审：低风险和已获明确授权的操作直接执行，不再显示审批卡；'
                  '被拒绝、评审失败或超时的调用仍由你确认。\n\n'
                  '每次评审会额外发送一次模型请求并计入用量。模型可能误判，评审通过的操作会以 App 现有的 '
                  'Android 权限执行。Linux 联网、隔离脚本授权和工作流策略签发等原生审批不经过自动审批。\n\n'
                  '本功能只替代标准工具审批的人工决定，不提供桌面的 Full access 权限预设或 Shell 沙箱。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
