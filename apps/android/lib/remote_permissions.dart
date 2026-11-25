// 远程会话的权限预设接入。
//
// 设计见 `docs/remote-dsh/p5-remaining-design.md` §4.5（D5 已决策：远程宿主启用
// 桌面 `permission` 服务，手机端复用本地权限页的二次确认）：
//
// - 目录：`api.call {namespace:'permissionPresets', method:'catalog'}`，形状见
//   `packages/interaction/permission-presets/src/types.ts` 的 `PermissionCatalog`
//   （`{options:[{value,name,description?}], defaultOptions, defaultPreset}`）；
// - 当前值：`session.projections` 的 `values.permissions.currentValue`（投影的
//   `wire.view` 只给这一个字段，见同文件 `PermissionSelection`）；
// - 写入口：`session.command` 的 `/permission <值>`，与本地
//   `SessionPermissionPage` 完全同一条命令；
// - 能力探测：`runtime.permissions` 的 `presets.available`（远程宿主由
//   `apps/android/runtime/index.mjs` 应答），为 false 时不发目录请求。
//
// 远程宿主返回的 `runtime.permissions` 是桌面形状（`shell.tool == 'desktop-host'`），
// 因此这里不复用本地严格的 `ExecutionPermissionPolicy.parse`；那个解析器校验的是
// Android `android_shell` 形状，只适合本地链路。
//
// 三态：连接未就绪 → [RemotePermissionAvailability.pending]（页面显示「正在连接
// 电脑…」）；就绪但 `presets.available` 为 false（或方法表里没有该探测方法）→
// [RemotePermissionAvailability.unavailable]（页面置灰并写原因）；否则可用。
// 目录读取失败不写「永久不支持」缓存：每次打开弹层都重新读，失败时弹层内给出
// 错误与重试。

library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'composer_commands.dart';
import 'remote_connection.dart';
import 'remote_conversation_source.dart';
import 'runtime.dart';
import 'runtime_transport.dart';

/// 权限预设目录的 typert 命名空间（`api.call` 的 `namespace`）。
const String remotePermissionPresetsNamespace = 'permissionPresets';

/// 读取权限预设目录的 typert 方法（`api.call` 的 `method`）。
const String remotePermissionPresetsCatalogMethod = 'catalog';

/// 读取宿主能力表的门面方法（`runtime.permissions`）。
const String remotePermissionRuntimeMethod = 'runtime.permissions';

/// 切换权限预设的宿主指令名（`packages/interaction/permission-presets` 注册的
/// `/permission`）；远程与本地写的是同一条命令。
const String remotePermissionCommandName = 'permission';

/// 权限预设入口的三态。
enum RemotePermissionAvailability {
  /// 连接未就绪，或探测尚未完成；页面显示「正在连接电脑…」。
  pending,

  /// 电脑启用了权限预设，可以打开预设列表。
  available,

  /// 电脑没有启用权限预设（或方法表里没有探测方法）；入口置灰并写原因。
  unavailable,
}

/// 一个可切换的权限预设，字段与宿主 `PresetOption` 同名同义。
@immutable
class RemotePermissionOption {
  const RemotePermissionOption({
    required this.value,
    required this.name,
    this.description,
  });

  /// 稳定标识：配置里的预设键，进入 `/permission <值>`。
  final String value;

  /// 显示名；宿主没给时与 [value] 相同。
  final String name;

  /// 一行说明；宿主没给时为 null。
  final String? description;
}

/// 电脑上的权限预设目录（`permissionPresets.catalog` 的投影）。
@immutable
class RemotePermissionCatalog {
  const RemotePermissionCatalog({required this.options, this.defaultPreset});

  /// 当前可选的预设，按宿主的贡献顺序。
  final List<RemotePermissionOption> options;

  /// 新会话的默认预设；宿主没给时为 null。
  final String? defaultPreset;

  /// 解析 `permissionPresets.catalog` 的返回。
  ///
  /// 只要求 `options` 是数组：目录是进程级快照，个别项形状不完整时跳过而不是让
  /// 整个入口不可用。`options` 缺失或不是数组时抛 [FormatException]，由调用方
  /// 在弹层里展示错误。
  factory RemotePermissionCatalog.parse(Object? raw) {
    if (raw is! Json) throw const FormatException('权限预设目录格式不正确');
    final rawOptions = raw['options'];
    if (rawOptions is! List) {
      throw const FormatException('权限预设目录缺少 options');
    }
    final options = <RemotePermissionOption>[];
    for (final item in rawOptions) {
      if (item is! Json) continue;
      final value = _nonEmptyString(item['value']);
      if (value == null) continue;
      options.add(
        RemotePermissionOption(
          value: value,
          name: _nonEmptyString(item['name']) ?? value,
          description: _nonEmptyString(item['description']),
        ),
      );
    }
    return RemotePermissionCatalog(
      options: options,
      defaultPreset: _nonEmptyString(raw['defaultPreset']),
    );
  }

  /// 按值查找选项；目录里没有时为 null。
  RemotePermissionOption? optionOf(String? value) {
    if (value == null) return null;
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }
}

/// `runtime.permissions` 里 `presets.available` 的值（远程宽松解析）。
///
/// 与本地 `ExecutionPermissionPolicy.parse` 不同，这里不校验 `shell` /
/// `programmaticTools`：远程宿主是桌面实现，形状本来就与 Android 不同，手机端只需要
/// 这一项判断入口是否可用。
bool remotePermissionPresetsAvailable(Object? response) {
  if (response is! Json) throw const FormatException('权限状态不是对象');
  final presets = response['presets'];
  if (presets is! Json) throw const FormatException('权限状态缺少 presets');
  final available = presets['available'];
  if (available is! bool) {
    throw const FormatException('权限状态缺少 presets.available');
  }
  return available;
}

/// 从 `session.projections` 的返回里读当前权限预设。
///
/// 投影值只在 `values.permissions.currentValue`；会话还没有该投影（权限服务未启用，
/// 或投影尚未注册）时返回 null，与本地权限页「状态尚未就绪」的判据一致。
String? remotePermissionCurrentValue(Object? projections) {
  if (projections is! Json) return null;
  final values = projections['values'];
  if (values is! Json) return null;
  final permissions = values['permissions'];
  if (permissions is! Json) return null;
  return _nonEmptyString(permissions['currentValue']);
}

/// 用远程会话数据源实现 [PermissionCallSurface]。
///
/// 数据源由会话页持有并已连到那台电脑；本类只投影连接阶段与请求入口，不新建
/// 连接、不缓存目录。
class RemotePermissionSurface implements PermissionCallSurface {
  /// 绑定会话数据源。
  ///
  /// @param source 会话页正在使用的远程会话数据源。
  RemotePermissionSurface(this.source);

  /// 被包装的会话数据源。
  final RemoteConversationSource source;

  /// 连接就绪（阶段为 ready）时才发起请求。
  @override
  bool get ready => source.phase == RemoteConnectionPhase.ready;

  /// 恢复会话后再读目录（门面 `session.ensure`，幂等）。
  ///
  /// [id] 必须是本数据源绑定的会话；权限页只操作自己的会话，传错说明页面状态
  /// 不一致，直接报错而不是替另一个会话恢复。
  @override
  Future<Json> ensureSession(String id) {
    if (id != source.sessionId) {
      throw StateError('会话已变化，请返回并重新打开权限设置。');
    }
    return source.ensureSession();
  }

  /// 门面请求透传；失败文本由数据源翻译成可直接展示的中文。
  @override
  Future<dynamic> call(
    String method, [
    Json params = const <String, dynamic>{},
  ]) => source.request(method, params);
}

/// 远程会话页的权限预设状态：能力三态、当前预设与目录加载。
///
/// 由会话页创建并持有：`initState` 里 [start]，`dispose` 里 [dispose]；页面在
/// 重连或手动重试时调用 [refresh]。控制器只读数据源、不持有 UI 状态，弹层的
/// 「读取中 / 失败重试」由 [catalogLoading] / [catalogError] 表达。
class RemotePermissionController extends ChangeNotifier {
  /// 绑定一个远程会话数据源。
  ///
  /// @param source 会话页持有的数据源；本类只读它的阶段、方法表、投影与请求入口。
  RemotePermissionController({required this.source})
    : _surface = RemotePermissionSurface(source),
      _phase = source.phase {
    source.addListener(_sourceChanged);
  }

  /// 会话页正在使用的远程数据源。
  final RemoteConversationSource source;

  final RemotePermissionSurface _surface;

  RemoteConnectionPhase _phase;
  bool _started = false;
  bool _disposed = false;

  int _probeEpoch = 0;
  int _readEpoch = 0;
  int _catalogEpoch = 0;

  RemotePermissionAvailability _availability =
      RemotePermissionAvailability.pending;
  String? _unavailableReason;
  bool _probing = false;

  String? _currentValue;

  RemotePermissionCatalog? _catalog;
  bool _catalogLoading = false;
  String? _catalogError;

  bool _applying = false;

  /// 权限预设入口的三态。
  RemotePermissionAvailability get availability => _availability;

  /// 不可用或暂时无法确认时的原因，可直接展示；可用时为 null。
  String? get unavailableReason => _unavailableReason;

  /// 是否正在做能力探测（页面据此区分「正在连接」与「正在读取权限状态」）。
  bool get probing => _probing;

  /// 入口是否可点：连接就绪且电脑启用了权限预设。
  bool get presetsReady =>
      !_disposed &&
      _availability == RemotePermissionAvailability.available &&
      source.phase == RemoteConnectionPhase.ready;

  /// 当前权限预设的值（`session.projections.values.permissions.currentValue`）。
  String? get currentValue => _currentValue;

  /// 当前预设的显示名；还没有读到投影时为 null。
  String? get currentLabel {
    final value = _currentValue;
    if (value == null) return null;
    return permissionPresetLabel(value, _catalog?.optionOf(value)?.name);
  }

  /// 最近一次成功读取的目录；没读过或读取失败时为 null。
  RemotePermissionCatalog? get catalog => _catalog;

  /// 是否正在读取目录。
  bool get catalogLoading => _catalogLoading;

  /// 目录读取失败的原因；成功后清空。
  String? get catalogError => _catalogError;

  /// 读取一次能力探测与当前预设。重复调用返回同一次开始。
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await refresh();
  }

  /// 重新确认能力与当前值：页面重连、手动重试或切换预设后调用。
  Future<void> refresh() async {
    // 两项只读请求互不依赖；并行后当前预设无需等待能力探测往返。
    await Future.wait<void>([_probe(), _readCurrent()]);
  }

  /// 读取权限预设目录。
  ///
  /// 每次打开弹层都重新读取（目录是进程级快照，可能因为 auto-review 的启用而
  /// 变化）；失败只记录在 [catalogError]，不写「永久不支持」缓存，下一次打开或
  /// 点重试都会再读。
  Future<void> loadCatalog() async {
    if (_disposed) return;
    final epoch = ++_catalogEpoch;
    if (source.phase != RemoteConnectionPhase.ready) {
      _catalogError = '与电脑的连接已断开，正在重连…';
      _publish();
      return;
    }
    _catalogLoading = true;
    _catalogError = null;
    _publish();
    try {
      // The catalog is global to the desktop runtime. Resolving a session here
      // serializes this read behind any work on that session, which can add
      // many seconds without changing the catalog result.
      final raw = await _surface.call(remoteConversationApiCallMethod, {
        'namespace': remotePermissionPresetsNamespace,
        'method': remotePermissionPresetsCatalogMethod,
        'args': const <String, dynamic>{},
      });
      if (_stale(epoch: epoch, token: _catalogEpoch)) return;
      _catalog = RemotePermissionCatalog.parse(raw);
      _catalogError = null;
    } on Object catch (failure) {
      if (_stale(epoch: epoch, token: _catalogEpoch)) return;
      _catalog = null;
      _catalogError = '无法读取权限预设：$failure';
    } finally {
      if (!_stale(epoch: epoch, token: _catalogEpoch)) {
        _catalogLoading = false;
        _publish();
      }
    }
  }

  /// 提交一次预设切换（`session.command` 的 `/permission <值>`）。
  ///
  /// 需要风险确认的预设（`danger-full-access` / `auto`）由调用方在勾选确认后才
  /// 调用本方法；这里不再重复询问。返回 null 表示成功（当前值已刷新），否则返回
  /// 可直接展示的失败原因。
  Future<String?> apply(String value) async {
    if (_disposed) return '会话已关闭，请重新打开。';
    if (source.phase != RemoteConnectionPhase.ready) {
      return '与电脑的连接已断开，请重试。';
    }
    if (_applying) return '正在应用，请稍候。';
    _applying = true;
    _publish();
    try {
      final response = await _surface.call(remoteConversationCommandMethod, {
        'sessionId': source.sessionId,
        'line': '/$remotePermissionCommandName $value',
        'attachmentIds': const <String>[],
      });
      if (_disposed || source.phase != RemoteConnectionPhase.ready) {
        return '连接已变化，操作结果待确认，请重新打开会话。';
      }
      final failure = _commandFailureOf(response);
      if (failure != null) return failure;
      // 写回成功后以宿主的权威投影为准，不用本地乐观值。
      await _readCurrent();
      return null;
    } on RuntimeTransportFailure catch (failure) {
      return '操作未确认，请核对最新的权限预设：${failure.message}';
    } on Object catch (failure) {
      return '操作未确认，请核对最新的权限预设：$failure';
    } finally {
      if (!_disposed) {
        _applying = false;
        _publish();
      }
    }
  }

  /// 连接阶段变化：离开 ready 时收起入口（不显示无法确认的状态），重新 ready 时
  /// 按协议 §7.2 重新探测并以宿主投影为准。
  void _sourceChanged() {
    if (_disposed) return;
    final phase = source.phase;
    if (phase == _phase) return;
    final wasReady = _phase == RemoteConnectionPhase.ready;
    _phase = phase;
    if (phase != RemoteConnectionPhase.ready) {
      _probeEpoch++;
      _readEpoch++;
      _catalogEpoch++;
      _availability = RemotePermissionAvailability.pending;
      _unavailableReason = null;
      _probing = false;
      _currentValue = null;
      _catalog = null;
      _catalogLoading = false;
      _catalogError = null;
      _applying = false;
      _publish();
      return;
    }
    if (!wasReady) {
      _availability = RemotePermissionAvailability.pending;
      _unavailableReason = null;
      _currentValue = null;
      _publish();
      unawaited(refresh());
    }
  }

  Future<void> _probe() async {
    if (_disposed) return;
    final epoch = ++_probeEpoch;
    if (source.phase != RemoteConnectionPhase.ready) {
      _setAvailability(RemotePermissionAvailability.pending, null);
      return;
    }
    _probing = true;
    _publish();
    try {
      if (!source.supports(remotePermissionRuntimeMethod)) {
        if (_stale(epoch: epoch, token: _probeEpoch)) return;
        _setAvailability(
          RemotePermissionAvailability.unavailable,
          '这台电脑未启用权限预设',
        );
        return;
      }
      final raw = await _surface.call(remotePermissionRuntimeMethod);
      if (_stale(epoch: epoch, token: _probeEpoch)) return;
      final available = remotePermissionPresetsAvailable(raw);
      _setAvailability(
        available
            ? RemotePermissionAvailability.available
            : RemotePermissionAvailability.unavailable,
        available ? null : '这台电脑未启用权限预设',
      );
    } on RuntimeTransportFailure catch (failure) {
      if (_stale(epoch: epoch, token: _probeEpoch)) return;
      if (failure.code == 'gateway/unavailable' ||
          failure.code == 'gateway/cancelled') {
        // 断连由阶段机承担：保持 pending，重连后会重新探测。
        _setAvailability(RemotePermissionAvailability.pending, null);
        return;
      }
      _setAvailability(
        RemotePermissionAvailability.unavailable,
        '无法确认权限预设，请稍后重试',
      );
    } on FormatException {
      if (_stale(epoch: epoch, token: _probeEpoch)) return;
      _setAvailability(
        RemotePermissionAvailability.unavailable,
        '无法确认权限预设，请稍后重试',
      );
    } finally {
      if (!_stale(epoch: epoch, token: _probeEpoch)) {
        _probing = false;
        _publish();
      }
    }
  }

  Future<void> _readCurrent() async {
    if (_disposed || source.phase != RemoteConnectionPhase.ready) return;
    final epoch = ++_readEpoch;
    try {
      final projections = await source.readProjections();
      if (_stale(epoch: epoch, token: _readEpoch)) return;
      _currentValue = remotePermissionCurrentValue(projections);
      _publish();
    } on Object {
      // 当前值读不到只影响回显与打勾：入口保持可用（目录仍能读），不把这次失败
      // 升级成页面错误；重试/重连会再读。
      if (_stale(epoch: epoch, token: _readEpoch)) return;
      _currentValue = null;
      _publish();
    }
  }

  /// 读或写是否仍属于同一代连接（期间没有断连/换代）。
  bool _stale({required int epoch, required int token}) {
    if (_disposed || source.phase != RemoteConnectionPhase.ready) return true;
    return epoch != token;
  }

  void _setAvailability(
    RemotePermissionAvailability availability,
    String? reason,
  ) {
    if (_disposed) return;
    _availability = availability;
    _unavailableReason = reason;
    _publish();
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  /// 把 `session.command` 的返回值拍平成失败原因；成功返回 null。
  ///
  /// 与本地权限页同一判据：null 表示电脑没有识别出这条指令；`result.kind` 不是
  /// `success` 说明处理器明确拒绝。
  static String? _commandFailureOf(Object? response) {
    if (response == null) return '电脑没有识别出权限指令，请重新打开会话。';
    if (response is! Json) return '电脑返回的权限结果格式不正确。';
    final payload = response['result'] is Json
        ? response['result'] as Json
        : response;
    if (payload['kind'] == 'success') return null;
    return _nonEmptyString(payload['text']) ?? '电脑没有接受这次权限切换。';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    source.removeListener(_sourceChanged);
    super.dispose();
  }
}

String? _nonEmptyString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
