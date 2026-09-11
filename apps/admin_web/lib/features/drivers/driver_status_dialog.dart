import 'package:flutter/material.dart';
import 'package:grua_core/grua_core.dart';

/// Asks the office to confirm moving [driver] to [target].
///
/// Returns the reason to store with the change, or null when the office backed
/// out. Activating needs no reason — it clears whatever "documentos
/// pendientes" note the account was opened with. Suspending requires one,
/// because it is the text the chofer reads on their blocked screen and a bare
/// "cuenta suspendida" only produces a phone call asking why.
Future<String?> showDriverStatusDialog(
  BuildContext context,
  Driver driver,
  DriverStatus target,
) {
  assert(target != DriverStatus.unknown, 'Not a status the office can set.');
  return showDialog<String>(
    context: context,
    builder: (context) => _DriverStatusDialog(driver: driver, target: target),
  );
}

/// The verb for moving a chofer to [status], as a button reads it.
String driverStatusAction(DriverStatus status) => switch (status) {
      DriverStatus.active => 'Activar',
      DriverStatus.inactive => 'Marcar inactivo',
      DriverStatus.suspended => 'Suspender',
      DriverStatus.unknown => '',
    };

/// The largest reason `setDriverStatus` accepts.
const _maxReasonLength = 300;

class _DriverStatusDialog extends StatefulWidget {
  const _DriverStatusDialog({required this.driver, required this.target});

  final Driver driver;
  final DriverStatus target;

  @override
  State<_DriverStatusDialog> createState() => _DriverStatusDialogState();
}

class _DriverStatusDialogState extends State<_DriverStatusDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _asksReason => widget.target != DriverStatus.active;
  bool get _requiresReason => widget.target == DriverStatus.suspended;

  void _confirm() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_asksReason ? _reason.text.trim() : '');
  }

  @override
  Widget build(BuildContext context) {
    final driver = widget.driver;
    final text = Theme.of(context).textTheme;

    final (title, message, confirmColor) = switch (widget.target) {
      DriverStatus.active => (
          '¿Activar a ${driver.name}?',
          'Podrá conectarse y recibir servicios. Actívalo solo después de '
              'revisar su licencia, cédula y seguro.',
          BrandColors.success,
        ),
      DriverStatus.suspended => (
          '¿Suspender a ${driver.name}?',
          'Deja de recibir servicios de inmediato y pierde el acceso a la app '
              'hasta que lo actives de nuevo.',
          BrandColors.danger,
        ),
      _ => (
          '¿Marcar a ${driver.name} como inactivo?',
          'Deja de recibir servicios de inmediato. Úsalo cuando le falte o se '
              'le venza un documento.',
          BrandColors.grey800,
        ),
    };

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message, style: text.bodyMedium),
              // Active but truckless is a chofer who signs in to a switch that
              // will not turn on. Worth saying before, not discovering after.
              if (widget.target == DriverStatus.active &&
                  driver.assignedTruckId == null) ...[
                const SizedBox(height: Insets.md),
                const InlineNotice(
                  message: 'No tiene grúa asignada: podrá entrar a la app, '
                      'pero no conectarse hasta que le asignes una.',
                  icon: Icons.info_outline,
                  tone: NoticeTone.info,
                ),
              ],
              if (_asksReason) ...[
                const SizedBox(height: Insets.lg),
                TextFormField(
                  controller: _reason,
                  autofocus: true,
                  maxLength: _maxReasonLength,
                  maxLines: 3,
                  minLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: _requiresReason
                        ? 'Motivo (lo verá el chofer)'
                        : 'Motivo (opcional)',
                    hintText: _requiresReason
                        ? 'Ej.: Efectivo pendiente de entregar'
                        : 'Ej.: Seguro vencido',
                  ),
                  validator: (value) =>
                      _requiresReason && (value ?? '').trim().isEmpty
                          ? 'Escribe el motivo de la suspensión.'
                          : null,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: _confirm,
          style: TextButton.styleFrom(foregroundColor: confirmColor),
          child: Text(driverStatusAction(widget.target)),
        ),
      ],
    );
  }
}
