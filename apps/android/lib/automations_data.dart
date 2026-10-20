import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'runtime.dart';

/// View state for the original Host schedule catalog. The Host owns all tasks.
class AutomationsController extends ChangeNotifier {
  AutomationsController(this.runtime);
  final RuntimeController runtime;
  List<Json> records = [];
  bool loading = false, settled = false;
  String? error;
  StreamSubscription<Json>? _events;
  bool _disposed = false, _ready = false;
  int _read = 0;

  Future<dynamic> api(String method, [Json args = const {}]) => runtime.call(
    'api.call',
    {'namespace': 'schedule', 'method': method, 'args': args},
  );

  void start() {
    _ready = runtime.ready;
    runtime.addListener(_connectionChanged);
    _events = runtime.remoteEvents.listen((event) {
      if (event['event'] == 'schedule/changed') unawaited(refresh());
    });
    unawaited(refresh());
  }

  void _connectionChanged() {
    if (_ready == runtime.ready) return;
    _ready = runtime.ready;
    if (_ready) {
      unawaited(refresh());
    } else {
      _read++;
      loading = false;
      _publish();
    }
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final read = ++_read;
    if (!runtime.ready) {
      loading = false;
      _publish();
      return;
    }
    loading = true;
    error = null;
    _publish();
    try {
      final result = await api('catalog') as List;
      if (_disposed || read != _read) return;
      records = result.cast<Json>();
      settled = true;
    } catch (failure) {
      if (_disposed || read != _read) return;
      error = '无法读取任务列表：$failure';
    } finally {
      if (!_disposed && read == _read) {
        loading = false;
        _publish();
      }
    }
  }

  Json? find(String id) {
    for (final record in records) {
      if (record['id'] == id) return record;
    }
    return null;
  }

  Future<Json> update(Json request) async {
    final result = await api('update', {'request': request}) as Json;
    if (result.containsKey('record') ||
        const {
          'schedule_conflict',
          'schedule_ended',
          'schedule_not_found',
        }.contains(result['code'])) {
      await refresh();
    }
    return result;
  }

  Future<Json> delete(Json record) async {
    final result = await api('delete', {
      'request': {'sessionId': record['sessionId'], 'id': record['id']},
    }) as Json;
    await refresh();
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    _read++;
    runtime.removeListener(_connectionChanged);
    unawaited(_events?.cancel());
    super.dispose();
  }
}

/// The original compare-and-update contract excludes catalog metadata.
Json automationSnapshot(Json record) {
  final kind = record['kind'] as String;
  final keys = switch (kind) {
    'after' => ['afterSeconds'],
    'at' => <String>[],
    'every' => ['everySeconds'],
    'daily' => ['time', 'timeZone'],
    'weekly' => ['time', 'timeZone', 'weekdays'],
    'cron' => ['expression', 'timeZone'],
    _ => throw FormatException('不支持的任务规则：$kind'),
  };
  return {
    for (final key in ['id', 'kind', 'title', 'prompt', 'scheduledAt', ...keys])
      key: record[key] is List ? List.of(record[key] as List) : record[key],
  };
}

bool sameAutomation(Json left, Json right) =>
    jsonEncode(automationSnapshot(left)) ==
    jsonEncode(automationSnapshot(right));

/// An edit draft keeps its captured expected record until an explicit rebase.
/// Time zone interpretation and validation remain with the original Host.
class AutomationDraft {
  AutomationDraft(Json record)
    : base = Map.of(record),
      values = _values(record),
      _initial = _values(record);

  Json base;
  Map<String, String> values;
  Map<String, String> _initial;
  static const timingFields = [
    'kind',
    'date',
    'time',
    'zone',
    'seconds',
    'expression',
    'weekdays',
  ];

  static Map<String, String> _values(Json record) {
    final at = DateTime.parse(record['scheduledAt'] as String).toUtc();
    final stamp = at.toIso8601String();
    return {
      'title': record['title'] as String,
      'prompt': record['prompt'] as String,
      'kind': record['kind'] == 'after' ? 'at' : record['kind'] as String,
      'date': stamp.substring(0, 10),
      'time':
          record['time'] as String? ?? stamp.substring(11).replaceAll('Z', ''),
      'zone': record['timeZone'] as String? ?? 'UTC',
      'seconds': '${record['everySeconds'] ?? 60}',
      'expression': record['expression'] as String? ?? '0 9 * * *',
      'weekdays': (record['weekdays'] as List? ?? [1]).join(','),
    };
  }

  bool get dirty => !mapEquals(values, _initial);
  bool get timingDirty =>
      timingFields.any((field) => values[field] != _initial[field]);

  void rebase(Json current) {
    final next = _values(current);
    final keepTiming = timingDirty;
    for (final field in ['title', 'prompt']) {
      if (values[field] == _initial[field]) values[field] = next[field]!;
    }
    if (!keepTiming) {
      for (final field in timingFields) {
        values[field] = next[field]!;
      }
    }
    base = Map.of(current);
    _initial = next;
  }

  void reset(Json current) {
    base = Map.of(current);
    values = _values(current);
    _initial = _values(current);
  }

  Json request() {
    final title = values['title']!.trim();
    final prompt = values['prompt']!.trim();
    if (title.isEmpty || title.length > 120 || prompt.isEmpty) {
      throw const FormatException('填写 1–120 字的名称和非空任务指令。');
    }
    return {
      'id': base['id'],
      'sessionId': base['sessionId'],
      'expected': automationSnapshot(base),
      if (title != _initial['title']) 'title': title,
      if (prompt != _initial['prompt']) 'prompt': prompt,
      if (timingDirty) 'change': _change(),
    };
  }

  Json _change() {
    final kind = values['kind']!;
    final clock = {
      'time': values['time']!.trim(),
      'time_zone': values['zone']!.trim(),
    };
    switch (kind) {
      case 'at':
        return {
          'kind': 'at',
          'at': {'date': values['date']!.trim(), ...clock},
        };
      case 'every':
        final seconds = int.tryParse(values['seconds']!.trim());
        if (seconds == null || seconds < 60 || seconds > 9007199254740991) {
          throw const FormatException('间隔须为至少 60 的安全整数秒。');
        }
        return {'kind': 'every', 'every_seconds': seconds};
      case 'daily':
        return {'kind': 'daily', 'daily': clock};
      case 'weekly':
        final days = values['weekdays']!.split(',').map(int.parse).toList();
        if (days.isEmpty || days.any((day) => day < 1 || day > 7)) {
          throw const FormatException('至少选择一个星期。');
        }
        return {
          'kind': 'weekly',
          'weekly': {...clock, 'weekdays': days},
        };
      case 'cron':
        return {
          'kind': 'cron',
          'cron': {
            'expression': values['expression']!.trim(),
            'time_zone': values['zone']!.trim(),
          },
        };
      default:
        throw const FormatException('请选择任务规则。');
    }
  }
}

String automationError(String code) => switch (code) {
  'schedule_conflict' => '任务已被修改。草稿已保留，请比较当前记录后再保存。',
  'schedule_ended' => '任务已结束，不能继续修改。草稿已保留。',
  'schedule_not_found' => '任务已不存在。草稿已保留。',
  'subagent_session' => '子 Agent 会话不能接收定时任务。',
  'invalid_time_zone' => '时区无效，请使用 UTC 或 IANA 时区名称。',
  'not_future' => '执行时间必须在未来。',
  'frequency_too_high' => '执行频率过高，请增大间隔。',
  'delivery_cursor_not_found' => '历史游标已失效，请刷新投递记录。',
  'invalid_prompt' => '任务名称或指令无效。',
  'invalid_selector' ||
  'invalid_rule' ||
  'time_out_of_range' => '任务规则无效，请检查日期、时间、间隔和表达式。',
  _ => '操作未完成（$code）。',
};

String automationRule(Json record) => switch (record['kind']) {
  'at' || 'after' => '单次 · ${record['scheduledAt']}',
  'every' => '每 ${record['everySeconds']} 秒',
  'daily' => '每天 ${record['time']} · ${record['timeZone']}',
  'weekly' =>
    '每周 ${(record['weekdays'] as List).join('、')} · ${record['time']} · ${record['timeZone']}',
  'cron' => 'Cron ${record['expression']} · ${record['timeZone']}',
  _ => '未知规则',
};

class AutomationHistory extends ChangeNotifier {
  AutomationHistory(this.catalog, this.record);
  final AutomationsController catalog;
  final Json record;
  List<Json> records = [];
  Json? page;
  bool loading = false, _disposed = false;
  String? error, _retryBefore;
  int _read = 0;
  String? _latestReceipt;
  bool _connected = false;

  void start() {
    _connected = catalog.runtime.ready;
    _latestReceipt =
        catalog.find(record['id'] as String)?['lastDelivery']?['messageId']
            as String?;
    catalog.addListener(_catalogChanged);
    if (_connected) unawaited(load());
  }

  void _catalogChanged() {
    final connected = catalog.runtime.ready;
    final receipt =
        catalog.find(record['id'] as String)?['lastDelivery']?['messageId']
            as String?;
    if (connected && (!_connected || receipt != _latestReceipt)) {
      unawaited(load());
    }
    _connected = connected;
    _latestReceipt = receipt;
    if (!connected) {
      _read++;
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> load({String? before}) async {
    if (_disposed || !catalog.runtime.ready || (loading && before != null)) {
      return;
    }
    final read = ++_read;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await catalog.api('history', {
        'request': {
          'id': record['id'],
          'sessionId': record['sessionId'],
          'limit': 20,
          'before': ?before,
        },
      }) as Json;
      if (_disposed || read != _read) return;
      if (result['code'] != null) {
        error = automationError(result['code'] as String);
        _retryBefore = null;
      } else {
        final incoming = (result['records'] as List).cast<Json>();
        final seen = before == null
            ? <dynamic>{}
            : records.map((item) => item['messageId']).toSet();
        records = [
          if (before != null) ...records,
          for (final item in incoming)
            if (seen.add(item['messageId'])) item,
        ];
        page = result;
      }
    } catch (failure) {
      if (_disposed || read != _read) return;
      error = '无法读取投递记录：$failure';
      _retryBefore = before;
    } finally {
      if (!_disposed && read == _read) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> retry() => load(before: _retryBefore);
  @override
  void dispose() {
    _disposed = true;
    _read++;
    catalog.removeListener(_catalogChanged);
    super.dispose();
  }
}
