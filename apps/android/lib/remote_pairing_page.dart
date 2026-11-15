// 远程配对页：粘贴电脑上的配对链接，把一台电脑配到这台手机上。
//
// 页面只做输入与展示：解析链接、取 CA、校验指纹、换取设备令牌、把设备存进本机
// 这几步全部交给 [RemotePairingFlow]，顺序与失败转译也只有它一处实现。配对成功后
// 本页把已保存的 [RemoteDevice] 原样返回给调用方，由调用方刷新设备列表并连接；
// 本页不连接、不读门面，因此失败时只在按钮下方给出原因，不会和连接状态的空态
// 互相覆盖。

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'flclash/typography.dart';
import 'remote_device_store.dart';
import 'remote_pairing.dart';
import 'remote_pairing_flow.dart';
import 'ui.dart';

/// 读取不到系统型号时上报给电脑的手机显示名。
///
/// 它只用于电脑的设备列表与排障（`apps/remote-host/src/devices.ts` 只要求
/// 1–120 个非控制字符），不参与校验。
const String remotePairingDeviceLabel = 'Android 手机';

/// 上报给电脑的手机显示名：优先用系统型号，读不到时退回 [remotePairingDeviceLabel]。
Future<String> resolvePairingDeviceLabel() async {
  try {
    final raw = await const MethodChannel('dsh/runtime')
        .invokeMethod<String>('app.metadata');
    if (raw != null) {
      final metadata = jsonDecode(raw);
      if (metadata is Map && metadata['model'] is String) {
        final model = (metadata['model'] as String).trim();
        if (model.isNotEmpty) return model;
      }
    }
  } on Object {
    // 型号只是显示名：通道不可用时用固定文案，不阻断配对。
  }
  return remotePairingDeviceLabel;
}

/// 远程配对页。
///
/// [store] 是配对成功后写入本机的存储；[flow] 省略时按 [store] 新建，测试可以
/// 注入一个不发请求的编排器。[deviceLabel] 是上报给电脑的手机显示名。
class RemotePairingPage extends StatefulWidget {
  const RemotePairingPage({
    super.key,
    required this.store,
    this.flow,
    this.deviceLabel,
  });

  /// 设备存储；配对成功后由流程写入这里。
  final RemoteDeviceStore store;

  /// 配对编排；省略时按 [store] 新建。
  final RemotePairingFlow? flow;

  /// 上报给电脑的手机显示名；省略时读取系统型号，读不到再用固定文案。
  final String? deviceLabel;

  @override
  State<RemotePairingPage> createState() => _RemotePairingPageState();
}

class _RemotePairingPageState extends State<RemotePairingPage> {
  /// 粘贴配对链接的输入框；进入页面不自动聚焦，键盘由用户点输入框才出现。
  final _link = TextEditingController();

  /// 配对编排：注入的优先，否则按 [RemotePairingPage.store] 新建。
  late final RemotePairingFlow _flow =
      widget.flow ?? RemotePairingFlow(store: widget.store);

  /// 是否正在配对；为 true 时按钮与输入框都停下，不能重复提交。
  bool _busy = false;

  /// 最近一次失败的中文原因；输入变化或重新提交时清空。
  String? _error;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  /// 输入非空且没有配对在进行时才允许提交。
  bool get _canSubmit => !_busy && _link.text.trim().isNotEmpty;

  void _onLinkChanged(String _) {
    // 只重算按钮可用性并清掉上一次的失败：输入已经变了，旧原因不再对应当前内容。
    setState(() => _error = null);
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    // 收起键盘：进度与结果都在按钮下方，不需要一直占着输入法。
    FocusScope.of(context).unfocus();
    final link = _link.text;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final device = await _flow.pair(
        link,
        deviceLabel: widget.deviceLabel ?? await resolvePairingDeviceLabel(),
      );
      if (!mounted) return;
      // 令牌已经写进本机密钥库：把设备交回调用方，由它刷新列表并连接。
      Navigator.of(context).pop(device);
    } on Object catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageOf(failure);
      });
    }
  }

  /// 失败原因：配对与存储的异常都自带可直接展示的中文，其余按原样给出。
  String _messageOf(Object failure) {
    if (failure is RemotePairingFailure) return failure.message;
    if (failure is RemoteDeviceStoreException) return failure.message;
    if (failure is FormatException) return failure.message;
    return '$failure';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = AppTextStyle.footnote
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    return PocketScaffold(
      title: const Text('添加连接'),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: PocketList(
          key: const ValueKey('remote-pairing-list'),
          children: [
            Text(
              '粘贴电脑上的配对链接',
              style: AppTextStyle.title3.of(context, emphasized: true),
            ),
            const SizedBox(height: 8),
            Text(
              '在电脑上打开远程 DSH 的配对链接并整段复制。链接形如 '
              'wss://电脑地址:端口#instance=…&token=…，只在本机使用，配对后即失效。',
              style: hint,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('remote-pairing-link'),
              controller: _link,
              enabled: !_busy,
              minLines: 3,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              autocorrect: false,
              enableSuggestions: false,
              style: AppTextStyle.body.of(context),
              onChanged: _onLinkChanged,
              // Flutter 默认的触摸行为会在点按输入框之外时保留焦点；这里与
              // 其它编辑页一致，点空白处即收起键盘。
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
              decoration: const InputDecoration(
                hintText: 'wss://192.168.1.10:4777#instance=…&token=…',
                hintMaxLines: 3,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.gpp_maybe_outlined,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '配对等于完全信任：配对后这台手机可以读取、修改并运行那台电脑上的内容。'
                    '请只配对你自己信任的电脑。',
                    style: hint,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            PocketButton(
              key: const ValueKey('remote-pairing-submit'),
              onPressed: _canSubmit ? _submit : null,
              child: _submitLabel(context),
            ),
            _statusSlot(context),
          ],
        ),
      ),
    );
  }

  /// 按钮内容：配对中给出进度与文案，其余显示「连接」。
  Widget _submitLabel(BuildContext context) {
    if (!_busy) return const Text('连接');
    // 按钮在配对中不可点，前景色因此是禁用色；圈与文案取同一个颜色。
    final foreground = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: .38);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '正在与电脑配对',
          child: SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          ),
        ),
        const SizedBox(width: 10),
        const Text('正在连接…'),
      ],
    );
  }

  /// 按钮下方的原因区：高度先占住，提示与错误出现或消失时按钮都不跳动。
  ///
  /// 没有错误且输入为空时说明按钮为什么不可用；有错误时原样显示异常自带的中文。
  /// 这里刻意不用 SnackBar：失败原因要与这次提交的输入留在同一处。
  Widget _statusSlot(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = AppTextStyle.footnote.of(context);
    final error = _error;
    final String? message;
    if (error != null) {
      message = error;
    } else if (!_busy && _link.text.trim().isEmpty) {
      message = '先粘贴电脑上的配对链接，再点「连接」。';
    } else {
      message = null;
    }
    // 两行脚注的高度：短提示占不到两行，空出来的部分让按钮位置保持不变。
    final reserved =
        MediaQuery.textScalerOf(context).scale(AppTextStyle.footnote.leading) *
            2 +
        10;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: reserved),
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: message == null
            ? const SizedBox.shrink()
            : Semantics(
                liveRegion: error != null,
                child: Text(
                  message,
                  style: style.copyWith(
                    color: error == null
                        ? colors.onSurfaceVariant
                        : colors.error,
                  ),
                ),
              ),
      ),
    );
  }
}
