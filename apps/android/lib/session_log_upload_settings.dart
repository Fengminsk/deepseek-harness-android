import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'configuration_boolean_preference.dart';
import 'runtime.dart';
import 'ui.dart';

/// Controls the original session-log-deepseek Host setting when it is served.
class SessionLogUploadSettingsRow extends StatefulWidget {
  const SessionLogUploadSettingsRow({required this.runtime, super.key});

  final RuntimeController runtime;

  @override
  State<SessionLogUploadSettingsRow> createState() =>
      _SessionLogUploadSettingsRowState();
}

class _SessionLogUploadSettingsRowState
    extends State<SessionLogUploadSettingsRow> {
  late ConfigurationBooleanPreference preference;

  @override
  void initState() {
    super.initState();
    preference = _newPreference();
    unawaited(preference.start());
  }

  ConfigurationBooleanPreference _newPreference() =>
      ConfigurationBooleanPreference(
        widget.runtime,
        namespace: 'session-log-deepseek',
      );

  @override
  void didUpdateWidget(SessionLogUploadSettingsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.runtime, widget.runtime)) return;
    preference.dispose();
    preference = _newPreference();
    unawaited(preference.start());
  }

  @override
  void dispose() {
    preference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preference,
    builder: (context, _) => Column(
      children: [
        PocketSwitchRow(
          key: const ValueKey('session-log-upload-switch'),
          title: const Text('上传 Session Log'),
          subtitle: Text(
            preference.needsReview
                ? '保存结果待核对；刷新后选择当前配置'
                : preference.failed
                ? '设置暂不可用，请刷新后重试'
                : '使用 DeepSeek 官方模型 API 时上传会话日志',
          ),
          value: preference.value,
          onChanged: preference.canChange
              ? (next) => unawaited(preference.setValue(next))
              : null,
        ),
        if (preference.failed || preference.needsReview)
          PocketRow(
            key: const ValueKey('session-log-upload-review'),
            icon: Icons.refresh_rounded,
            title: '重新核对会话日志上传设置',
            onTap: preference.busy
                ? null
                : () => unawaited(preference.refresh()),
          ),
        if (preference.canAdoptCurrent)
          PocketRow(
            key: const ValueKey('session-log-upload-adopt'),
            icon: Icons.check_circle_outline_rounded,
            title: '以当前配置为准',
            subtitle: '放弃尚未确认的本次修改',
            onTap: preference.adoptCurrent,
          ),
      ],
    ),
  );
}
