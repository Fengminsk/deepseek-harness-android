import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

class NotificationSettingsPage extends StatelessWidget {
  const NotificationSettingsPage({super.key});
  @override
  Widget build(BuildContext context) => const PocketScaffold(
    title: Text('授权通知'),
    body: PocketList(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        NotificationAccessCard(),
        PocketSection(
          title: '通知中的操作',
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(22, 0, 22, 18),
              child: Text(
                '授权通知提供“允许一次”和“拒绝”。'
                '适合直接填写的提问可以在通知中回复，复杂问题会打开 App。'
                '\n\nApp、通知和 Web 处理同一个 DSH 请求；'
                '请求已经完成或撤回时，旧通知不能再次作答。'
                '通知权限关闭时，仍可在 App 的“授权与提问”页面处理。',
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class NotificationAccessCard extends StatefulWidget {
  const NotificationAccessCard({super.key});
  @override
  State<NotificationAccessCard> createState() => _NotificationAccessCardState();
}

class _NotificationAccessCardState extends State<NotificationAccessCard>
    with WidgetsBindingObserver {
  Json? status;
  String? error;
  bool busy = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(read());
  }

  Future<void> read() async {
    final current = ++generation;
    try {
      final response = await RuntimeController.channel.invokeMethod<String>(
        'notifications.status',
      );
      if (response == null) throw StateError('未收到通知权限状态');
      final value = jsonDecode(response) as Json;
      if (mounted && current == generation) {
        setState(() {
          status = value;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted && current == generation) {
        setState(() => error = '无法读取系统通知状态：$failure');
      }
    }
  }

  Future<void> change(String method) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await RuntimeController.channel.invokeMethod<void>(method);
      await read();
    } catch (failure) {
      if (mounted) {
        setState(() => error = '无法打开通知授权或设置：$failure');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(read());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = status?['enabled'] == true;
    return PocketSection(
      title: '系统通知',
      children: [
        PocketRow(
          icon: enabled
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          title: error != null
              ? '通知状态暂不可用'
              : status == null
              ? '正在读取通知状态'
              : enabled
              ? '授权通知已开启'
              : '授权通知未开启',
          subtitle: error != null
              ? '暂时无法核对系统通知状态；你仍可在 App 内处理请求。'
              : enabled
              ? '请求可以通过系统通知提醒你。'
              : switch (status?['reason']) {
                  'permission' => '尚未允许系统通知；你仍可在 App 内处理请求。',
                  'app-disabled' => '系统已关闭此 App 的通知，请在系统设置中开启。',
                  'channel-disabled' => '“Agent 请求”通知类别已关闭，请在系统设置中开启。',
                  _ => '你仍可在 App 内处理授权与提问。',
                },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error != null) ...[
                SelectableText(error!),
                const SizedBox(height: 8),
                PocketButton.tonal(
                  onPressed: busy ? null : read,
                  child: const Text('重新读取通知状态'),
                ),
              ],
              if (status?['reason'] == 'permission')
                PocketButton(
                  onPressed: busy
                      ? null
                      : () => change('notifications.request'),
                  child: const Text('允许系统通知'),
                ),
              PocketButton.tonal(
                onPressed: busy ? null : () => change('notifications.settings'),
                child: const Text('打开系统通知设置'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
