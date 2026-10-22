import 'configuration_fields_schema.dart';

/// Copy belongs to exact bundled namespace/path pairs. Unknown plugin fields
/// retain their own schema labels and types instead of inheriting a name guess.
class ConfigurationPresentation {
  const ConfigurationPresentation(this.namespace);
  final String namespace;

  /// Groups only exact field paths. Fields introduced by a newer plugin stay
  /// available outside these groups until their presentation is described.
  List<ConfigurationFieldGroup> get groups => _groups[namespace] ?? const [];

  String title(List<String> path, ConfigurationFieldSchema field) =>
      _fields[namespace]?[path.join('.')]?.$1 ??
      _localized(field.meta['title']) ??
      _localized(field.meta['name']) ??
      path.last;

  String? description(List<String> path, ConfigurationFieldSchema field) =>
      field.description ?? _fields[namespace]?[path.join('.')]?.$2;

  String option(List<String> path, dynamic value) =>
      _options['$namespace.${path.join('.')}']?[value] ??
      configurationStructureSummary(value);

  bool offerOption(List<String> path, dynamic value) =>
      !(namespace == 'ui-chat' &&
          path.join('.') == 'transcriptView' &&
          const ['normal', 'expanded'].contains(value));
}

enum ConfigurationGroupSymbol {
  shell,
  search,
  folder,
  attachment,
  stream,
  shutdown,
  settings,
}

class ConfigurationFieldGroup {
  const ConfigurationFieldGroup({
    required this.id,
    required this.title,
    required this.summary,
    required this.description,
    required this.symbol,
    required this.paths,
    this.advanced = false,
  });

  final String id, title, summary, description;
  final ConfigurationGroupSymbol symbol;
  final Set<String> paths;
  final bool advanced;

  bool contains(List<String> path) => paths.contains(path.join('.'));
}

const _groups = <String, List<ConfigurationFieldGroup>>{
  'android-runtime': [
    ConfigurationFieldGroup(
      id: 'shell',
      title: 'Shell',
      summary: '执行时间与输出大小',
      description: '控制 Android 普通 Shell 命令的执行时限与结果大小。新命令开始执行时采用已保存的设置。',
      symbol: ConfigurationGroupSymbol.shell,
      paths: {'shellTimeoutMs', 'shellOutputLimit'},
    ),
    ConfigurationFieldGroup(
      id: 'file-search',
      title: '文件搜索',
      summary: '搜索范围、结果与读取限制',
      description: '这些限制用于授权目录和私有工作区的文件搜索。达到限制时会说明搜索未完成；如果未能返回结果，需要缩小范围后重试。',
      symbol: ConfigurationGroupSymbol.search,
      paths: {
        'documentSearchFileBytes',
        'documentSearchTotalBytes',
        'documentSearchMaxEntries',
        'documentSearchMaxFiles',
        'documentSearchMaxDepth',
        'documentSearchMaxMatches',
        'documentSearchPreviewChars',
        'documentSearchMaxDurationMs',
        'documentSearchMaxRequests',
      },
    ),
    ConfigurationFieldGroup(
      id: 'workspace',
      title: '工作区',
      summary: '目录分页与文件分段读取',
      description: '控制私有工作区浏览页面的目录分页和文本分段读取。文件搜索使用文件搜索页中的限制。',
      symbol: ConfigurationGroupSymbol.folder,
      paths: {
        'workspaceReadPageBytes',
        'workspaceDirectoryMaxEntries',
        'workspaceDirectoryPageSize',
      },
    ),
    ConfigurationFieldGroup(
      id: 'attachments',
      title: '会话附件',
      summary: '查看大小、文本分页与打开数量',
      description: '控制查看和保存历史会话附件时的文件校验、临时副本与文本读取。更改后用于下一次准备或读取，不会主动关闭已打开的附件。',
      symbol: ConfigurationGroupSymbol.attachment,
      paths: {
        'attachmentFileMaxBytes',
        'attachmentFileReadPageBytes',
        'attachmentFileMaxRequests',
      },
    ),
    ConfigurationFieldGroup(
      id: 'state-stream',
      title: '状态同步',
      summary: '订阅、消息大小与推送间隔',
      description: '调节本地 Agent 服务向 App 传递状态的方式。通常保留默认值即可。',
      symbol: ConfigurationGroupSymbol.stream,
      advanced: true,
      paths: {
        'appStreamMaxSubscriptions',
        'appStreamMaxFrameBytes',
        'streamPublishMs',
      },
    ),
    ConfigurationFieldGroup(
      id: 'shutdown',
      title: '服务关闭',
      summary: '等待读取、搜索与会话操作收尾',
      description: '仅影响 DSH 服务关闭时的等待时间。超时会报告关闭尚未完成，不会把仍在收尾的操作标记为已结束。',
      symbol: ConfigurationGroupSymbol.shutdown,
      advanced: true,
      paths: {'workspaceFilesCloseTimeoutMs', 'libraryCloseTimeoutMs'},
    ),
  ],
};

String? _localized(dynamic value) {
  if (value is String && value.trim().isNotEmpty) return value;
  if (value is Map) {
    for (final locale in ['zh-CN', 'zh', 'en-US', '']) {
      final text = value[locale];
      if (text is String && text.trim().isNotEmpty) return text;
    }
  }
  return null;
}

const _fields = <String, Map<String, (String, String?)>>{
  // packages/session/session-log-deepseek/src/index.ts Config.enabled.
  'session-log-deepseek': {
    'enabled': ('上传会话日志', '随 DeepSeek 官方模型请求上传会话日志。关闭不会删除手机上的会话。'),
  },
  'agent-loop': {
    'maxParallelToolCalls': ('并行工具调用上限', '一次 Agent 步骤中最多同时执行的工具调用数量。'),
  },
  'agent-default-model': {
    'provider': ('模型提供方', null),
    'model': ('默认模型', null),
    'reasoningEffort': ('思考强度', '未设置时遵循模型提供方的默认值。'),
  },
  'subagent': {
    'maxDepth': (
      '最大递归深度（层）',
      '0 表示禁用子 Agent，1 仅允许主 Agent 创建子 Agent。工具单独设置深度时以工具为准。',
    ),
    'maxActiveSubagents': (
      '子 Agent 并行上限（个）',
      '同一主 Agent 下所有递归层级同时存活的子 Agent 总数，不包含主 Agent。',
    ),
  },
  'subagent-model-selection-settings': {
    'enabled': ('允许 Agent 为子 Agent 选择模型', '对之后新建的会话生效；开启前需要选择至少一个允许使用的模型。'),
    'allowedModels': ('允许使用的模型', '使用已注册的模型提供方和模型 ID；列表中的模型路由不能重复。'),
  },
  'web': {
    'searchProvider': ('搜索服务', 'Agent 搜索网页时使用的已注册服务 ID。未指定时，只有恰好一个服务可用才会自动选择。'),
    'fetchProvider': (
      '网页读取服务',
      'Agent 获取网页内容时使用的已注册服务 ID。未指定时，只有恰好一个服务可用才会自动选择。',
    ),
  },
  'web-search-deepseek': {
    'apiKey': ('API 密钥', '在凭据管理中设置。'),
    'apiKeyEnv': ('凭据引用', '搜索请求读取的凭据名称。'),
    'baseURL': ('搜索服务地址', '独立于聊天模型的服务地址，使用兼容 Anthropic 的接口。'),
    'model': ('搜索模型', '用于搜索请求的模型 ID，与当前聊天模型分别设置。'),
    'apiVersion': ('接口版本', '搜索请求的 anthropic-version 标头。'),
    'maxTokens': ('最大输出 Token', '单次搜索请求生成内容的 Token 上限。'),
    'maxUses': ('最多搜索次数', '单次请求允许服务端调用网页搜索工具的次数。'),
  },
  'web-deepseek-api': {
    'apiKey': ('API 密钥', '在凭据管理中设置。'),
    'apiKeyEnv': ('凭据引用', '联网服务读取的凭据名称。'),
    'baseURL': ('联网服务地址', 'Search/Fetch API 的基础地址，可包含路径前缀。'),
    'count': ('搜索结果数量', '每次搜索请求返回的结果数量。'),
    'sendOriginalQuestion': ('向搜索服务发送原始问题', '发送触发本轮的用户问题，最多 128 个字符。'),
  },
  // apps/android/runtime/index.mjs; values retain wire milliseconds/bytes.
  'android-runtime': {
    'shellTimeoutMs': ('执行超时（毫秒）', '每条获准执行的命令开始时采用此值。超时后请求结束命令及其子进程。'),
    'shellOutputLimit': ('输出上限（字节）', '标准输出和错误输出各自最多保留的字节数。超出部分会被截断，命令不会因此停止。'),
    'appStreamMaxSubscriptions': (
      '状态订阅上限',
      '每个 App 连接可同时订阅的状态流数量。达到上限时需关闭无用页面后重试；不限制 Agent 任务数量。',
    ),
    'appStreamMaxFrameBytes': (
      '状态消息上限（字节）',
      '单条状态流消息序列化后的 UTF-8 大小上限。超出时该状态流报错，需要缩小请求范围；此设置不会扩大 Android 的 IPC 限制。',
    ),
    'streamPublishMs': (
      '状态更新间隔（毫秒）',
      '流式回复片段合并后向 App 推送的间隔。较小值更新更频繁，不改变模型生成速度。',
    ),
    'documentSearchFileBytes': (
      '单文件搜索上限（字节）',
      '单次搜索允许读取一个文件的最大大小。超过上限的文件会跳过并说明原因，不只搜索它的前半部分。',
    ),
    'documentSearchTotalBytes': (
      '搜索总读取上限（字节）',
      '单次搜索累计读取文件内容的大小上限。应不小于单文件上限；达到预算时保留已有结果并停止继续读取。',
    ),
    'documentSearchMaxEntries': (
      '搜索目录项上限',
      '单次搜索最多检查的目录条目数，包括文件和文件夹。此值不是搜索结果数量。',
    ),
    'documentSearchMaxFiles': (
      '正文搜索文件数上限',
      '限制单次正文搜索尝试处理的文件数，不影响名称搜索。授权目录会先排除虚拟文件和已知过大的文件；工作区中因大小跳过的文件也会计入。',
    ),
    'documentSearchMaxDepth': ('搜索目录深度', '以所选目录为起点；1 只检查当前目录中的项目，不进入子目录内部。'),
    'documentSearchMaxMatches': (
      '搜索匹配数上限',
      '单次搜索最多保留的匹配结果数。正文搜索按匹配行计数，同一个文件可以有多条结果。',
    ),
    'documentSearchPreviewChars': ('搜索摘要长度（字符）', '正文匹配结果中每段摘要的最长字符数，不改变原文件内容。'),
    'documentSearchMaxDurationMs': (
      '搜索超时（毫秒）',
      '单次搜索的时间预算。达到时会停止搜索并提示未完成；如果未能返回结果，需要缩小范围后重试。',
    ),
    'documentSearchMaxRequests': (
      '并行搜索上限',
      '授权目录搜索与工作区搜索各自允许同时运行的请求数。达到上限后，需要等已有搜索结束再发起新搜索。',
    ),
    'workspaceReadPageBytes': (
      '文件每页读取大小（字节）',
      '每次分段读取文本文件时最多读取的字节数。长文件可以继续读取下一段，此值不改变文件搜索的大小上限。',
    ),
    'workspaceDirectoryMaxEntries': (
      '工作区目录项上限',
      '浏览单个目录时最多收集的条目数。超出部分不会在本次列表中显示。',
    ),
    'workspaceDirectoryPageSize': (
      '目录每页项目数',
      '每次加载目录列表的条目数。这里只影响分批显示，不扩大目录项上限。',
    ),
    'attachmentFileMaxBytes': (
      '附件文件大小上限（字节）',
      '查看或保存历史会话附件时，允许校验和复制的单文件大小上限。这不是发送附件的大小限制。',
    ),
    'attachmentFileReadPageBytes': (
      '附件文本每页读取大小（字节）',
      'UTF-8 文本附件每次预览的字节预算。长文本可继续读取下一段，不改变原文件内容。',
    ),
    'attachmentFileMaxRequests': (
      '同时打开附件数',
      '允许同时打开或正在准备的附件数量。达到上限时，需要关闭已有附件再打开新的附件；降低此值不会主动关闭已打开的页面。',
    ),
    'workspaceFilesCloseTimeoutMs': (
      '工作区关闭等待（毫秒）',
      'DSH 服务关闭时，等待私有工作区读取和搜索结束的时间。超时会提示关闭尚未完成。',
    ),
    'libraryCloseTimeoutMs': (
      '会话服务关闭等待（毫秒）',
      'DSH 服务关闭时，等待工作区与会话管理中的读写操作收尾的时间。超时会报告未完成，不会重发写入。',
    ),
  },
  'bash-sandbox': _shellFields,
  'pwsh-sandbox': _shellFields,
  'agent-preset-registry': {
    'selectedDefault': ('默认 Agent 预设', '新建会话使用的预设 ID。'),
  },
  'ui-settings': {'enabled': ('启用开发者工具', '控制聊天中的文件改动，并与原版 Web 的开发者工具共用开关。')},
  'ui-settings-account': {
    'version': ('引导数据版本', '原版桌面端首次引导的记录格式版本。'),
    'step': ('当前引导步骤', '已保存的桌面端引导进度，不代表账号登录状态。'),
    'purpose': ('使用场景记录', '在原版桌面端首次引导中选择的工作场景。'),
    'process': ('工作详情偏好记录', '仅修改引导记录。实际显示方式请在 Web 聊天展示中设置。'),
    'completion': ('引导完成方式', '首次引导的完成原因，不代表账号授权状态。'),
    'usage': ('用量详情偏好记录', '仅修改引导记录，不改变实际用量展示。'),
    'developerTools': ('开发者功能偏好记录', '仅修改引导记录。实际开关请在开发者工具中设置。'),
  },
  'ui-conversation': {'busyEnter': ('运行时按回车', '原版 Web 在 Agent 繁忙时如何处理新消息。')},
  'ui-chat': {
    'transcriptView': ('工作详情', '原版 Web 中工具调用和过程消息的显示方式。'),
    'collapseTiming': ('工作详情折叠时机', '控制整轮执行完成后的工作详情折叠时机。'),
    'performanceUsage': ('性能与用量详情', null),
    'linkOpening': ('打开网页链接', null),
  },
  'ui-theme': {
    'preference': ('Web 显示模式', null),
    'fontSize': ('正文字号（像素）', null),
    'codeFontSize': ('代码字号（像素）', null),
    'terminalFontSize': ('终端字号（像素）', null),
    'textFontFamily': ('正文字体', '留空时使用原版 Web 的默认字体。'),
    'codeFontFamily': ('代码字体', '留空时使用原版 Web 的默认字体。'),
    'terminalFontFamily': ('终端字体', '留空时使用原版 Web 的默认字体。'),
  },
};

const _shellFields = <String, (String, String?)>{
  'cwd': ('工作目录', null),
  'timeoutMs': ('默认超时（毫秒）', '前台命令默认执行时间限制。'),
  'maxTimeoutMs': ('最长超时（毫秒）', null),
  'maxOutputBytes': ('每路输出上限（字节）', '标准输出和错误输出各自保留的内存大小。'),
  'maxSpillBytes': ('输出文件上限（字节）', null),
  'graceMs': ('退出宽限（毫秒）', null),
  'pwshPath': ('PowerShell 路径', null),
};

const _options = <String, Map<dynamic, String>>{
  'ui-settings-account.step': {
    'welcome': '欢迎',
    'credit': '额度',
    'purpose': '使用场景',
    'process': '工作详情',
    'done': '完成',
  },
  'ui-settings-account.purpose': {
    'office': '办公',
    'development': '开发',
    'both': '办公与开发',
    null: '尚未选择',
  },
  'ui-settings-account.process': {
    'compact': '紧凑',
    'standard': '标准',
    'detailed': '详细',
    null: '尚未选择',
  },
  'ui-settings-account.completion': {
    'completed': '已完成引导',
    'skipped': '已跳过引导',
    'api-key': '使用 API 密钥',
    null: '尚未完成',
  },
  'ui-settings-account.usage': {'compact': '简洁', 'detailed': '详细'},
  'ui-theme.preference': {'system': '跟随系统', 'light': '浅色', 'dark': '深色'},
  'ui-conversation.busyEnter': {'queue': '排队发送', 'steer': '立即补充指令'},
  'ui-chat.transcriptView': {
    'compact': '紧凑',
    'standard': '标准',
    'detailed': '详细',
    'verbose': '完整',
  },
  'ui-chat.collapseTiming': {'completion': '完成时', 'next-input': '下一次输入时'},
  'ui-chat.performanceUsage': {'compact': '简洁', 'detailed': '详细'},
  'ui-chat.linkOpening': {'sidebar': 'Web 侧栏', 'new-tab': '新标签页'},
};
