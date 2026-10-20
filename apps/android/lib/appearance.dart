import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'flclash/color.dart';
import 'runtime.dart';
import 'ui.dart';

/// App-local preferences work even when the Agent service cannot start.
class AppearanceController extends ChangeNotifier {
  ThemeMode mode = ThemeMode.system;
  ColorStyle style = ColorStyle.soft;
  int seed = 0xff556f63;
  bool dynamicColor = false, pureBlack = false, reduceMotion = false;
  String glass = 'ultra';
  double textScale = 0;
  bool saving = false;
  String? error;
  bool get glassEnabled => glass != 'none';
  LiquidGlassQuality get quality => glass == 'standard'
      ? LiquidGlassQuality.standard
      : LiquidGlassQuality.ultra;
  Json get value => {
    'mode': mode.name,
    'style': style.name,
    'seed': seed,
    'dynamicColor': dynamicColor,
    'pureBlack': pureBlack,
    'reduceMotion': reduceMotion,
    'glass': glass,
    'textScale': textScale,
  };
  void _accept(Json data) {
    mode = ThemeMode.values.firstWhere(
      (item) => item.name == data['mode'],
      orElse: () => ThemeMode.system,
    );
    style = ColorStyle.values.firstWhere(
      (item) => item.name == data['style'],
      orElse: () => ColorStyle.soft,
    );
    seed = data['seed'] as int? ?? 0xff556f63;
    dynamicColor = data['dynamicColor'] == true;
    pureBlack = data['pureBlack'] == true;
    reduceMotion = data['reduceMotion'] == true;
    glass = ['none', 'standard', 'ultra'].contains(data['glass'])
        ? data['glass'] as String
        : 'ultra';
    textScale = (data['textScale'] as num? ?? 0).toDouble();
  }

  Future<void> load() async {
    try {
      final raw = await RuntimeController.channel.invokeMethod<String>(
        'appearance.load',
      );
      if (raw != null) _accept(jsonDecode(raw) as Json);
    } catch (exception) {
      error = '无法读取主题设置：$exception';
    }
    notifyListeners();
  }

  Future<void> update(Json patch) async {
    if (saving) return;
    saving = true;
    error = null;
    notifyListeners();
    final next = {...value, ...patch};
    try {
      await RuntimeController.channel.invokeMethod<void>(
        'appearance.save',
        jsonEncode(next),
      );
      _accept(next);
    } catch (exception) {
      error = '主题设置未保存：$exception';
    } finally {
      saving = false;
      notifyListeners();
    }
  }
}

class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    required AppearanceController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
  static AppearanceController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()!.notifier!;
}

class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});
  @override
  Widget build(BuildContext context) {
    final settings = AppearanceScope.of(context);
    final colors = Theme.of(context).colorScheme;
    void update(Json patch) {
      settings.update(patch);
    }

    return PocketScaffold(
      title: const Text('外观与主题'),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          // The preview uses the same glass and color components as the conversation page.
          Container(
            constraints: const BoxConstraints(minHeight: 174),
            padding: const EdgeInsets.all(22),
            margin: const EdgeInsets.only(bottom: 28),
            clipBehavior: Clip.antiAlias,
            decoration: ShapeDecoration(
              shape: AppShape.xxl,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colors.primaryContainer,
                  colors.surface,
                  colors.secondaryContainer,
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const PocketMark(size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Pocket Harness',
                        style: TextStyle(
                          fontSize: 16,
                          color: colors.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    GlassButton(
                      icon: Icons.more_horiz,
                      label: '效果预览',
                      onPressed: () {},
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                GlassSurface(
                  radius: 22,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '按住右上按钮，拖动试试',
                            style: TextStyle(fontSize: 14),
                          ),
                        ),
                        Icon(Icons.arrow_upward_rounded, color: colors.primary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          PocketSection(
            title: '显示模式',
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: double.infinity,
                  child: IgnorePointer(
                    ignoring: settings.saving,
                    child: SegmentedControl<ThemeMode>(
                      segments: const [
                        (ThemeMode.system, '系统'),
                        (ThemeMode.light, '浅色'),
                        (ThemeMode.dark, '深色'),
                      ],
                      value: settings.mode,
                      onChanged: (value) => update({'mode': value.name}),
                    ),
                  ),
                ),
              ),
              PocketSwitchRow(
                title: const Text('纯黑背景', style: TextStyle(fontSize: 16)),
                subtitle: const Text(
                  '在深色模式下使用',
                  style: TextStyle(fontSize: 12),
                ),
                value: settings.pureBlack,
                onChanged: settings.saving
                    ? null
                    : (value) => update({'pureBlack': value}),
              ),
            ],
          ),
          PocketSection(
            title: '主题色',
            children: [
              PocketSwitchRow(
                title: const Text('使用系统配色', style: TextStyle(fontSize: 16)),
                subtitle: const Text(
                  '支持时跟随壁纸颜色，否则使用所选主题色',
                  style: TextStyle(fontSize: 12),
                ),
                value: settings.dynamicColor,
                onChanged: settings.saving
                    ? null
                    : (value) => update({'dynamicColor': value}),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final color in const [
                      0xff556f63,
                      0xff4268b3,
                      0xff8353a4,
                      0xffbe6b7b,
                      0xffad6a30,
                      0xff52646f,
                    ])
                      Semantics(
                        selected:
                            !settings.dynamicColor && settings.seed == color,
                        button: true,
                        label: '主题色 ${color.toRadixString(16)}',
                        child: PocketSwatch(
                          color: Color(color),
                          selected:
                              !settings.dynamicColor && settings.seed == color,
                          onTap: settings.saving
                              ? null
                              : () => update({
                                  'seed': color,
                                  'dynamicColor': false,
                                }),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in const {
                      ColorStyle.vivid: '鲜明',
                      ColorStyle.tinted: '染色',
                      ColorStyle.soft: '柔和',
                      ColorStyle.monochrome: '单色',
                    }.entries)
                      PocketChoice(
                        label: Text(entry.value),
                        selected: settings.style == entry.key,
                        onSelected: settings.saving
                            ? null
                            : (_) => update({'style': entry.key.name}),
                      ),
                  ],
                ),
              ),
            ],
          ),
          PocketSection(
            title: '液态玻璃',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: IgnorePointer(
                    ignoring: settings.saving,
                    child: SegmentedControl<String>(
                      segments: const [
                        ('none', '关闭'),
                        ('standard', '标准'),
                        ('ultra', '精细'),
                      ],
                      value: settings.glass,
                      onChanged: (value) => update({'glass': value}),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: Text(
                  '用于顶部按钮与输入栏。精细模式增加玻璃边缘与折射细节。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          PocketSection(
            title: '文字与动效',
            children: [
              PocketSwitchRow(
                title: const Text('减少动画', style: TextStyle(fontSize: 16)),
                subtitle: const Text(
                  '系统开启减少动画时始终生效',
                  style: TextStyle(fontSize: 12),
                ),
                value: settings.reduceMotion,
                onChanged: settings.saving
                    ? null
                    : (value) => update({'reduceMotion': value}),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in {
                      0.0: '系统字号',
                      .9: '小',
                      1.0: '标准',
                      1.15: '大',
                      1.3: '特大',
                    }.entries)
                      PocketChoice(
                        label: Text(entry.value),
                        selected: settings.textScale == entry.key,
                        onSelected: settings.saving
                            ? null
                            : (_) => update({'textScale': entry.key}),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (settings.error != null)
            SelectableText(
              settings.error!,
              style: TextStyle(color: colors.error),
            ),
        ],
      ),
    );
  }
}
