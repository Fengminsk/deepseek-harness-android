import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'account.dart';
import 'models.dart';
import 'models_provider.dart';
import 'runtime.dart';
import 'ui.dart';

/// These namespaces have model/account workflows rather than free-form fields.
bool isModelConfigurationNamespace(String namespace) => const {
  'agent-default-model',
  'llm-deepseek',
  'llm-deepseek-account',
  'llm-pi-ai',
}.contains(namespace);

/// Opens semantic model settings from the general configuration directory.
/// A retained catalog is never used to initialize a new editor after refresh
/// failed. Once opened, the editor keeps its own revision and unsaved draft.
class ConfigurationModelDestination extends StatefulWidget {
  const ConfigurationModelDestination({
    super.key,
    required this.runtime,
    required this.namespace,
  });
  final RuntimeController runtime;
  final String namespace;

  @override
  State<ConfigurationModelDestination> createState() =>
      _ConfigurationModelDestinationState();
}

class _ConfigurationModelDestinationState
    extends State<ConfigurationModelDestination> {
  Widget? destination;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    switch (widget.namespace) {
      case 'llm-deepseek-account':
        // Sign-in must remain reachable when no model catalog can be read.
        destination = AccountPage(runtime: widget.runtime);
        loading = false;
      case 'llm-pi-ai':
        // A namespace contains many provider routes. The existing directory
        // checks freshness again before opening any one provider's editor.
        destination = ModelsPage(runtime: widget.runtime);
        loading = false;
      default:
        unawaited(refresh());
    }
  }

  Future<void> refresh() async {
    setState(() {
      loading = true;
      error = null;
    });
    if (!isModelConfigurationNamespace(widget.namespace)) {
      setState(() {
        loading = false;
        error = '此配置没有模型设置入口。';
      });
      return;
    }
    final directory = widget.runtime.models;
    await directory.refresh();
    if (!mounted) return;
    final snapshot = directory.snapshot;
    if (!directory.fresh || snapshot == null) {
      setState(() {
        loading = false;
        error = directory.error ?? '模型目录暂不可用，请重试。';
      });
      return;
    }
    Widget? page;
    if (widget.namespace == 'agent-default-model') {
      if (snapshot.descriptor(widget.namespace) != null) {
        page = DefaultModelPage(runtime: widget.runtime, snapshot: snapshot);
      }
    } else {
      final providers = snapshot.providers
          .where((provider) => provider.entry['settingsNs'] == widget.namespace)
          .toList();
      if (providers.length == 1 && providers.single.descriptor != null) {
        final provider = providers.single;
        page = provider.account
            ? AccountPage(runtime: widget.runtime)
            : ProviderSettingsPage(runtime: widget.runtime, provider: provider);
      } else if (providers.length > 1) {
        page = ModelsPage(runtime: widget.runtime);
      }
    }
    setState(() {
      loading = false;
      destination = page;
      error = page == null ? '此模型配置已不可用，请返回刷新设置列表。' : null;
    });
  }

  @override
  Widget build(BuildContext context) =>
      destination ??
      PocketScaffold(
        title: Text(
          widget.namespace == 'agent-default-model' ? '默认模型' : '模型与连接',
        ),
        trailing: GlassButton(
          icon: Icons.refresh_rounded,
          label: '重新读取模型设置',
          onPressed: loading ? null : refresh,
        ),
        body: PocketList(
          children: [
            if (loading) const ModelNotice('正在读取模型设置…'),
            if (error != null) ModelNotice(error!),
          ],
        ),
      );
}
