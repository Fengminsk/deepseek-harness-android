import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'models_data.dart';
import 'plugins_data.dart';
import 'runtime.dart';

const deepSeek1017Plugin =
    '@deepseek-ai/dsh-client-ui-deepseek-model-label-1017';

/// The browser slot is present only while its Loader entry is active. A stale
/// or unread inventory is not evidence that a disabled plugin is available.
bool deepSeek1017PluginActive(PluginsController plugins) {
  if (!plugins.fresh) return false;
  final entries = plugins.inventory?['entries'];
  if (entries is! List) return false;
  final matches = entries.where(
    (entry) => entry is Map && entry['moduleName'] == deepSeek1017Plugin,
  );
  if (matches.length != 1) return false;
  final entry = matches.single as Map;
  return entry['enabled'] == true && entry['fiberPhase'] == 'active';
}

/// One read-only catalog request for the home trigger. The general Models
/// directory also reads provider settings and schedules retries for editors;
/// the chat header must not start those unrelated background reads.
class CurrentModelCatalog extends ChangeNotifier with WidgetsBindingObserver {
  CurrentModelCatalog(this.runtime)
    : _connection = runtime.connectionGeneration,
      _ready = runtime.ready {
    runtime.addListener(_runtimeChanged);
    WidgetsBinding.instance.addObserver(this);
    if (runtime.ready) unawaited(refresh());
  }

  final RuntimeController runtime;
  Json? catalog;
  bool fresh = false;
  bool _disposed = false;
  int _connection, _revision = 0;
  bool _ready;
  Future<void>? _read;

  void _runtimeChanged() {
    if (_disposed ||
        (_connection == runtime.connectionGeneration &&
            _ready == runtime.ready)) {
      return;
    }
    _connection = runtime.connectionGeneration;
    _ready = runtime.ready;
    _revision++;
    // A previous connection's read must not hold the new connection's slot.
    // Its revision check still prevents that response from being published.
    _read = null;
    fresh = false;
    catalog = null;
    notifyListeners();
    if (runtime.ready) unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() {
    if (_disposed || !runtime.ready) return Future.value();
    if (_read != null) return _read!;
    final revision = ++_revision;
    final connection = runtime.connectionGeneration;
    bool current() =>
        !_disposed &&
        runtime.ready &&
        revision == _revision &&
        connection == runtime.connectionGeneration;
    late final Future<void> operation;
    operation =
        () async {
          try {
            final result = await modelsApi(runtime, 'session', 'modelCatalog');
            if (!current()) return;
            if (result is! Json || result['groups'] is! List) {
              throw const FormatException('Model catalog is incomplete');
            }
            catalog = result;
            fresh = true;
            notifyListeners();
          } catch (_) {
            if (!current()) return;
            fresh = false;
            notifyListeners();
          }
        }().whenComplete(() {
          if (identical(_read, operation)) _read = null;
        });
    return _read = operation;
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    runtime.removeListener(_runtimeChanged);
    super.dispose();
  }
}

/// A raw model ID, missing catalog or previous-connection cache must never
/// qualify for the fixed release marker.
String currentModelCatalogName(CurrentModelCatalog directory, Json route) {
  if (!directory.fresh) {
    return '${route['model']}';
  }
  final groups = directory.catalog?['groups'];
  if (groups is! List) return '${route['model']}';
  for (final group in groups) {
    if (group is! Map || group['id'] != route['provider']) continue;
    final models = group['models'];
    if (models is! List) break;
    for (final model in models) {
      if (model is Map && model['id'] == route['model']) {
        return model['name'] is String
            ? model['name'] as String
            : '${route['model']}';
      }
    }
    break;
  }
  return '${route['model']}';
}

/// One presentation source for the composer trigger and Session model rows.
class PluginAwareModelReleaseLabel extends StatelessWidget {
  const PluginAwareModelReleaseLabel({
    super.key,
    required this.runtime,
    required this.providerId,
    required this.modelId,
    required this.modelName,
    this.suffix,
  });

  final RuntimeController runtime;
  final String providerId, modelId, modelName;
  final String? suffix;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: runtime.plugins,
    builder: (context, _) => ModelReleaseLabel(
      providerId: providerId,
      modelId: modelId,
      modelName: modelName,
      suffix: suffix,
      badgeEnabled: deepSeek1017PluginActive(runtime.plugins),
    ),
  );
}

class CurrentModelReleaseLabel extends StatelessWidget {
  const CurrentModelReleaseLabel({
    super.key,
    required this.runtime,
    required this.catalog,
    required this.selection,
  });

  final RuntimeController runtime;
  final CurrentModelCatalog catalog;
  final Json selection;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: catalog,
    builder: (context, _) => PluginAwareModelReleaseLabel(
      runtime: runtime,
      providerId: '${selection['provider']}',
      modelId: '${selection['model']}',
      modelName: currentModelCatalogName(catalog, selection),
    ),
  );
}

/// Mirrors the original ui-deepseek-model-label-1017 display-only predicate.
/// Keep the catalog name and routing ID untouched; this is never an alias.
bool showsDeepSeek1017Badge({
  required String providerId,
  required String modelId,
  required String modelName,
  bool enabled = true,
}) =>
    enabled &&
    (providerId == 'deepseek-account' || providerId == 'deepseek-official') &&
    modelId == 'deepseek-flash' &&
    modelName == 'DeepSeek-V4.1-Flash';

/// Inline presentation used by model selection surfaces, never by API calls.
class ModelReleaseLabel extends StatelessWidget {
  const ModelReleaseLabel({
    super.key,
    required this.providerId,
    required this.modelId,
    required this.modelName,
    this.suffix,
    this.badgeEnabled = true,
  });

  final String providerId;
  final String modelId;
  final String modelName;
  final String? suffix;
  final bool badgeEnabled;

  @override
  Widget build(BuildContext context) {
    final badge = showsDeepSeek1017Badge(
      providerId: providerId,
      modelId: modelId,
      modelName: modelName,
      enabled: badgeEnabled,
    );
    if (!badge) return Text('$modelName${suffix ?? ''}');
    final colors = Theme.of(context).colorScheme;
    final style = DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: modelName),
          const TextSpan(text: ' '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                child: Text(
                  '1017',
                  style: style.copyWith(
                    fontSize: 11,
                    height: 1.1,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ),
          if (suffix != null) TextSpan(text: suffix),
        ],
      ),
    );
  }
}
