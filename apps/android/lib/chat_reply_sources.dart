import 'tool_activity_data.dart';

enum ChatReplySourceKind { search, fetch }

/// Preserves the observed retrieval facts independently of display deduplication.
class ChatReplySourceRecord {
  const ChatReplySourceRecord({
    required this.activityId,
    required this.kind,
    required this.truncated,
    this.statusCode,
  });
  final String activityId;
  final ChatReplySourceKind kind;
  final bool truncated;
  final num? statusCode;
}

class ChatReplySource {
  ChatReplySource({
    required this.url,
    required this.records,
    this.title,
    this.snippet,
    this.publishedAt,
  });
  final String url;
  final String? title, snippet, publishedAt;
  final List<ChatReplySourceRecord> records;

  Uri? get destination {
    final uri = Uri.tryParse(url);
    return uri != null &&
            ['http', 'https'].contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : null;
  }

  String get host => Uri.tryParse(url)?.host ?? '';
  String get label => title?.isNotEmpty == true
      ? title!
      : host.isNotEmpty
      ? host
      : url;

  ChatReplySource _merge(ChatReplySource next) => ChatReplySource(
    url: url,
    title: title?.isNotEmpty == true ? title : next.title,
    snippet: snippet?.isNotEmpty == true ? snippet : next.snippet,
    publishedAt: publishedAt?.isNotEmpty == true
        ? publishedAt
        : next.publishedAt,
    records: List.unmodifiable([...records, ...next.records]),
  );
}

/// Feed ONLY this answer's Turn activities. No assistant Markdown, caller input,
/// model inference or network favicon request participates in source discovery.
/// Mirrors tool-web searchMetaFromResult/fetchMetaFromResult validation. An old
/// or malformed result has no structured sources; its raw log remains elsewhere.
class ChatReplySources {
  const ChatReplySources._(this.entries, this.truncated);
  static const empty = ChatReplySources._([], false);
  final List<ChatReplySource> entries;
  final bool truncated;
  bool get isEmpty => entries.isEmpty;

  factory ChatReplySources.fromActivities(Iterable<ToolActivity> activities) {
    final byUrl = <String, ChatReplySource>{};
    final visited = <String>{};
    var truncated = false;
    void add(ChatReplySource source) {
      final previous = byUrl[source.url];
      byUrl[source.url] = previous == null ? source : previous._merge(source);
    }

    void visit(ToolActivity activity) {
      if (!visited.add(activity.identity)) return;
      // Nested PTC results retain the original name/meta; never parse the parent
      // execute-code output looking for something that resembles a source.
      if (activity.hasResult &&
          activity.phase == ToolActivityPhase.completed &&
          activity.error == null) {
        final meta = activity.meta;
        if (meta is Map && activity.name == 'web_search') {
          final sources = meta['sources'];
          if (sources is List &&
              sources.every(_isSearchSource) &&
              meta['truncated'] is bool &&
              (!meta.containsKey('answer') || meta['answer'] is String)) {
            truncated = truncated || meta['truncated'] == true;
            for (final raw in sources.cast<Map>()) {
              add(
                ChatReplySource(
                  url: raw['url'],
                  title: raw['title'],
                  snippet: raw['snippet'],
                  publishedAt: raw['publishedAt'],
                  records: List.unmodifiable([
                    ChatReplySourceRecord(
                      activityId: activity.identity,
                      kind: ChatReplySourceKind.search,
                      truncated: meta['truncated'],
                    ),
                  ]),
                ),
              );
            }
          }
        } else if (meta is Map &&
            activity.name == 'web_fetch' &&
            meta['url'] is String &&
            meta['statusCode'] is num &&
            meta['truncated'] is bool) {
          truncated = truncated || meta['truncated'] == true;
          add(
            ChatReplySource(
              url: meta['url'],
              records: List.unmodifiable([
                ChatReplySourceRecord(
                  activityId: activity.identity,
                  kind: ChatReplySourceKind.fetch,
                  truncated: meta['truncated'],
                  statusCode: meta['statusCode'],
                ),
              ]),
            ),
          );
        }
      }
      for (final child in activity.children) {
        visit(child);
      }
    }

    for (final activity in activities) {
      visit(activity);
    }
    return ChatReplySources._(List.unmodifiable(byUrl.values), truncated);
  }

  static bool _isSearchSource(dynamic value) =>
      value is Map &&
      value['url'] is String &&
      [
        'title',
        'snippet',
        'publishedAt',
      ].every((key) => !value.containsKey(key) || value[key] is String);
}
