import 'package:flutter/material.dart';
import 'package:grua_core/grua_core.dart';

/// The pieces every create / edit form in the panel is built from, so the
/// chofer, grúa and aseguradora forms look and behave the same.

/// Icon, title, subtitle and the close button across the top of a form dialog.
class FormDialogHeader extends StatelessWidget {
  const FormDialogHeader({
    required this.title,
    required this.subtitle,
    required this.onClose,
    this.icon,
    super.key,
  });

  final String title;
  final String subtitle;

  /// Shown in a tinted square to the left of the title. What the form is
  /// about, at a glance, on a screen where several dialogs look alike.
  final IconData? icon;

  /// Null while submitting: closing mid-save would hide the outcome.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        Insets.xxl,
        Insets.xl,
        Insets.lg,
        Insets.lg,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(bottom: BorderSide(color: palette.border)),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Corners.lg),
        ),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: palette.brandTint,
                borderRadius: Corners.brSm,
              ),
              child: Icon(icon, size: 20, color: palette.brand),
            ),
            const SizedBox(width: Insets.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleLarge),
                const SizedBox(height: Insets.xxs),
                Text(
                  subtitle,
                  style: text.bodySmall?.copyWith(color: palette.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Cerrar',
          ),
        ],
      ),
    );
  }
}

/// Cancelar and the primary action, with a spinner while it runs. [note] sits
/// on the left — what the asterisks mean, or what pressing the button will do.
class FormDialogFooter extends StatelessWidget {
  const FormDialogFooter({
    required this.submitting,
    required this.label,
    required this.onCancel,
    required this.onSubmit,
    this.note,
    super.key,
  });

  final bool submitting;
  final String label;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(top: BorderSide(color: palette.border)),
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(Corners.lg),
        ),
      ),
      child: Row(
        children: [
          if (note != null)
            Expanded(
              child: Text(
                note!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: palette.textMuted),
              ),
            )
          else
            const Spacer(),
          TextButton(
            onPressed: submitting ? null : onCancel,
            child: const Text('Cancelar'),
          ),
          const SizedBox(width: Insets.sm),
          ElevatedButton(
            onPressed: submitting ? null : onSubmit,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
            ),
            child: submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: BrandColors.white,
                    ),
                  )
                : Text(label),
          ),
        ],
      ),
    );
  }
}

/// An uppercase section title with a rule running to the edge, and an optional
/// line under it saying what the section is for.
class FormSection extends StatelessWidget {
  const FormSection(this.title, {this.note, super.key});

  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FieldLabel(title.toUpperCase()),
              const SizedBox(width: Insets.sm),
              Expanded(child: Divider(color: palette.border)),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: Insets.xs),
            Text(
              note!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: palette.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// One labelled row: the asterisk, the field, and the note under it.
class LabeledField extends StatelessWidget {
  const LabeledField({
    required this.label,
    required this.child,
    this.required = false,
    this.help,
    super.key,
  });

  final String label;
  final Widget child;
  final bool required;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              text: label,
              style: text.labelMedium?.copyWith(color: palette.textStrong),
              children: [
                if (required)
                  TextSpan(
                    text: ' *',
                    style: TextStyle(color: palette.brand),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Insets.xs),
          child,
          if (help != null) ...[
            const SizedBox(height: Insets.xxs),
            Text(
              help!,
              style: text.bodySmall?.copyWith(color: palette.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Two or three fields side by side, stacked when the dialog is too narrow
/// for them.
class FormRow extends StatelessWidget {
  const FormRow({
    required this.left,
    required this.right,
    this.third,
    super.key,
  });

  final Widget left;
  final Widget right;

  /// A third field on the same line, for short ones like a year or a colour.
  final Widget? third;

  /// Below this the two fields would be too cramped to type a company name in.
  static const _stackUnder = 460.0;

  /// A third field takes a third of the line, so the line has to be wider
  /// before any of them is still worth typing in.
  static const _stackThreeUnder = 640.0;

  @override
  Widget build(BuildContext context) {
    final fields = [left, right, ?third];

    return LayoutBuilder(
      builder: (context, constraints) {
        final stackUnder = third == null ? _stackUnder : _stackThreeUnder;
        if (constraints.maxWidth < stackUnder) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: fields,
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (index, field) in fields.indexed) ...[
              if (index > 0) const SizedBox(width: Insets.lg),
              Expanded(child: field),
            ],
          ],
        );
      },
    );
  }
}

/// A tappable date, flagged when it is under a month away.
///
/// Every date these forms ask for is an expiry, and under a month left is
/// worth flagging at data entry: the expiry sweep acts on it almost at once.
class DateField extends StatelessWidget {
  const DateField({
    required this.value,
    required this.onPick,
    this.error,
    super.key,
  });

  final DateTime? value;
  final Future<void> Function() onPick;

  /// Reported like a validator's message, so a date left empty reads the same
  /// as any other required field rather than only as a line by the button.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final expiry = value;
    final soon = expiry != null &&
        expiry.difference(DateTime.now()).inDays <= 30;

    return InkWell(
      onTap: onPick,
      borderRadius: Corners.brSm,
      child: InputDecorator(
        decoration: InputDecoration(
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
          errorText: error ?? (soon ? 'Vence en menos de 30 días.' : null),
          errorStyle: TextStyle(
            color: error != null ? palette.danger : palette.warning,
          ),
        ),
        child: Text(
          expiry == null ? 'dd/mm/aaaa' : DoTime.fullDate(expiry),
          style: text.bodyMedium?.copyWith(
            color: expiry == null ? palette.textFaint : palette.text,
          ),
        ),
      ),
    );
  }
}
