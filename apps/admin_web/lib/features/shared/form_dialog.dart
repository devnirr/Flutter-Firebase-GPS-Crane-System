import 'package:flutter/material.dart';
import 'package:grua_core/grua_core.dart';

/// The pieces every create / edit form in the panel is built from, so the
/// chofer and grúa forms look and behave the same.

/// Title, subtitle and the close button across the top of a form dialog.
class FormDialogHeader extends StatelessWidget {
  const FormDialogHeader({
    required this.title,
    required this.subtitle,
    required this.onClose,
    super.key,
  });

  final String title;
  final String subtitle;

  /// Null while submitting: closing mid-save would hide the outcome.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(Insets.xxl, Insets.xl, Insets.lg, Insets.lg),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: BrandColors.grey200)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleLarge),
                const SizedBox(height: Insets.xxs),
                Text(
                  subtitle,
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
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

/// Cancelar and the primary action, with a spinner while it runs.
class FormDialogFooter extends StatelessWidget {
  const FormDialogFooter({
    required this.submitting,
    required this.label,
    required this.onCancel,
    required this.onSubmit,
    super.key,
  });

  final bool submitting;
  final String label;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: const BoxDecoration(
        color: BrandColors.offWhite,
        border: Border(top: BorderSide(color: BrandColors.grey200)),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(Corners.md)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
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

/// An uppercase section title with a rule running to the edge.
class FormSection extends StatelessWidget {
  const FormSection(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Row(
        children: [
          FieldLabel(title.toUpperCase()),
          const SizedBox(width: Insets.sm),
          const Expanded(child: Divider(color: BrandColors.grey200)),
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

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              text: label,
              style: text.labelMedium?.copyWith(color: BrandColors.grey800),
              children: [
                if (required)
                  const TextSpan(
                    text: ' *',
                    style: TextStyle(color: BrandColors.red),
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
              style: text.bodySmall?.copyWith(color: BrandColors.grey600),
            ),
          ],
        ],
      ),
    );
  }
}

/// A tappable date, flagged when it is under a month away.
///
/// Every date these forms ask for is an expiry, and under a month left is
/// worth flagging at data entry: the expiry sweep acts on it almost at once.
class DateField extends StatelessWidget {
  const DateField({required this.value, required this.onPick, super.key});

  final DateTime? value;
  final Future<void> Function() onPick;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final expiry = value;
    final soon = expiry != null &&
        expiry.difference(DateTime.now()).inDays <= 30;

    return InkWell(
      onTap: onPick,
      borderRadius: Corners.brSm,
      child: InputDecorator(
        decoration: InputDecoration(
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
          errorText: soon ? 'Vence en menos de 30 días.' : null,
          errorStyle: const TextStyle(color: BrandColors.warning),
        ),
        child: Text(
          expiry == null ? 'dd/mm/aaaa' : DoTime.fullDate(expiry),
          style: text.bodyMedium?.copyWith(
            color: expiry == null ? BrandColors.grey400 : BrandColors.ink,
          ),
        ),
      ),
    );
  }
}
