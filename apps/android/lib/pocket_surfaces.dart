import 'package:material_ui/material_ui.dart';
import 'package:prism_ui/surface.dart';

import 'prism_bridge.dart';

export 'package:prism_ui/surface.dart' hide AppSurfaceThemeExt;

/// The surface a floating panel sits on, in this app's palette.
///
/// prism's `SurfaceLevel.floatingOf` reads prism's own `ColorScheme`; this app
/// builds its colors from Material's, so the two are bridged here.
///
/// @param scheme The surrounding Material scheme.
/// @returns The level a menu, sheet or dialog sits at.
SurfaceLevel pocketFloatingOf(ColorScheme scheme) =>
    SurfaceLevel.floatingOf(prismColorSchemeOf(scheme));

/// Reads a surface level's color from this app's Material scheme.
extension PocketSurfaceLevelColor on SurfaceLevel {
  /// @param scheme The surrounding Material scheme.
  /// @returns The color this level paints on a page.
  Color colorOfMaterial(ColorScheme scheme) => colorOf(prismColorSchemeOf(scheme));
}

/// Applies the surface roles to the Material theme this app builds.
extension PocketSurfaces on ThemeData {
  /// The theme with every Material surface role filled from this app's levels.
  ThemeData get withAppSurfaces {
    final scheme = prismColorSchemeOf(colorScheme);
    final page = SurfaceLevel.page.colorOf(scheme);
    final card = SurfaceLevel.card.colorOf(scheme);
    final floatingLevel = SurfaceLevel.floatingOf(scheme);
    final floating = floatingLevel.colorOf(scheme);
    final ring = focusRingStyle(colorScheme);
    final standingRing = focusRingStyle(colorScheme, standsOff: true);
    return copyWith(
      dividerTheme: dividerTheme.copyWith(
        color: colorScheme.onSurface.withValues(alpha: 0.14),
      ),
      scaffoldBackgroundColor: page,
      cardTheme: cardTheme.copyWith(color: card, elevation: 0),
      dialogTheme: dialogTheme.copyWith(backgroundColor: floating),
      popupMenuTheme: popupMenuTheme.copyWith(color: floating),
      menuTheme: MenuThemeData(
        style: (menuTheme.style ?? const MenuStyle()).copyWith(
          backgroundColor: WidgetStatePropertyAll(floating),
        ),
      ),
      navigationBarTheme: navigationBarTheme.copyWith(
        backgroundColor: floating,
        indicatorColor: floatingLevel.next.colorOf(scheme),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      bottomSheetTheme: bottomSheetTheme.copyWith(
        backgroundColor: page,
        modalBackgroundColor: page,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: standingRing.merge(filledButtonTheme.style),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ring.merge(textButtonTheme.style),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ring.merge(outlinedButtonTheme.style),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ring.merge(iconButtonTheme.style),
      ),
    );
  }
}

const _focusRingWidth = 2.0;
const _focusRingGap = 1.0;

/// The focus ring of `.agents/surfaces.md`; one that [standsOff] clears the
/// edge, which a primary fill or a button's own glass would hide it on.
///
/// @param colorScheme The surrounding Material scheme.
/// @param standsOff Whether the ring clears the edge instead of sitting on it.
/// @returns The border side to paint while focus is in the control.
BorderSide focusRingSide(ColorScheme colorScheme, {bool standsOff = false}) =>
    BorderSide(
      color: colorScheme.primary,
      width: _focusRingWidth,
      strokeAlign: standsOff
          ? 1 + 2 * _focusRingGap / _focusRingWidth
          : BorderSide.strokeAlignInside,
    );

/// [focusRingSide] as the side a button paints while focused.
///
/// @param colorScheme The surrounding Material scheme.
/// @param standsOff Whether the ring clears the edge instead of sitting on it.
/// @returns A button style that only supplies the focused side.
ButtonStyle focusRingStyle(ColorScheme colorScheme, {bool standsOff = false}) =>
    ButtonStyle(
      side: WidgetStateProperty<BorderSide?>.fromMap({
        WidgetState.focused: focusRingSide(colorScheme, standsOff: standsOff),
      }),
    );
