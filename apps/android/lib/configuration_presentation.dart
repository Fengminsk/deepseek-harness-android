import 'configuration_fields_schema.dart';

/// Copy belongs to exact bundled namespace/path pairs. Unknown plugin fields
/// retain their own schema labels and types instead of inheriting a name guess.
class ConfigurationPresentation {
  const ConfigurationPresentation(this.namespace);
  final String namespace;

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
    'shellTimeoutMs': ('Shell 执行超时（毫秒）', '已获批准的命令允许执行的最长时间。'),
    'shellOutputLimit': ('Shell 输出上限（字节）', '单次命令保留的输出大小上限。'),
    'appStreamMaxSubscriptions': ('状态订阅上限', null),
    'appStreamMaxFrameBytes': ('状态消息上限（字节）', null),
    'streamPublishMs': ('状态更新间隔（毫秒）', null),
    'documentSearchFileBytes': ('单文件搜索上限（字节）', null),
    'documentSearchTotalBytes': ('搜索总读取上限（字节）', null),
    'documentSearchMaxEntries': ('搜索目录项上限', null),
    'documentSearchMaxFiles': ('搜索文件数上限', null),
    'documentSearchMaxDepth': ('搜索目录深度', null),
    'documentSearchMaxMatches': ('搜索匹配数上限', null),
    'documentSearchPreviewChars': ('搜索摘要长度（字符）', null),
    'documentSearchMaxDurationMs': ('搜索超时（毫秒）', null),
    'documentSearchMaxRequests': ('并行搜索上限', null),
    'workspaceReadPageBytes': ('文件每页读取大小（字节）', null),
    'workspaceDirectoryMaxEntries': ('工作区目录项上限', null),
    'workspaceDirectoryPageSize': ('目录每页项目数', null),
    'workspaceFilesCloseTimeoutMs': ('工作区文件关闭超时（毫秒）', null),
    'libraryCloseTimeoutMs': ('文件库关闭超时（毫秒）', null),
  },
  'bash-sandbox': _shellFields,
  'pwsh-sandbox': _shellFields,
  'agent-preset-registry': {
    'selectedDefault': ('默认 Agent 预设', '新建会话使用的预设 ID。'),
  },
  'ui-settings': {
    'enabled': ('启用 Web 开发者工具', '控制原版 Web 的诊断、预设选择、变更摘要和脚本化 HTML 预览。'),
  },
  'ui-settings-account': {
    'version': ('引导数据版本', '原版桌面端首次引导的记录格式版本。'),
    'step': ('当前引导步骤', '已保存的桌面端引导进度，不代表账号登录状态。'),
    'purpose': ('使用场景记录', '在原版桌面端首次引导中选择的工作场景。'),
    'process': ('工作详情偏好记录', '仅修改引导记录。实际显示方式请在 Web 聊天展示中设置。'),
    'completion': ('引导完成方式', '首次引导的完成原因，不代表账号授权状态。'),
    'usage': ('用量详情偏好记录', '仅修改引导记录，不改变实际用量展示。'),
    'developerTools': ('开发者功能偏好记录', '仅修改引导记录。实际开关请在 Web 开发者工具中设置。'),
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
