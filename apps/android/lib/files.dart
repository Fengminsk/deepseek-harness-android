import 'package:material_ui/material_ui.dart';

import 'runtime.dart';
import 'ui.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({
    required this.runtime,
    this.root,
    this.path = '',
    super.key,
  });
  final RuntimeController runtime;
  final String? root;
  final String path;
  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  List<Json>? items;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.runtime.call(
        widget.root == null ? 'documents.roots' : 'documents.list',
        widget.root == null ? {} : {'root': widget.root, 'path': widget.path},
      );
      if (mounted) {
        setState(() {
          items = (result as List).cast<Json>();
          error = null;
        });
      }
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
    }
  }

  Future<void> select(Json entry) async {
    if (widget.root == null || entry['directory'] == true) {
      final path = widget.root == null
          ? ''
          : [if (widget.path.isNotEmpty) widget.path, entry['name']].join('/');
      await Navigator.push(
        context,
        PocketRoute<void>(
          builder: (_) => FilesPage(
            runtime: widget.runtime,
            root: widget.root ?? entry['id'] as String,
            path: path,
          ),
        ),
      );
    } else {
      final path = [
        if (widget.path.isNotEmpty) widget.path,
        entry['name'],
      ].join('/');
      await Navigator.push(
        context,
        PocketRoute<void>(
          builder: (_) => TextFilePage(
            runtime: widget.runtime,
            root: widget.root!,
            path: path,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(widget.path.isEmpty ? '授权文件' : widget.path),
    bottom: widget.root != null
        ? null
        : PocketButton(
            glass: true,
            child: const Text('授权目录'),
            onPressed: () async {
              try {
                await RuntimeController.channel.invokeMethod<bool>(
                  'pickDirectory',
                );
                await load();
              } catch (exception) {
                if (mounted) setState(() => error = '$exception');
              }
            },
          ),
    body: PocketList(
      padding: const EdgeInsets.all(16),
      children: [
        if (error != null)
          PocketCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(error!),
            ),
          ),
        if (items == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (items?.isEmpty == true)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('这里还没有文件或授权目录。'),
          ),
        for (final entry in items ?? <Json>[])
          PocketTile(
            leading: Icon(
              widget.root == null || entry['directory'] == true
                  ? Icons.folder_outlined
                  : Icons.description_outlined,
            ),
            title: Text('${entry['name']}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => select(entry),
          ),
      ],
    ),
  );
}

class TextFilePage extends StatefulWidget {
  const TextFilePage({
    required this.runtime,
    required this.root,
    required this.path,
    super.key,
  });
  final RuntimeController runtime;
  final String root, path;
  @override
  State<TextFilePage> createState() => _TextFilePageState();
}

class _TextFilePageState extends State<TextFilePage> {
  String text = '', error = '';
  int offset = 0;
  bool more = false, loading = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final result = await widget.runtime.call('documents.read', {
        'root': widget.root,
        'path': widget.path,
        'offset': offset,
      }) as Json;
      if (mounted) {
        setState(() {
          text = result['text'] as String;
          offset = result['nextOffset'] as int;
          more = result['truncated'] == true;
          error = '';
        });
      }
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(widget.path),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        if (loading) const LinearProgressIndicator(),
        if (error.isNotEmpty) Text(error),
        SelectableText(text),
        if (more)
          PocketButton.tonal(
            onPressed: loading ? null : load,
            child: const Text('读取下一段'),
          ),
      ],
    ),
  );
}
