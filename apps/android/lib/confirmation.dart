import 'package:material_ui/material_ui.dart';

import 'entry_motion.dart';
import 'ui.dart';

/// Keeps an editor mounted while a confirmation owns input and accessibility.
class PocketConfirmationLayer extends StatelessWidget {
  const PocketConfirmationLayer({
    super.key,
    required this.child,
    this.confirmation,
  });
  final Widget child;
  final PocketConfirmation? confirmation;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      ExcludeSemantics(
        excluding: confirmation != null,
        child: ExcludeFocus(
          excluding: confirmation != null,
          child: IgnorePointer(ignoring: confirmation != null, child: child),
        ),
      ),
      if (confirmation != null) Positioned.fill(child: confirmation!),
    ],
  );
}

/// Shared two-choice alert. It never performs an operation or dismisses itself;
/// the owning flow retains its busy state, validation and mutation policy.
class PocketConfirmation extends StatelessWidget {
  const PocketConfirmation({
    super.key,
    required this.title,
    required this.message,
    required this.secondaryLabel,
    required this.onSecondary,
    required this.primaryLabel,
    required this.onPrimary,
    this.scrollKey,
  });
  final String title, message, secondaryLabel, primaryLabel;
  final VoidCallback? onSecondary, onPrimary;
  final Key? scrollKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final panel = Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              const style = TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              );
              double labelWidth(String label) {
                final painter = TextPainter(
                  text: TextSpan(
                    text: label,
                    style: Theme.of(context).textTheme.labelLarge?.merge(style),
                  ),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout();
                final width = painter.width;
                painter.dispose();
                return width;
              }

              final secondary = PocketButton.tonal(
                onPressed: onSecondary,
                child: Text(
                  secondaryLabel,
                  style: style,
                  textAlign: TextAlign.center,
                ),
              );
              final primary = PocketButton(
                onPressed: onPrimary,
                child: Text(
                  primaryLabel,
                  style: style,
                  textAlign: TextAlign.center,
                ),
              );
              // Keep equal horizontal actions whenever labels fit; large type
              // can use two full-width rows instead of clipping or shrinking.
              final available = (constraints.maxWidth - 8) / 2 - 28;
              if (labelWidth(secondaryLabel) > available ||
                  labelWidth(primaryLabel) > available) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [secondary, primary],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: secondary),
                  const SizedBox(width: 8),
                  Expanded(child: primary),
                ],
              );
            },
          ),
        ],
      ),
    );
    return Stack(
      children: [
        const Positioned.fill(
          child: ModalBarrier(color: Color(0x55000000), dismissible: false),
        ),
        Positioned.fill(
          child: Padding(
            padding: MediaQuery.viewInsetsOf(context),
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  key: scrollKey,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Semantics(
                            scopesRoute: true,
                            namesRoute: true,
                            label: title,
                            explicitChildNodes: true,
                            child: FocusScope(
                              autofocus: true,
                              child: PocketReveal(
                                child: LiquidGlassScope.of(context)
                                    ? LiquidGlass(
                                        style: LiquidGlassStyle.alert(colors)
                                            .copyWith(rim: .18, hairline: .25),
                                        borderRadius: BorderRadius.circular(30),
                                        child: panel,
                                      )
                                    : GlassSurface(child: panel),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
