import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'browser_url.dart';
import 'runtime.dart';
import 'ui.dart';

/// Address entry and this page's history. AndroidX Custom Tabs owns page
/// navigation and network loading, so remote content never enters App WebView.
class SessionBrowserPage extends StatefulWidget {
  const SessionBrowserPage({super.key, required this.runtime, this.initialUrl});
  final RuntimeController runtime;
  final String? initialUrl;

  @override
  State<SessionBrowserPage> createState() => _SessionBrowserPageState();
}

class _SessionBrowserPageState extends State<SessionBrowserPage> {
  static const _channel = MethodChannel('dsh/runtime');
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  final _opened = <Uri>[];
  String? _error;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _address.text = widget.initialUrl ?? '';
    if (widget.initialUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(widget.initialUrl!);
      });
    }
  }

  @override
  void didUpdateWidget(SessionBrowserPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialUrl != null &&
        widget.initialUrl != oldWidget.initialUrl) {
      _address.text = widget.initialUrl!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(widget.initialUrl!);
      });
    }
  }

  Future<void> _open(String text) async {
    final address = browserAddress(
      text,
      BrowserLocalOrigin.fromRuntime(widget.runtime),
    );
    if (address == null) {
      setState(() => _error = '请输入有效的远程网页地址。');
      return;
    }
    _addressFocus.unfocus();
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      // Native repeats the address policy; this call cannot load App WebView.
      await _channel.invokeMethod<void>('browser.open', address.toString());
      if (!mounted) return;
      setState(() {
        _address.text = address.toString();
        _opened.remove(address);
        _opened.insert(0, address);
        if (_opened.length > 30) _opened.removeLast();
      });
    } on PlatformException catch (failure) {
      if (mounted) setState(() => _error = failure.message ?? '无法打开网页。');
    } on MissingPluginException {
      if (mounted) setState(() => _error = '当前设备不支持打开网页。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final header = (MediaQuery.textScalerOf(context).scale(17) * 2.4).clamp(
      52.0,
      120.0,
    );
    return PocketScaffold(
      title: const Text('浏览器'),
      body: Column(
        children: [
          SizedBox(height: safe.top + header + 30),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: GlassSurface(
              radius: 26,
              child: Row(
                children: [
                  const SizedBox(width: 18),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('browser-address'),
                      controller: _address,
                      focusNode: _addressFocus,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        hintText: '输入网址',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      onSubmitted: _open,
                    ),
                  ),
                  GlassButton(
                    icon: Icons.open_in_new_rounded,
                    label: '打开网址',
                    onPressed: _opening ? null : () => _open(_address.text),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          if (_opening) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _opened.isEmpty
                ? const Center(child: Text('输入网址，在浏览器中打开'))
                : ListView.builder(
                    key: const ValueKey('browser-history'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 18,
                    ),
                    itemCount: _opened.length,
                    itemBuilder: (context, index) {
                      final address = _opened[index];
                      return PocketRow(
                        key: ValueKey('browser-history-$index'),
                        icon: Icons.public_rounded,
                        title: address.host,
                        subtitle: address.toString(),
                        onTap: _opening
                            ? null
                            : () => _open(address.toString()),
                      );
                    },
                  ),
          ),
          SizedBox(height: safe.bottom),
        ],
      ),
    );
  }
}
