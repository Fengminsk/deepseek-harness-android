import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'session_search_data.dart';
import 'ui.dart';

/// Selects a session without activating it or submitting an Agent prompt.
class SessionSearchPage extends StatefulWidget {
  const SessionSearchPage({
    super.key,
    required this.runtime,
    this.initialQuery = '',
  });
  final RuntimeController runtime;
  final String initialQuery;

  @override
  State<SessionSearchPage> createState() => _SessionSearchPageState();
}

class _SessionSearchPageState extends State<SessionSearchPage> {
  late final state = SessionSearchController(
    widget.runtime,
    initialQuery: widget.initialQuery,
  );
  late final input = TextEditingController(text: widget.initialQuery);
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The sidebar supplied an explicitly submitted query. Later text edits and
    // reconnections still require a new submission.
    if (widget.initialQuery.trim().isNotEmpty) unawaited(state.search());
  }

  @override
  void dispose() {
    state.dispose();
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  void _search() {
    focus.unfocus();
    unawaited(state.search());
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => PocketScaffold(
      title: const Text('搜索对话内容'),
      trailing: GlassButton(
        key: const ValueKey('session-search-submit'),
        icon: Icons.search_rounded,
        label: '搜索对话内容',
        solid: true,
        onPressed: state.canSearch ? _search : null,
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: focus.unfocus,
        child: PocketList(
          key: const ValueKey('session-search-list'),
          children: [
            TextField(
              key: const ValueKey('session-search-input'),
              controller: input,
              focusNode: focus,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              onChanged: state.setQuery,
              onSubmitted: (_) => _search(),
              onTapOutside: (_) => focus.unfocus(),
              decoration: InputDecoration(
                hintText: '查找聊过的内容',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: input.text.isEmpty
                    ? null
                    : GlassButton(
                        icon: Icons.close_rounded,
                        label: '清空搜索',
                        onPressed: () {
                          input.clear();
                          state.setQuery('');
                          focus.requestFocus();
                        },
                      ),
                errorText:
                    state.query.trim().isNotEmpty && state.validation != null
                    ? state.validation
                    : null,
                errorMaxLines: 3,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              child: Text(
                '搜索你和 Agent 的对话正文，输入后点击搜索。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (!widget.runtime.ready || state.error != null)
              PocketSection(
                key: const ValueKey('session-search-error'),
                children: [
                  PocketRow(
                    icon: widget.runtime.ready
                        ? Icons.search_off_rounded
                        : Icons.wifi_off_rounded,
                    title: !widget.runtime.ready
                        ? '等待服务连接'
                        : state.phase == SessionSearchPhase.failed
                        ? '未能完成搜索'
                        : '可以重新搜索',
                    subtitle: state.error ?? '连接恢复后，可以提交搜索',
                  ),
                  if (state.canSearch)
                    PocketRow(
                      icon: Icons.refresh_rounded,
                      title: '重新搜索',
                      onTap: _search,
                    ),
                ],
              ),
            if (state.phase == SessionSearchPhase.searching)
              const PocketSection(
                key: ValueKey('session-search-loading'),
                children: [
                  PocketRow(
                    icon: Icons.hourglass_empty_rounded,
                    title: '正在查找对话',
                    subtitle: '首次搜索可能需要更多时间',
                  ),
                ],
              ),
            if (state.phase == SessionSearchPhase.idle &&
                state.error == null &&
                widget.runtime.ready)
              const PocketSection(
                key: ValueKey('session-search-idle'),
                children: [
                  PocketRow(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: '从一句话开始查找',
                    subtitle: '结果会展示匹配摘要，点击可打开对应会话',
                  ),
                ],
              ),
            if (state.phase == SessionSearchPhase.complete) ...[
              if (state.catalogError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                  child: Text(state.catalogError!),
                ),
              PocketSection(
                key: ValueKey('session-search-results:${state.submittedQuery}'),
                title: state.items.isEmpty
                    ? '搜索结果'
                    : '找到 ${state.items.length} 个会话',
                divided: true,
                children: [
                  if (state.items.isEmpty)
                    const PocketRow(
                      icon: Icons.search_off_rounded,
                      title: '没有找到相关对话',
                      subtitle: '试试其他词语或更短的内容',
                    ),
                  for (final item in state.items)
                    PocketTile(
                      key: ValueKey('session-search-result:${item.sessionId}'),
                      leading: const Icon(Icons.chat_bubble_outline_rounded),
                      title: Text(
                        state.title(item.sessionId),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (state.archived(item.sessionId)) const Text('已归档'),
                          if (!state.hasTitle(item.sessionId))
                            Text(
                              item.sessionId,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          Text(item.snippet),
                          if (!state.canOpen(item.sessionId)) ...[
                            const SizedBox(height: 6),
                            const Text('该会话未在当前会话目录中，暂不能从这里打开'),
                          ],
                        ],
                      ),
                      trailing: state.canOpen(item.sessionId)
                          ? const Icon(Icons.chevron_right_rounded, size: 20)
                          : null,
                      onTap: state.canOpen(item.sessionId)
                          ? () => Navigator.pop<String>(context, item.sessionId)
                          : null,
                    ),
                ],
              ),
              if (state.hasMore)
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 0, 18, 20),
                  child: Text('最多显示 20 个会话。还有更多匹配，请缩小搜索范围。'),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}
