import 'package:material_ui/material_ui.dart';
import 'package:prism_ui/liquid_glass.dart';

import 'design/color.dart';

/// This app's glass looks, expressed on prism_ui's style type.
///
/// prism_ui draws the pane, captures the backdrop and runs the shader; these
/// factories keep the numbers this app shipped, so the drawing code can come
/// from the package without the glass changing how it looks.
abstract final class PocketGlass {
  /// How far a dark pane's tint sits above the card tone it floats over.
  static const double _darkTintOverCard = 7.0;
  static final Map<Color, Color> _darkTints = <Color, Color>{};

  /// The dark pane's tint: the card tone lifted, so glass reads over content.
  ///
  /// @param colorScheme The surrounding Material scheme.
  /// @returns The tint color for a dark pane's style.
  static Color _darkTint(ColorScheme colorScheme) {
    final card = colorScheme.surfaceContainer;
    if (_darkTints.length > 8) _darkTints.clear();
    return _darkTints.putIfAbsent(
      card,
      () => card.shiftTone(_darkTintOverCard),
    );
  }

  /// The everyday pane behind headers, docks and cards.
  static LiquidGlassStyle regular(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    return dark
        ? LiquidGlassStyle(
            tint: _darkTint(colorScheme).withValues(alpha: 0.58),
            contrast: -0.4,
            blur: 8,
            saturation: 1.35,
            rim: 0.38,
            rimWidth: 1.4,
            rimTail: 0.17,
            rimFocus: 1,
            rimAdded: 0.38,
            hairlineSide: 0.48,
          )
        : const LiquidGlassStyle(
            tint: Color(0x9EFDFCF7),
            contrast: 0.4,
            blur: 8,
            saturation: 1.25,
            rim: 0.48,
            rimWidth: 1.4,
            rimTail: 0.17,
            rimFocus: 1,
            rimAdded: 0.38,
            hairline: 0.14,
            hairlineSide: 0.38,
          );
  }

  /// A capsule, hazed rather than blurred so a moving pill stays steady.
  static LiquidGlassStyle pill(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    return dark
        ? LiquidGlassStyle(
            tint: _darkTint(colorScheme).withValues(alpha: 0.48),
            contrast: -0.4,
            blur: 0,
            haze: 0.72,
            hazeBlur: 15.6,
            saturation: 1.35,
            rim: 0.42,
          )
        : const LiquidGlassStyle(
            tint: Color(0x9EF7F6EF),
            contrast: 0.4,
            blur: 0,
            haze: 0.72,
            hazeBlur: 15.6,
            saturation: 1.25,
            rim: 0.48,
            hairline: 0.2,
          );
  }

  /// Thicker than [regular], for rows that read over anything.
  static LiquidGlassStyle menu(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    return dark
        ? LiquidGlassStyle(
            tint: _darkTint(colorScheme).withValues(alpha: 0.63),
            contrast: -0.53,
            blur: 12,
            saturation: 1.75,
            brightness: 1.8,
            rim: 0,
          )
        : LiquidGlassStyle(
            tint: colorScheme.surfaceBright.withValues(alpha: 0.55),
            blur: 12,
            saturation: 2,
            brightness: 1.1,
            rim: 0,
          );
  }

  /// A menu pane with a wider blur, for alerts that cover more content.
  static LiquidGlassStyle alert(ColorScheme colorScheme) =>
      menu(colorScheme).copyWith(blur: 16);

  /// A control filled with its own color, glowing rather than refracting.
  static LiquidGlassStyle tinted(ColorScheme colorScheme, Color color) {
    final dark = colorScheme.brightness == Brightness.dark;
    return LiquidGlassStyle(
      tint: color.withValues(alpha: 0.82),
      saturation: 1.2,
      // A primary tint masks the neutral pane's edge at normal phone scale.
      // Keep its face (and onPrimary contrast) unchanged; light a narrow bevel
      // and let the highlight reach the rounded ends without whitening them.
      rim: dark ? 0.52 : 0.42,
      rimWidth: 1.5,
      rimTail: 0.23,
      rimFocus: 0.72,
      rimAdded: 0.16,
      hairline: dark ? 0.12 : 0.26,
      hairlineSide: dark ? 0.48 : 0.42,
    );
  }

  /// A raised lens: it bends the backdrop outward around its rim.
  static LiquidGlassStyle lens(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    return LiquidGlassStyle(
      tint: Colors.transparent,
      blur: 0,
      refraction: -4.3,
      bevel: 5.5,
      saturation: 1,
      brightness: dark ? 1.33 : 1,
      rim: dark ? 0.3 : 0.6,
      rimWidth: 1.1,
      endShade: 0.045,
      dispersion: 6.5,
      rimBlur: 1.5,
      hairline: 0.42,
    );
  }

  /// A sunken lens, for content that sits below the pane's face.
  static LiquidGlassStyle lensContent(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    return LiquidGlassStyle(
      tint: Colors.transparent,
      blur: 0,
      refraction: 14,
      bevel: 11.2,
      saturation: 1,
      brightness: dark ? 1.33 : 1,
      rim: 0,
      dispersion: 3.6,
      rimBlur: 2.5,
    );
  }

  /// The rim a menu's or an alert's pane keeps along its edge.
  static LiquidGlassRim rimMenu(ColorScheme colorScheme) =>
      colorScheme.brightness == Brightness.dark
      ? const LiquidGlassRim(side: 0.27, corner: 0.1, flat: 0.02, shine: 0.22)
      : const LiquidGlassRim(side: 0.25, corner: 0.15, flat: 0.09, shine: 0.16);

  /// The rim of an alert, which lights its sides more than a menu does.
  static LiquidGlassRim rimAlert(ColorScheme colorScheme) =>
      colorScheme.brightness == Brightness.dark
      ? const LiquidGlassRim(side: 0.75, corner: 0.1, flat: 0.03, shine: 0.22)
      : const LiquidGlassRim(side: 0.35, corner: 0.22, flat: 0.12, shine: 0.16);
}

/// An iOS 27 menu's or alert's shadow, measured over white below, above and
/// beside it: one wide shadow, glass or not.
///
/// @param colorScheme The surrounding Material scheme.
/// @param depth A multiplier for how far the surface is lifted.
/// @returns The shadows to paint under the pane.
List<BoxShadow> menuShadows(ColorScheme colorScheme, [double depth = 1]) {
  final strength = colorScheme.brightness == Brightness.dark ? 1.5 : 1.0;
  return [
    BoxShadow(
      color: colorScheme.shadow.withValues(alpha: 0.118 * strength * depth),
      blurRadius: 29,
      offset: const Offset(0, 8),
    ),
  ];
}

/// A button whose background is a glass pane, choosing its style per state.
///
/// prism_ui has no equivalent helper: its buttons take a `backgroundBuilder`
/// and this app's Material buttons take a `ButtonStyle`.
///
/// @param styleOf The pane style for the button's current states.
/// @returns The style to hand a filled, tonal or icon button.
ButtonStyle glassButtonStyle(
  LiquidGlassStyle Function(Set<WidgetState> states) styleOf,
) => ButtonStyle(
  backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
  backgroundBuilder: (context, states, child) => LiquidGlass(
    style: styleOf(states),
    pressed: states.contains(WidgetState.pressed),
    child: child,
  ),
);

/// A copy of [style] with a few fields replaced.
///
/// prism_ui's own `copyWith` only takes the two blur values, and an extension
/// cannot shadow a member, so this fills every other field explicitly.
///
/// @param style The style to copy.
/// @param rim A new rim strength, when it differs.
/// @param rimWidth A new rim width, when it differs.
/// @param hairline A new hairline, when it differs.
/// @param hairlineSide A new side hairline, when it differs.
/// @returns The copied style.
LiquidGlassStyle glassStyleWith(
  LiquidGlassStyle style, {
  double? rim,
  double? rimWidth,
  double? hairline,
  double? hairlineSide,
}) => LiquidGlassStyle(
  tint: style.tint,
  contrast: style.contrast,
  blur: style.blur,
  haze: style.haze,
  hazeBlur: style.hazeBlur,
  refraction: style.refraction,
  bevel: style.bevel,
  saturation: style.saturation,
  brightness: style.brightness,
  rim: rim ?? style.rim,
  rimWidth: rimWidth ?? style.rimWidth,
  rimTail: style.rimTail,
  rimFocus: style.rimFocus,
  rimAdded: style.rimAdded,
  endShade: style.endShade,
  dispersion: style.dispersion,
  rimBlur: style.rimBlur,
  hairline: hairline ?? style.hairline,
  hairlineSide: hairlineSide ?? style.hairlineSide,
);
