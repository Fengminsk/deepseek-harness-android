// 远程首页新增能力（电脑文件、电脑设置）的测试替身。
//
// 这些替身不连宿主、不拨号：页面只认 `RemoteDshFilesSource` /
// `RemoteDshSettingsSource` 接口，能力状态与每次应答都由测试配置，因此列表、
// 分页、错误与门控都可以在没有 PC 的情况下验证。

import 'package:dsh_android/remote_dsh_live_source.dart';
import 'package:flutter/services.dart';

/// 一次目录请求的参数记录。
typedef FakeDirectoryCall = ({String path, int offset, String? version});

/// 一次文件请求的参数记录。
typedef FakeFileCall = ({String path, int offset, String? version});

/// 可配置的文件数据源替身。
///
/// [directories] 以相对路径为键，值是同一路径按 `offset` 顺序排列的页；
/// [files] 同理。请求到没有配置的偏移时抛可展示的坏响应，用来暴露页面拼错分页
/// 参数的情况。
class FakeRemoteFilesSource implements RemoteDshFilesSource {
  FakeRemoteFilesSource({
    this.capability = const RemoteDshCapability.available(),
    Map<String, List<RemoteDshDirectoryPage>>? directories,
    Map<String, List<RemoteDshFilePage>>? files,
    this.directoryError,
    this.fileError,
  }) : directories = directories ?? <String, List<RemoteDshDirectoryPage>>{},
       files = files ?? <String, List<RemoteDshFilePage>>{};

  /// 返回给首页/页面入口的能力状态。
  final RemoteDshCapability capability;

  /// 目录应答：路径 → 按偏移排列的页。
  final Map<String, List<RemoteDshDirectoryPage>> directories;

  /// 文件应答：路径 → 按偏移排列的页。
  final Map<String, List<RemoteDshFilePage>> files;

  /// 非 null 时所有目录请求都以它失败；测试可在中途置空再点重试。
  Object? directoryError;

  /// 非 null 时所有文件请求都以它失败。
  Object? fileError;

  /// 按调用顺序记录的目录请求。
  final List<FakeDirectoryCall> directoryCalls = <FakeDirectoryCall>[];

  /// 按调用顺序记录的文件请求。
  final List<FakeFileCall> fileCalls = <FakeFileCall>[];

  @override
  RemoteDshCapability get filesCapability => capability;

  @override
  Future<RemoteDshDirectoryPage> listDirectory({
    required String path,
    int offset = 0,
    String? version,
  }) async {
    directoryCalls.add((path: path, offset: offset, version: version));
    final failure = directoryError;
    if (failure != null) throw failure;
    for (final page in directories[path] ?? const <RemoteDshDirectoryPage>[]) {
      if (page.offset != offset) continue;
      if (version != null && version != page.version) {
        throw PlatformException(
          code: 'workspace-files/changed',
          message: '文件或目录已变化，已显示内容保留。请从头刷新后继续。',
        );
      }
      return page;
    }
    throw PlatformException(
      code: 'workspace-files/not-found',
      message: '路径已不存在，请刷新上级目录。',
    );
  }

  @override
  Future<RemoteDshFilePage> readFile({
    required String path,
    int offset = 0,
    String? version,
  }) async {
    fileCalls.add((path: path, offset: offset, version: version));
    final failure = fileError;
    if (failure != null) throw failure;
    for (final page in files[path] ?? const <RemoteDshFilePage>[]) {
      if (page.offset != offset) continue;
      if (version != null && version != page.version) {
        throw PlatformException(
          code: 'workspace-files/changed',
          message: '文件或目录已变化，已显示内容保留。请从头刷新后继续。',
        );
      }
      return page;
    }
    throw PlatformException(
      code: 'workspace-files/not-found',
      message: '路径已不存在，请刷新上级目录。',
    );
  }
}

/// 构造一条目录页；测试只关心自己用到的字段。
RemoteDshDirectoryPage fakeDirectoryPage({
  String path = '',
  String root = r'C:\work',
  String version = 'dir-v1',
  int offset = 0,
  int? nextOffset,
  bool truncated = false,
  List<RemoteDshFileEntry> entries = const <RemoteDshFileEntry>[],
}) => RemoteDshDirectoryPage(
  root: root,
  path: path,
  version: version,
  offset: offset,
  nextOffset: nextOffset,
  truncated: truncated,
  listedEntries: entries.length,
  entries: entries,
);

/// 构造一条文件页；`nextOffset` 缺省时按 `eof` 推导。
RemoteDshFilePage fakeFilePage({
  required String path,
  required String text,
  String root = r'C:\work',
  String version = 'file-v1',
  int offset = 0,
  int bytes = 14,
  bool eof = true,
  int? nextOffset,
}) => RemoteDshFilePage(
  root: root,
  path: path,
  version: version,
  bytes: bytes,
  offset: offset,
  nextOffset: nextOffset ?? (eof ? bytes : offset + text.length),
  eof: eof,
  text: text,
);

/// 构造一个目录项目。
RemoteDshFileEntry fakeFileEntry(
  String name, {
  String? path,
  RemoteDshFileKind kind = RemoteDshFileKind.file,
  int? modifiedAt,
  int? bytes,
  String? blockedReason,
}) => RemoteDshFileEntry(
  name: name,
  path: path ?? name,
  kind: kind,
  modifiedAt: modifiedAt,
  bytes: bytes,
  blockedReason: blockedReason,
);

/// 一次默认模型写入的记录。
typedef FakeModelMutation = ({RemoteDshModelRoute route, int revision});

/// 可配置的设置数据源替身。
///
/// [describes] 是 `settings.describe` 的应答序列：每次读取取下一项，读完重复最后
/// 一项。这样「冲突 → 重读」可以在同一次测试里看到不同的 revision。
class FakeRemoteSettingsSource implements RemoteDshSettingsSource {
  FakeRemoteSettingsSource({
    this.capability = const RemoteDshCapability.available(),
    required List<RemoteDshSettingsSnapshot> describes,
    this.afterMutation,
    this.mutateError,
    this.describeError,
  }) : describes = describes.isEmpty
           ? const <RemoteDshSettingsSnapshot>[RemoteDshSettingsSnapshot()]
           : describes;

  /// 返回给首页入口的能力状态。
  final RemoteDshCapability capability;

  /// `settings.describe` 的应答序列。
  final List<RemoteDshSettingsSnapshot> describes;

  /// 写入成功后返回的设置；为 null 时返回下一次 describe 应答。
  final RemoteDshSettingsSnapshot? afterMutation;

  /// 非 null 时写入以它失败（版本冲突测试用 `SETTINGS_CONFLICT`）。
  Object? mutateError;

  /// 非 null 时读取以它失败。
  Object? describeError;

  /// `settings.describe` 的调用次数。
  int describeCalls = 0;

  /// 按顺序记录的写入请求。
  final List<FakeModelMutation> mutations = <FakeModelMutation>[];

  @override
  RemoteDshCapability get settingsCapability => capability;

  @override
  Future<RemoteDshSettingsSnapshot> describeSettings() async {
    final failure = describeError;
    if (failure != null) throw failure;
    final index = describeCalls < describes.length
        ? describeCalls
        : describes.length - 1;
    describeCalls++;
    return describes[index];
  }

  @override
  Future<RemoteDshSettingsSnapshot> saveDefaultModel({
    required RemoteDshModelRoute route,
    required int revision,
  }) async {
    mutations.add((route: route, revision: revision));
    final failure = mutateError;
    if (failure != null) throw failure;
    final configured = afterMutation;
    if (configured != null) return configured;
    final index = describeCalls < describes.length
        ? describeCalls
        : describes.length - 1;
    return describes[index];
  }
}

/// 构造一份设置快照；只列测试关心的节。
RemoteDshSettingsSnapshot fakeSettingsSnapshot({
  List<RemoteDshSettingsSection> sections = const <RemoteDshSettingsSection>[],
  bool writable = true,
}) => RemoteDshSettingsSnapshot(sections: sections, writable: writable);

/// 构造默认模型那一节；[revision] 是写回时要带上的版本。
RemoteDshSettingsSection fakeDefaultModelSection({
  String provider = 'deepseek-account',
  String model = 'deepseek-flash',
  String? reasoningEffort,
  int revision = 3,
  List<RemoteDshSettingField>? fields,
}) => RemoteDshSettingsSection(
  ns: 'agent-default-model',
  title: '默认模型',
  revision: revision,
  value: <String, dynamic>{
    'provider': provider,
    'model': model,
    'reasoningEffort': ?reasoningEffort,
  },
  fields:
      fields ??
      <RemoteDshSettingField>[
        const RemoteDshSettingField(
          path: <String>['provider'],
          label: '模型提供方',
          value: 'deepseek-account',
          kind: RemoteDshSettingFieldKind.text,
        ),
      ],
);

/// 构造一个只读设置节。
RemoteDshSettingsSection fakeSettingsSection({
  required String ns,
  required String title,
  List<RemoteDshSettingField> fields = const <RemoteDshSettingField>[],
  int revision = 1,
}) => RemoteDshSettingsSection(
  ns: ns,
  title: title,
  revision: revision,
  fields: fields,
);

/// 构造一个只读字段。
RemoteDshSettingField fakeSettingField({
  required String name,
  required String label,
  required String value,
  RemoteDshSettingFieldKind kind = RemoteDshSettingFieldKind.text,
  bool configured = false,
}) => RemoteDshSettingField(
  path: <String>[name],
  label: label,
  value: value,
  kind: kind,
  configured: configured,
);

/// 可配置的模型目录替身。
class FakeRemoteModelCatalogSource implements RemoteDshModelCatalogSource {
  FakeRemoteModelCatalogSource(this.catalog, {this.error});

  /// 返回的模型目录。
  final RemoteDshModelCatalog catalog;

  /// 非 null 时读取以它失败（测试手动填写回退）。
  Object? error;

  /// 调用次数。
  int calls = 0;

  @override
  Future<RemoteDshModelCatalog> describeModelCatalog() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return catalog;
  }
}

/// 构造目录：一个提供方、若干模型，可选推理强度。
RemoteDshModelCatalog fakeModelCatalog({
  List<RemoteDshModelGroup>? groups,
  List<String> failures = const <String>[],
}) => RemoteDshModelCatalog(
  groups:
      groups ??
      <RemoteDshModelGroup>[
        RemoteDshModelGroup(
          id: 'deepseek-account',
          name: 'DeepSeek 账号',
          models: <RemoteDshModel>[
            const RemoteDshModel(
              id: 'deepseek-flash',
              name: 'DeepSeek-V4-Flash',
            ),
            const RemoteDshModel(
              id: 'deepseek-v4-pro',
              name: 'DeepSeek-V4-Pro',
              reasoning: RemoteDshModelReasoning(
                efforts: <RemoteDshReasoningLevel>[
                  RemoteDshReasoningLevel(id: 'low', name: '低'),
                  RemoteDshReasoningLevel(id: 'high', name: '高'),
                ],
                defaultEffort: 'low',
              ),
            ),
          ],
        ),
      ],
  failures: failures,
);
