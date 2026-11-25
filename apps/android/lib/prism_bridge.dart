import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:prism_ui/switch.dart' as prism_switch;
import 'package:prism_ui/theme_data.dart' as prism;


/// Translates the app's Material color scheme into the scheme prism widgets
/// draw with.
///
/// prism_ui defines its own `ColorScheme` and `ThemeData` and imports no
/// Material library, so a prism subtree never inherits [material.ColorScheme].
/// Every role the app generates in `seededColorScheme` is copied across; roles
/// Material leaves null stay null and prism derives them from the seed.
///
/// @param scheme The Material scheme built by `pocketTheme`.
/// @returns The same palette as prism's own scheme type.
prism.ColorScheme prismColorSchemeOf(material.ColorScheme scheme) =>
    prism.ColorScheme(
      brightness: scheme.brightness,
      primary: scheme.primary,
      onPrimary: scheme.onPrimary,
      primaryContainer: scheme.primaryContainer,
      onPrimaryContainer: scheme.onPrimaryContainer,
      secondary: scheme.secondary,
      onSecondary: scheme.onSecondary,
      secondaryContainer: scheme.secondaryContainer,
      onSecondaryContainer: scheme.onSecondaryContainer,
      tertiary: scheme.tertiary,
      onTertiary: scheme.onTertiary,
      tertiaryContainer: scheme.tertiaryContainer,
      onTertiaryContainer: scheme.onTertiaryContainer,
      error: scheme.error,
      onError: scheme.onError,
      errorContainer: scheme.errorContainer,
      onErrorContainer: scheme.onErrorContainer,
      surface: scheme.surface,
      onSurface: scheme.onSurface,
      surfaceDim: scheme.surfaceDim,
      surfaceBright: scheme.surfaceBright,
      surfaceContainerLowest: scheme.surfaceContainerLowest,
      surfaceContainerLow: scheme.surfaceContainerLow,
      surfaceContainer: scheme.surfaceContainer,
      surfaceContainerHigh: scheme.surfaceContainerHigh,
      surfaceContainerHighest: scheme.surfaceContainerHighest,
      onSurfaceVariant: scheme.onSurfaceVariant,
      outline: scheme.outline,
      outlineVariant: scheme.outlineVariant,
      shadow: scheme.shadow,
      scrim: scheme.scrim,
      inverseSurface: scheme.inverseSurface,
      onInverseSurface: scheme.onInverseSurface,
      inversePrimary: scheme.inversePrimary,
      surfaceTint: scheme.surfaceTint,
    );

/// Installs prism's theme around [child] with the palette of the enclosing
/// Material theme, so package widgets match the rest of the app.
///
/// Place it at the point where the subtree stops using Material widgets, not at
/// the root: prism's `Theme` does not replace Material's, and wrapping the whole
/// app would rebuild prism consumers on every Material theme change.
class PocketPrismScope extends StatelessWidget {
  const PocketPrismScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final materialScheme = material.Theme.of(context).colorScheme;
    return prism.Theme(
      data: prism.ThemeData(
        colorScheme: prismColorSchemeOf(materialScheme),
        platform: defaultTargetPlatform,
      ),
      child: child,
    );
  }
}

/// A prism switch sized like the FlClash component it replaces.
///
/// The track is a fixed box and the lifted thumb is allowed to overflow it, so
/// a switch never grows the row it sits in — the same rule the adapted copy
/// followed before this moved to prism_ui.
class PocketSwitch extends StatelessWidget {
  const PocketSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  static const double trackWidth = prism_switch.Switch.trackWidth;
  static const double trackHeight = prism_switch.Switch.trackHeight;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: trackWidth,
    height: trackHeight,
    child: PocketPrismScope(
      child: OverflowBox(
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: prism_switch.Switch(
          value: value,
          onChanged: onChanged,
          semanticLabel: semanticLabel,
        ),
      ),
    ),
  );
}

/// A prism theme built from the app's own generator, for tests and for widgets
/// pumped outside the app tree.
///
/// @param scheme A Material scheme from `pocketTheme`.
/// @returns prism's theme carrying that palette.
prism.ThemeData prismThemeOf(material.ColorScheme scheme) =>
    prism.ThemeData(
      colorScheme: prismColorSchemeOf(scheme),
      platform: defaultTargetPlatform,
    );
