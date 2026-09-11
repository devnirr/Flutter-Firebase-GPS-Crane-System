import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../brand.dart';

/// A white card that floats over a map, as on the tracking and request screens.
class FloatingCard extends StatelessWidget {
  const FloatingCard({
    required this.child,
    this.padding = const EdgeInsets.all(Insets.lg),
    this.onTap,
    this.borderRadius = Corners.brLg,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    // The shadow goes on a DecoratedBox and the surface colour on a Material,
    // rather than both on the DecoratedBox. ListTile and InkWell paint their
    // splashes onto the nearest Material ancestor, so a *coloured* box between
    // them and it silently swallows every ripple — the card looks right and
    // nothing responds to touch.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: Shadows.floating,
      ),
      child: Material(
        color: BrandColors.white,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? Padding(padding: padding, child: child)
            : InkWell(
                onTap: onTap,
                child: Padding(padding: padding, child: child),
              ),
      ),
    );
  }
}

/// The bottom sheet that carries the primary action on most screens.
class BottomActionSheet extends StatelessWidget {
  const BottomActionSheet({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(
      Insets.gutter,
      Insets.xl,
      Insets.gutter,
      Insets.lg,
    ),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    // Same split as FloatingCard: shadow on the box, colour on the Material,
    // so anything ink-based dropped into a sheet still ripples.
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: Corners.sheet,
        boxShadow: Shadows.sheet,
      ),
      child: Material(
        color: BrandColors.white,
        borderRadius: Corners.sheet,
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A small uppercase label above a field or a value.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {this.color, super.key});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(context)
          .textTheme
          .labelSmall
          ?.copyWith(color: color ?? BrandColors.grey600),
    );
  }
}

/// Status pill. Colour encodes urgency so a dispatcher can scan a list without
/// reading it: red needs a human, amber is in flight, green is done.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {this.compact = false, this.label, super.key});

  final ServiceStatus status;
  final bool compact;

  /// Overrides the customer-facing [ServiceStatus.label], as the panel does
  /// with [ServiceStatus.officeLabel]. The colour still follows [status].
  final String? label;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = _colors;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? Insets.sm : Insets.md,
        vertical: compact ? 3 : Insets.xs,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brSm),
      child: Text(
        label ?? status.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }

  (Color, Color) get _colors => switch (status) {
        ServiceStatus.pendingDispatch ||
        ServiceStatus.offered =>
          (BrandColors.warning, BrandColors.warningTint),
        ServiceStatus.needsManual => (BrandColors.danger, BrandColors.dangerTint),
        ServiceStatus.accepted ||
        ServiceStatus.arrived ||
        ServiceStatus.inProgress =>
          (BrandColors.info, BrandColors.infoTint),
        ServiceStatus.completed ||
        ServiceStatus.closed =>
          (BrandColors.success, BrandColors.successTint),
        ServiceStatus.cancelled ||
        ServiceStatus.expired ||
        ServiceStatus.failed =>
          (BrandColors.grey600, BrandColors.grey100),
        ServiceStatus.unknown => (BrandColors.grey600, BrandColors.grey100),
      };
}

/// A labelled row of the kind used all over the service detail sheets.
class DetailRow extends StatelessWidget {
  const DetailRow({
    required this.label,
    required this.value,
    this.icon,
    this.valueColor,
    this.emphasise = false,
    super.key,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? valueColor;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: BrandColors.grey400),
            const SizedBox(width: Insets.md),
          ],
          Expanded(
            child: Text(label, style: text.bodyMedium?.copyWith(color: BrandColors.grey600)),
          ),
          const SizedBox(width: Insets.md),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: (emphasise ? text.titleMedium : text.bodyMedium)
                  ?.copyWith(color: valueColor ?? BrandColors.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// Two-line origin → destination block with the connector rail from the
/// mockups.
class RouteSummary extends StatelessWidget {
  const RouteSummary({
    required this.pickup,
    this.pickupReference = '',
    this.dropoff,
    super.key,
  });

  final String pickup;
  final String pickupReference;
  final String? dropoff;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            children: [
              const _Dot(color: BrandColors.red),
              if (dropoff != null) ...[
                Container(
                  width: 2,
                  height: 26,
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  color: BrandColors.grey200,
                ),
                const _Dot(color: BrandColors.ink, hollow: true),
              ],
            ],
          ),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pickup,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall,
              ),
              if (pickupReference.isNotEmpty)
                Text(
                  pickupReference,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
              if (dropoff != null) ...[
                const SizedBox(height: Insets.md),
                Text(
                  dropoff!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, this.hollow = false});

  final Color color;
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: hollow ? BrandColors.white : color,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2),
      ),
    );
  }
}

/// Full-screen empty / error state. Every failure in these apps gets one of
/// these rather than a bare spinner that never resolves.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.title,
    required this.message,
    this.icon = Icons.info_outline,
    this.actionLabel,
    this.onAction,
    this.tone = EmptyStateTone.neutral,
    super.key,
  });

  final String title;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EmptyStateTone tone;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (fg, bg) = switch (tone) {
      EmptyStateTone.neutral => (BrandColors.grey600, BrandColors.grey100),
      EmptyStateTone.error => (BrandColors.danger, BrandColors.dangerTint),
      EmptyStateTone.success => (BrandColors.success, BrandColors.successTint),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(icon, size: 34, color: fg),
            ),
            const SizedBox(height: Insets.xl),
            Text(title, textAlign: TextAlign.center, style: text.titleLarge),
            const SizedBox(height: Insets.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Insets.xxl),
              SizedBox(
                width: 220,
                child: ElevatedButton(onPressed: onAction, child: Text(actionLabel!)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum EmptyStateTone { neutral, error, success }

/// Branded loading indicator. Deliberately small and centred — a full-screen
/// red spinner reads as an alarm in this palette.
class BrandLoader extends StatelessWidget {
  const BrandLoader({this.message, super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          if (message != null) ...[
            const SizedBox(height: Insets.lg),
            Text(
              message!,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: BrandColors.grey600),
            ),
          ],
        ],
      ),
    );
  }
}

/// The red header used on the driver and auth screens.
class BrandHeader extends StatelessWidget {
  const BrandHeader({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.height = 160,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final double height;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      height: height,
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [BrandColors.redBright, BrandColors.redDark],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
          child: Column(
            children: [
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    ?leading,
                    const Spacer(),
                    ?trailing,
                  ],
                ),
              ),
              const Spacer(),
              Text(
                title.toUpperCase(),
                textAlign: TextAlign.center,
                style: text.headlineMedium?.copyWith(color: BrandColors.white),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: Text(
                    subtitle!,
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: Colors.white70),
                  ),
                ),
              const SizedBox(height: Insets.xl),
            ],
          ),
        ),
      ),
    );
  }
}

/// A destructive or cautionary inline banner.
class InlineNotice extends StatelessWidget {
  const InlineNotice({
    required this.message,
    this.icon = Icons.warning_amber_rounded,
    this.tone = NoticeTone.warning,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String message;
  final IconData icon;
  final NoticeTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = switch (tone) {
      NoticeTone.warning => (BrandColors.warning, BrandColors.warningTint),
      NoticeTone.error => (BrandColors.danger, BrandColors.dangerTint),
      NoticeTone.info => (BrandColors.info, BrandColors.infoTint),
      NoticeTone.success => (BrandColors.success, BrandColors.successTint),
    };

    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(color: bg, borderRadius: Corners.brSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: BrandColors.grey800),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(foregroundColor: fg),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

enum NoticeTone { warning, error, info, success }
