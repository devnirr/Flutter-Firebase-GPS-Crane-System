import 'package:flutter/material.dart';
import 'package:grua_core/grua_core.dart';

/// The pieces every create / edit form in the panel is built from, so the
/// chofer, grúa and aseguradora forms look and behave the same.

/// Sends every way out of a form dialog — the barrier, Escape, the X and
/// Cancelar — through one [onClose], so none of them can drop typed data on
/// its own.
///
/// `canPop` is false rather than "false while there is work": typing rebuilds
/// the field and not the dialog, so a flag computed here would be read stale
/// at the moment it matters. [onClose] decides instead, with the values as
/// they are right then.
///
/// The dialog must be opened with `barrierDismissible: true`, or a tap outside
/// never reaches this at all — it is swallowed and the dialog just sits there,
/// which is what it looks like to somebody trying to leave.
class FormDialogScope extends StatelessWidget {
  const FormDialogScope({required this.onClose, required this.child, super.key});

  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) onClose();
    },
    child: child,
  );
}

/// Closes a form dialog, asking first when there is typed work to lose.
///
/// An untouched form closes on the tap that asked for it: a confirmation there
/// is a second click to dismiss an empty dialog, which is the nag that teaches
/// people to click through these without reading. Mid-save nothing closes —
/// the outcome is still coming, as a toast or as an error in the form.
Future<void> closeFormDialog(
  BuildContext context, {
  required bool dirty,
  required bool submitting,
  required String question,
  required String detail,
}) async {
  if (submitting) return;
  if (!dirty) {
    Navigator.of(context).pop();
    return;
  }

  final discard = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(question),
      content: Text(detail),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Seguir editando'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: context.palette.danger),
          child: const Text('Descartar'),
        ),
      ],
    ),
  );
  if (discard == true && context.mounted) Navigator.of(context).pop();
}

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
    this.submitKey,
    super.key,
  });

  final bool submitting;
  final String label;

  /// Null on a dialog whose only way on is the primary button — a result
  /// being acknowledged rather than a form being filled in. Two buttons that
  /// both close it just make the reader choose between identical doors.
  final VoidCallback? onCancel;
  final VoidCallback onSubmit;
  final String? note;

  /// On the primary button, for a dialog whose own tests reach for it.
  final Key? submitKey;

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
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: palette.textMuted),
              ),
            )
          else
            const Spacer(),
          if (onCancel != null) ...[
            TextButton(
              onPressed: submitting ? null : onCancel,
              child: const Text('Cancelar'),
            ),
            const SizedBox(width: Insets.sm),
          ],
          ElevatedButton(
            key: submitKey,
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

/// The scrolling middle of a form dialog, between the header and the footer.
///
/// A long form is cut off by the footer, and a field cut exactly at its label
/// reads as a rendering fault rather than as "there is more below". The last
/// few pixels fade into the surface so the cut is legible as an edge, and the
/// scrollbar says how much is left.
class FormDialogBody extends StatelessWidget {
  const FormDialogBody({required this.child, super.key});

  final Widget child;

  /// Tall enough to read as a fade, short enough not to grey out a field.
  static const _fade = 24.0;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Flexible(
      child: Stack(
        children: [
          Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                Insets.xxl,
                Insets.xl,
                Insets.xxl,
                Insets.lg,
              ),
              child: child,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _fade,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      palette.surface.withValues(alpha: 0),
                      palette.surface,
                    ],
                  ),
                ),
              ),
            ),
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
              style: Theme.of(context).textTheme.bodySmall
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
    final soon =
        expiry != null && expiry.difference(DateTime.now()).inDays <= 30;

    // A date about to run out is a warning, not a refusal: as `errorText` it
    // painted the field's border the same red as a date left empty, which said
    // "wrong" about paperwork the office had entered correctly.
    final warn = soon && error == null;

    return InkWell(
      onTap: onPick,
      borderRadius: Corners.brSm,
      child: InputDecorator(
        decoration: InputDecoration(
          suffixIcon: Icon(
            Icons.calendar_today_outlined,
            size: 18,
            color: warn ? palette.warning : null,
          ),
          errorText: error,
          errorStyle: TextStyle(color: palette.danger),
          helperText: warn ? 'Vence en menos de 30 días.' : null,
          helperStyle: TextStyle(color: palette.warning, fontSize: 12),
          enabledBorder: warn
              ? OutlineInputBorder(
                  borderRadius: Corners.brMd,
                  borderSide: BorderSide(color: palette.warning),
                )
              : null,
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
