// 「添加连接」页：把一台远程 DSH 电脑配到这台手机上。
//
// 页面只做输入与展示：解析链接、取 CA、校验指纹、换取设备令牌、把设备存进本机
// 这几步全部交给 [RemotePairingFlow]，顺序与失败转译也只有它一处实现。配对成功后
// 本页把已保存的 [RemoteDevice] 原样返回给调用方，由调用方刷新设备列表并连接；
// 本页不连接、不读门面，因此失败时只在按钮下方给出原因，不会和连接状态的空态
// 互相覆盖。
//
// 五种入口最终都落到同一条配对流程：
// - 粘贴链接：电脑上整段复制配对链接；
// - 扫码配对：系统相机拍二维码，原生 ZXing 解出文本（[PairingScanner]）；
// - 搜索局域网：UDP 广播发现同网段宿主，直接把宿主回的配对链接交给流程
//   （[RemoteDiscovery]，协议见 `docs/remote-dsh/discovery.md`）；
// - HTTPS 反代：TLS 在反代（公网域名 / Nginx / 内网穿透）处终止时，用系统根证书
//   验证反代出示的公网证书；仍会取回电脑自己的 CA 并核对 instance 指纹，用户必须
//   显式选这个入口，普通入口只提示切换、不静默改变信任模式；
// - 手动地址与令牌（高级）：粘贴完整链接后替换地址，用于 USB adb reverse / 反代。
//
// 发现只在用户切到「搜索局域网」或点「重新搜索」时发起，窗口结束即关闭套接字：
// 页面静置不产生 UDP 流量，也不常驻轮询（60 fps 门禁）。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'flclash/typography.dart';
import 'remote_device_store.dart';
import 'remote_discovery.dart';
import 'remote_pairing.dart';
import 'remote_pairing_flow.dart';
import 'remote_pairing_scan.dart';
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

/// 添加连接页的输入方式。
enum _PairingMode { paste, scan, discover, proxy }

/// 远程配对页。
///
/// [store] 是配对成功后写入本机的存储；[flow] 省略时按 [store] 新建，测试可以
/// 注入一个不发请求的编排器。[deviceLabel] 是上报给电脑的手机显示名。
/// [scanner] 是扫码实现，省略时走 `dsh/runtime` 的相机通道。
/// [discovery] 是局域网发现实现，省略时走真实 UDP；页面负责在销毁时释放它。
class RemotePairingPage extends StatefulWidget {
  const RemotePairingPage({
    super.key,
    required this.store,
    this.flow,
    this.deviceLabel,
    this.scanner,
    this.discovery,
  });

  /// 设备存储；配对成功后由流程写入这里。
  final RemoteDeviceStore store;

  /// 配对编排；省略时按 [store] 新建。
  final RemotePairingFlow? flow;

  /// 上报给电脑的手机显示名；省略时读取系统型号，读不到再用固定文案。
  final String? deviceLabel;

  /// 扫码实现；省略时用 [MethodChannelPairingScanner]。
  final PairingScanner? scanner;

  /// 局域网发现；省略时用 [UdpRemoteDiscovery]。
  final RemoteDiscovery? discovery;

  @override
  State<RemotePairingPage> createState() => _RemotePairingPageState();
}

class _RemotePairingPageState extends State<RemotePairingPage> {
  /// 粘贴配对链接的输入框；进入页面不自动聚焦，键盘由用户点输入框才出现。
  final _link = TextEditingController();

  /// 手动地址覆盖用的两个输入框（高级入口）。
  final _manualAddress = TextEditingController();
  final _manualLink = TextEditingController();

  /// 配对编排：注入的优先，否则按 [RemotePairingPage.store] 新建。
  late final RemotePairingFlow _flow =
      widget.flow ?? RemotePairingFlow(store: widget.store);

  /// 扫码实现：注入的优先，否则走原生相机通道。
  late final PairingScanner _scanner =
      widget.scanner ?? MethodChannelPairingScanner();

  /// 局域网发现：注入的优先，否则走真实 UDP；dispose 时由本页释放。
  late final RemoteDiscovery _discovery =
      widget.discovery ?? UdpRemoteDiscovery();

  /// 当前输入方式；默认粘贴链接（对没有相机/广播被拦的网络也一直可用）。
  _PairingMode _mode = _PairingMode.paste;

  /// 是否正在配对；为 true 时按钮与输入框都停下，不能重复提交。
  bool _busy = false;

  /// 是否正在扫码（相机在前台）；为 true 时配对与再次扫码都不可点。
  bool _scanning = false;

  /// 是否正在搜索局域网；为 true 时发现按钮显示进度、不能重复触发。
  bool _discovering = false;

  /// 最近一次失败的中文原因；输入变化或重新提交时清空。
  String? _error;

  /// 普通入口收到「看起来是 HTTPS 反代」的链接时置位：只在状态区给出切换按钮，
  /// 绝不因此改信任模式（模式只能由用户切到「HTTPS 反代」入口来表达）。
  bool _suggestProxy = false;

  /// 最近一次发现结果；null 表示还没搜过。空列表是「搜过但没有找到」。
  List<RemoteDiscoveredHost>? _discovered;

  /// 发现失败的中文原因（与配对失败分开，避免和配对提示互相覆盖）。
  String? _discoveryError;

  /// 发现结果的代次：重新搜索或页面销毁后，旧结果不再回写 UI。
  int _discoveryGeneration = 0;

  @override
  void dispose() {
    _discoveryGeneration += 1;
    _discovery.dispose();
    _link.dispose();
    _manualAddress.dispose();
    _manualLink.dispose();
    super.dispose();
  }

  /// 输入非空且没有配对或扫码在进行时才允许提交。
  bool get _canSubmit => !_busy && !_scanning && _link.text.trim().isNotEmpty;

  /// 没有配对在进行时才允许扫码。
  bool get _canScan => !_busy && !_scanning;

  /// 没有配对在进行时才允许发起发现。
  bool get _canDiscover => !_busy && !_discovering;

  void _onLinkChanged(String _) {
    // 只重算按钮可用性并清掉上一次的失败：输入已经变了，旧原因不再对应当前内容。
    setState(() {
      _error = null;
      _suggestProxy = false;
    });
  }

  /// 切换输入方式；第一次切到「搜索局域网」时才发起发现（懒加载）。
  void _selectMode(_PairingMode mode) {
    if (_mode == mode) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _mode = mode;
      _error = null;
      _suggestProxy = false;
    });
    if (mode == _PairingMode.discover && _discovered == null && !_discovering) {
      unawaited(_search());
    }
  }

  /// 广播搜索同网段的电脑；窗口结束后把结果回写 UI。
  Future<void> _search() async {
    if (!_canDiscover) return;
    FocusScope.of(context).unfocus();
    final generation = ++_discoveryGeneration;
    setState(() {
      _discovering = true;
      _discoveryError = null;
      _error = null;
    });
    try {
      final hosts = await _discovery.discover();
      if (!mounted || generation != _discoveryGeneration) return;
      setState(() => _discovered = hosts);
    } on RemoteDiscoveryFailure catch (failure) {
      if (!mounted || generation != _discoveryGeneration) return;
      setState(() => _discoveryError = failure.message);
    } on Object catch (failure) {
      if (!mounted || generation != _discoveryGeneration) return;
      setState(() => _discoveryError = '搜索局域网失败：$failure。请改用扫码或粘贴配对链接。');
    } finally {
      if (mounted && generation == _discoveryGeneration) {
        setState(() => _discovering = false);
      }
    }
  }

  /// 打开相机扫码，把扫到的配对链接填进输入框；配对仍由用户点「连接」触发。
  ///
  /// 扫码取消不是失败（输入框与提示都不变）；扫到的内容不是配对链接时只给可读
  /// 说明，不覆盖已有输入。输入框里已有一条不同的链接时先确认再覆盖。
  Future<void> _scan() async {
    if (!_canScan) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final text = await _scanner.scan();
      if (!mounted) return;
      // 相机已经返回：进度到此为止；后面是校验与覆盖确认，不再显示扫码中的转圈。
      if (_scanning) setState(() => _scanning = false);
      final link = text.trim();
      try {
        PairingDescriptor.parse(link);
      } on FormatException catch (failure) {
        setState(() => _error = '扫到的内容不是配对链接：${failure.message}');
        return;
      }
      final current = _link.text.trim();
      if (current.isNotEmpty && current != link) {
        final replace = await _confirmReplace();
        if (!mounted || !replace) return;
      }
      if (!mounted) return;
      final proxyLink = looksLikeHttpsProxyPairingLink(link);
      setState(() {
        _link.text = link;
        // 扫到链接后回到粘贴视图：用户能看到链接并直接点「连接」。
        _mode = _PairingMode.paste;
        _error = null;
        // 反代链接只提示切换入口，不静默改信任模式（见「HTTPS 反代」模式）。
        _suggestProxy = proxyLink;
      });
      // 光标放到末尾：整条链接保持可见，用户可以直接点「连接」。
      _link.selection = TextSelection.collapsed(offset: _link.text.length);
    } on PairingScanCancelled {
      // 用户取消扫码：保持输入框与提示原样，不当作失败。
    } on PairingScanFailure catch (failure) {
      if (!mounted) return;
      setState(() => _error = failure.message);
    } on Object catch (failure) {
      if (!mounted) return;
      setState(() => _error = '扫码失败：$failure');
    } finally {
      if (mounted && _scanning) setState(() => _scanning = false);
    }
  }

  /// 输入框已有另一条链接时确认是否用扫码结果替换。
  Future<bool> _confirmReplace() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('替换已填写的链接'),
        content: const Text('输入框里已经有一条配对链接。用这次扫码的结果替换它吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('remote-pairing-scan-replace'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('替换'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// 用一条配对链接走既有配对流程；成功时带着设备记录出栈。
  ///
  /// [systemTrust] 由入口显式决定：普通入口为 false（固定宿主 CA）；「HTTPS 反代」
  /// 入口为 true（系统根证书验证反代公网证书）。普通入口拿到反代形态的链接时只提示
  /// 切换入口，绝不自动改用系统信任。
  Future<void> _pairLink(String link, {bool systemTrust = false}) async {
    if (_busy) return;
    if (!systemTrust && looksLikeHttpsProxyPairingLink(link)) {
      FocusScope.of(context).unfocus();
      setState(() {
        _suggestProxy = true;
        _error = null;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _suggestProxy = false;
    });
    try {
      final device = await _flow.pair(
        link,
        deviceLabel: widget.deviceLabel ?? await resolvePairingDeviceLabel(),
        systemTrust: systemTrust,
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

  Future<void> _submit() async {
    if (!_canSubmit) return;
    await _pairLink(_link.text, systemTrust: _mode == _PairingMode.proxy);
  }

  /// 从普通入口切到「HTTPS 反代」入口；输入框内容原样保留，用户再点连接。
  void _switchToProxy() {
    if (_mode == _PairingMode.proxy || _busy || _scanning) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _mode = _PairingMode.proxy;
      _suggestProxy = false;
      _error = null;
    });
  }

  /// 连接一台发现到的电脑：直接用宿主应答里的配对链接（与扫码/粘贴同一条）。
  Future<void> _pairDiscovered(RemoteDiscoveredHost host) async {
    final link = host.pairLink;
    if (link == null || _busy) return;
    await _pairLink(link);
  }

  /// 手动地址（高级）：完整链接里的 instanceId/token 不变，只替换连接地址。
  ///
  /// 首次配对仍然需要链接里带 CA 指纹（instanceId）：它才是信任锚。只有地址没有
  /// instanceId 时无法验证电脑证书，会明确提示改粘贴完整链接，不做 TOFU 放行。
  Future<void> _submitManual() async {
    if (_busy) return;
    final raw = _manualLink.text.trim();
    final address = _manualAddress.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请粘贴电脑上的完整配对链接（含 #instance=…&token=…）。');
      return;
    }
    final PairingDescriptor descriptor;
    try {
      descriptor = PairingDescriptor.parse(raw);
    } on FormatException catch (failure) {
      setState(() => _error = _manualTokenHint(raw) ?? failure.message);
      return;
    }
    var link = raw;
    if (address.isNotEmpty) {
      // 地址只决定走哪条网络路径（USB adb reverse 用 127.0.0.1:4777，反代填自己
      // 的域名与端口）；CA 指纹与令牌仍来自粘贴的链接，再交给既有解析复核。
      final composed =
          'wss://$address#instance=${descriptor.instanceId}'
          '&token=${descriptor.token}';
      try {
        final rewritten = PairingDescriptor.parse(composed);
        link =
            'wss://${rewritten.host}:${rewritten.port}'
            '#instance=${rewritten.instanceId}&token=${rewritten.token}';
      } on FormatException catch (failure) {
        setState(() => _error = '电脑地址不合法：${failure.message}');
        return;
      }
    }
    await _pairLink(link);
  }

  /// 只填了 43 字符令牌时给出可操作说明；其它非法输入返回 null 由解析错误说明。
  String? _manualTokenHint(String raw) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(raw)) return null;
    return '只填配对令牌不够：首次配对必须带 CA 指纹（instanceId）才能验证电脑证书。'
        '请从电脑复制完整配对链接（wss://… #instance=…&token=…），或改用扫码。';
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
              '连接电脑',
              style: AppTextStyle.title3.of(context, emphasized: true),
            ),
            const SizedBox(height: 8),
            Text(
              '四种方式都会把电脑的配对链接交给同一条配对流程：扫码与自动发现最省事，'
              '链接也可以从电脑上整段复制粘贴。前三类（粘贴 / 扫码 / 局域网）是直连电脑'
              '自己的 TLS；「HTTPS 反代」用于 TLS 在公网域名/Nginx/内网穿透处终止的情况。'
              '配对等于完全信任，请只配对你自己的电脑。',
              style: hint,
            ),
            const SizedBox(height: 16),
            SegmentedControl<_PairingMode>(
              key: const ValueKey('remote-pairing-modes'),
              segments: const [
                (_PairingMode.paste, '粘贴链接'),
                (_PairingMode.scan, '扫码配对'),
                (_PairingMode.discover, '搜索局域网'),
                (_PairingMode.proxy, 'HTTPS 反代'),
              ],
              value: _mode,
              onChanged: _busy || _scanning ? null : _selectMode,
            ),
            const SizedBox(height: 18),
            ..._modeContent(context),
            _statusSlot(context, hint),
            const SizedBox(height: 18),
            PocketDisclosure(
              key: const ValueKey('remote-pairing-manual'),
              title: '手动地址与令牌（高级）',
              child: _manualPanel(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前输入方式的正文。
  List<Widget> _modeContent(BuildContext context) {
    switch (_mode) {
      case _PairingMode.paste:
        return [
          _linkField(context),
          const SizedBox(height: 18),
          PocketButton(
            key: const ValueKey('remote-pairing-submit'),
            onPressed: _canSubmit ? _submit : null,
            child: _submitLabel(context),
          ),
          const SizedBox(height: 12),
          _trustNote(context),
        ];
      case _PairingMode.scan:
        return [
          PocketButton.tonal(
            key: const ValueKey('remote-pairing-scan'),
            onPressed: _canScan ? _scan : null,
            child: _scanLabel(context),
          ),
          const SizedBox(height: 12),
          _linkField(context),
          const SizedBox(height: 18),
          PocketButton(
            key: const ValueKey('remote-pairing-submit'),
            onPressed: _canSubmit ? _submit : null,
            child: _submitLabel(context),
          ),
          const SizedBox(height: 12),
          _trustNote(context),
        ];
      case _PairingMode.discover:
        return _discoveryContent(context);
      case _PairingMode.proxy:
        return [
          _proxyIntro(context),
          const SizedBox(height: 12),
          _linkField(context, proxy: true),
          const SizedBox(height: 18),
          PocketButton(
            key: const ValueKey('remote-pairing-proxy-submit'),
            onPressed: _canSubmit ? _submit : null,
            child: _submitLabel(context),
          ),
          const SizedBox(height: 12),
          _proxyTrustNote(context),
        ];
    }
  }

  Widget _linkField(BuildContext context, {bool proxy = false}) => TextField(
    key: const ValueKey('remote-pairing-link'),
    controller: _link,
    enabled: !_busy && !_scanning,
    minLines: 3,
    maxLines: 5,
    keyboardType: TextInputType.multiline,
    textInputAction: TextInputAction.newline,
    autocorrect: false,
    enableSuggestions: false,
    style: AppTextStyle.body.of(context),
    onChanged: _onLinkChanged,
    // Flutter 默认的触摸行为会在点按输入框之外时保留焦点；这里与其它编辑页一致，
    // 点空白处即收起键盘。
    onTapOutside: (_) => FocusScope.of(context).unfocus(),
    decoration: InputDecoration(
      labelText: '配对链接',
      hintText: proxy
          ? 'wss://dsh.example.com:443#instance=…&token=…'
          : 'wss://192.168.1.10:4777#instance=…&token=…',
      hintMaxLines: 3,
    ),
  );

  /// 「HTTPS 反代」正文：适用场景与信任模式说明。
  Widget _proxyIntro(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = AppTextStyle.footnote
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    return Text(
      '适用于「公网域名 + 反向代理 / Nginx / 内网穿透，TLS 在反代处终止」：'
      '反代把 /ca.cer、/pair 与 /app（含 WebSocket）转发到你电脑上的远程 DSH。'
      '这个模式用手机的系统根证书验证反代出示的公网证书，不再固定电脑自己的 CA；'
      '配对时仍会取回电脑的 CA 证书并核对链接里的指纹，所以反代后端必须是你自己的电脑。',
      style: hint,
    );
  }

  /// 「HTTPS 反代」的信任说明：模式差异 + 只用于可信反代。
  Widget _proxyTrustNote(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = AppTextStyle.footnote
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.gpp_maybe_outlined, size: 18, color: colors.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '只在你自己控制的反代上使用：反代在终止 TLS 后能看到请求明文，'
            '请确认域名与证书都归你所有。局域网直连、组网（Tailscale/WireGuard）或 '
            'TCP 直通反代请改用「粘贴链接」，不要在这里关掉既有的证书固定。',
            style: hint,
          ),
        ),
      ],
    );
  }

  Widget _trustNote(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = AppTextStyle.footnote
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    return Row(
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
    );
  }

  /// 「搜索局域网」正文：懒加载，只有用户切到这一页或点重试才发起发现。
  List<Widget> _discoveryContent(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = AppTextStyle.footnote
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    if (_discovering) {
      return [
        Row(
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text('正在搜索局域网里的电脑…（约 2.5 秒）', style: hint)),
          ],
        ),
        const SizedBox(height: 12),
        Text('只在这次搜索期间收发 UDP，窗口结束即停止。', style: hint),
      ];
    }
    final error = _discoveryError;
    if (error != null) {
      return [
        Text(error, style: hint.copyWith(color: colors.error)),
        const SizedBox(height: 14),
        _retrySearchButton(
          context,
          const ValueKey('remote-pairing-search-retry'),
        ),
      ];
    }
    final hosts = _discovered;
    if (hosts == null) {
      return [
        Text(
          '电脑与手机在同一 Wi-Fi 或同一网段时，可以自动找到正在打开配对窗口的电脑。'
          '需要电脑上的远程 DSH 已启动，且允许 UDP 4778 入站。',
          style: hint,
        ),
        const SizedBox(height: 14),
        PocketButton(
          key: const ValueKey('remote-pairing-search'),
          onPressed: _canDiscover ? _search : null,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_find_rounded, size: 18),
              SizedBox(width: 6),
              Text('开始搜索'),
            ],
          ),
        ),
      ];
    }
    if (hosts.isEmpty) {
      return [
        Text(
          '没有发现同网段的电脑。请确认：手机和电脑在同一 Wi-Fi/网段；电脑上的远程 DSH '
          '正在运行并已打开配对窗口；电脑防火墙允许 UDP 4778 入站；路由器没有开启客户端隔离。',
          style: hint,
        ),
        const SizedBox(height: 10),
        Text('也可以改用「扫码配对」或「粘贴链接」。', style: hint),
        const SizedBox(height: 14),
        _retrySearchButton(
          context,
          const ValueKey('remote-pairing-search-retry'),
        ),
      ];
    }
    return [
      Text(
        '发现 ${hosts.length} 台电脑。配对窗口打开的可以直接连接；'
        '窗口关闭的需要先在电脑上重新打开配对窗口。',
        style: hint,
      ),
      const SizedBox(height: 14),
      for (final host in hosts) _discoveredHost(context, host),
      const SizedBox(height: 4),
      _retrySearchButton(
        context,
        const ValueKey('remote-pairing-search-retry'),
      ),
    ];
  }

  Widget _retrySearchButton(BuildContext context, Key key) =>
      PocketButton.tonal(
        key: key,
        onPressed: _canDiscover ? _search : null,
        child: const Text('重新搜索'),
      );

  /// 一台发现到的电脑：名称、地址、配对窗口状态与动作。
  Widget _discoveredHost(BuildContext context, RemoteDiscoveredHost host) {
    final colors = Theme.of(context).colorScheme;
    final hint = AppTextStyle.footnote
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    final instance = host.instanceId.substring(0, 8);
    return Padding(
      key: ValueKey('remote-pairing-host-${host.instanceId}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: PocketCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.computer_rounded,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    host.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.body.of(context, emphasized: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('${host.address} · 指纹 $instance', style: hint),
            const SizedBox(height: 6),
            if (host.pairingOpen) ...[
              Text('配对窗口已打开', style: hint),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: ValueKey(
                    'remote-pairing-discovered-connect-${host.instanceId}',
                  ),
                  onPressed: _busy
                      ? null
                      : () => unawaited(_pairDiscovered(host)),
                  child: const Text('连接'),
                ),
              ),
            ] else ...[
              Text('配对窗口未打开。请在电脑上重新打开配对窗口后重试。', style: hint),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: ValueKey(
                    'remote-pairing-discovered-retry-${host.instanceId}',
                  ),
                  onPressed: _canDiscover ? () => unawaited(_search()) : null,
                  child: const Text('重新搜索'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 手动地址（高级）：完整链接 + 可选地址覆盖；不复制任何配对校验逻辑。
  Widget _manualPanel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = AppTextStyle.footnote
        .of(context)
        .copyWith(color: colors.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '用于 USB 调试（adb reverse）或反代：先把电脑上的完整配对链接粘贴到「链接」，'
          '再把地址改成本机可达的 host:port。地址只改变连接路径，'
          'CA 指纹仍以链接里的 instanceId 为准。',
          style: hint,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('remote-pairing-manual-address'),
          controller: _manualAddress,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          style: AppTextStyle.body.of(context),
          decoration: const InputDecoration(
            labelText: '电脑地址',
            hintText: '127.0.0.1:4777（留空则用链接里的地址）',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('remote-pairing-manual-link'),
          controller: _manualLink,
          enabled: !_busy,
          minLines: 2,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          style: AppTextStyle.body.of(context),
          decoration: const InputDecoration(
            labelText: '配对链接',
            hintText: 'wss://电脑地址:端口#instance=…&token=…',
            hintMaxLines: 3,
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('remote-pairing-manual-copy-link'),
            onPressed: _busy
                ? null
                : () => setState(() {
                    _manualLink.text = _link.text;
                    _manualLink.selection = TextSelection.collapsed(
                      offset: _manualLink.text.length,
                    );
                  }),
            child: const Text('用上面填写的链接'),
          ),
        ),
        const SizedBox(height: 6),
        PocketButton(
          key: const ValueKey('remote-pairing-manual-submit'),
          onPressed: _busy ? null : _submitManual,
          child: const Text('用这个地址配对'),
        ),
      ],
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

  /// 按钮内容：扫码中给出进度与文案，其余显示「扫码配对」。
  Widget _scanLabel(BuildContext context) {
    if (!_scanning) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.qr_code_scanner_rounded, size: 18),
          SizedBox(width: 6),
          Text('扫码配对'),
        ],
      );
    }
    // 按钮在扫码中不可点，前景色因此是禁用色；圈与文案取同一个颜色。
    final foreground = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: .38);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '正在打开相机',
          child: SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          ),
        ),
        const SizedBox(width: 10),
        const Text('正在扫码…'),
      ],
    );
  }

  /// 按钮下方的原因区：高度先占住，提示与错误出现或消失时按钮都不跳动。
  ///
  /// 扫码/搜索中说明接下来会发生什么；没有错误且输入为空时说明按钮为什么不可用；
  /// 有错误时原样显示异常自带的中文。这里刻意不用 SnackBar：失败原因要与这次提交
  /// 的输入留在同一处。
  ///
  /// 普通入口收到反代形态的链接时额外给一个「改用 HTTPS 反代」按钮：模式只能由
  /// 用户点这个按钮显式切换，页面不会代用户改信任方式。
  Widget _statusSlot(BuildContext context, TextStyle hint) {
    final colors = Theme.of(context).colorScheme;
    final error = _error;
    final suggestProxy = _suggestProxy && _mode != _PairingMode.proxy;
    final String? message;
    if (error != null) {
      message = error;
    } else if (_scanning) {
      message = '正在打开相机：把电脑上的二维码放进取景框，识别后自动填入链接。';
    } else if (_discovering) {
      message = null;
    } else if (suggestProxy) {
      message =
          '这条链接指向 HTTPS 反代（域名证书由反代出示）。'
          '要连它，请点下面的按钮改用「HTTPS 反代」入口；普通入口不会改变证书信任方式。';
    } else if (_mode != _PairingMode.discover &&
        !_busy &&
        _link.text.trim().isEmpty) {
      message = _mode == _PairingMode.proxy
          ? '先粘贴电脑日志里的 HTTPS 反代配对链接，再点「连接」。'
          : '先扫码或粘贴电脑上的配对链接，再点「连接」。';
    } else {
      message = null;
    }
    // 两行脚注的高度：短提示占不到两行，空出来的部分让按钮位置保持不变。
    final reserved =
        MediaQuery.textScalerOf(context).scale(AppTextStyle.footnote.leading) *
            2 +
        10;
    final children = <Widget>[
      if (message != null)
        Semantics(
          liveRegion: error != null,
          child: Text(
            message,
            style: hint.copyWith(
              color: error == null ? colors.onSurfaceVariant : colors.error,
            ),
          ),
        ),
      if (suggestProxy)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('remote-pairing-switch-proxy'),
            onPressed: _busy || _scanning ? null : _switchToProxy,
            child: const Text('改用「HTTPS 反代」连接'),
          ),
        ),
    ];
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: reserved),
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: children.isEmpty
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
      ),
    );
  }
}
