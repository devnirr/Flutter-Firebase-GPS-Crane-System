import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart'
    show FutureProviderFamily, StreamProviderFamily;
import 'package:grua_core/grua_core.dart';

import '../drivers/driver_status_dialog.dart';
import '../shared/toast.dart';
import 'license_verification_screen.dart';

/// One chofer's licence check, laid out for a decision: both sides and the
/// profile photo, what the chofer typed beside what the card says, and every
/// check with its result.
///
/// Takes the id rather than the driver so the dialog follows the live record:
/// an approval or an activation shows up here the moment it lands.
Future<void> showLicenseReviewDialog(BuildContext context, String driverId) =>
    showDialog<void>(
      context: context,
      builder: (_) => LicenseReviewDialog(driverId: driverId),
    );

final StreamProviderFamily<List<DriverDocument>, String> _documentsProvider =
    StreamProvider.family<List<DriverDocument>, String>(
  (ref, driverId) =>
      ref.watch(driverRepositoryProvider).watchDocuments(driverId),
);

final FutureProviderFamily<String?, String> _documentUrlProvider =
    FutureProvider.family<String?, String>((ref, path) async {
  final url = await ref.watch(driverRepositoryProvider).documentUrl(path);
  return url.valueOrNull;
});

class LicenseReviewDialog extends ConsumerStatefulWidget {
  const LicenseReviewDialog({required this.driverId, super.key});

  final String driverId;

  @override
  ConsumerState<LicenseReviewDialog> createState() =>
      _LicenseReviewDialogState();
}

class _LicenseReviewDialogState extends ConsumerState<LicenseReviewDialog> {
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final driver = ref
        .watch(allDriversProvider)
        .value
        ?.where((d) => d.id == widget.driverId)
        .firstOrNull;
    final verification = driver?.licenseVerification;

    return Dialog(
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(borderRadius: Corners.brMd),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 820,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: driver == null || verification == null
            ? const Padding(
                padding: EdgeInsets.all(Insets.xxl),
                child: BrandLoader(message: 'Cargando…'),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Header(driver: driver, verification: verification),
                  Divider(height: 1, color: palette.border),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(Insets.xxl),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (verification.reason.isNotEmpty) ...[
                            InlineNotice(
                              message: 'Motivo mostrado al chofer: '
                                  '${verification.reason}',
                              tone: verification.state ==
                                      LicenseVerificationState.rejected
                                  ? NoticeTone.error
                                  : NoticeTone.warning,
                            ),
                            const SizedBox(height: Insets.lg),
                          ],
                          const _Title('Fotos'),
                          _Photos(driver: driver),
                          const SizedBox(height: Insets.xl),
                          const _Title('Datos'),
                          _Comparison(
                            driver: driver,
                            read: verification.extracted,
                          ),
                          const SizedBox(height: Insets.xl),
                          const _Title('Verificación automática'),
                          if (verification.checks.isEmpty)
                            Text(
                              verification.state ==
                                      LicenseVerificationState.processing
                                  ? 'Verificando ahora mismo…'
                                  : 'Todavía no se ha verificado.',
                              style: text.bodyMedium
                                  ?.copyWith(color: palette.textMuted),
                            )
                          else
                            for (final check in verification.checks)
                              _CheckRow(check: check),
                          if (verification.notes.isNotEmpty) ...[
                            const SizedBox(height: Insets.md),
                            Text(
                              'Nota: ${verification.notes}',
                              style: text.bodySmall
                                  ?.copyWith(color: palette.textMuted),
                            ),
                          ],
                          const SizedBox(height: Insets.md),
                          Text(
                            [
                              'Intentos: ${verification.attempts} de 3',
                              if (verification.completedAt != null)
                                'Verificada: ${DoTime.dateAndTime(verification.completedAt!)}',
                              if (verification.reviewedAt != null)
                                'Revisada por la oficina: ${DoTime.dateAndTime(verification.reviewedAt!)}',
                            ].join(' · '),
                            style: text.bodySmall
                                ?.copyWith(color: palette.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _Footer(
                    driver: driver,
                    verification: verification,
                    busy: _busy,
                    onApprove: () => unawaited(_approve(driver)),
                    onReject: () => unawaited(_reject(driver)),
                    onActivate: () => unawaited(_activate(driver)),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _approve(Driver driver) async {
    await _run(
      () => ref
          .read(functionsGatewayProvider)
          .reviewLicenseVerification(driverId: driver.id, approve: true),
      done: 'Licencia de ${driver.name} aprobada.',
    );
  }

  Future<void> _reject(Driver driver) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _RejectDialog(),
    );
    if (reason == null || !mounted) return;
    await _run(
      () => ref.read(functionsGatewayProvider).reviewLicenseVerification(
            driverId: driver.id,
            approve: false,
            reason: reason,
          ),
      done: 'Licencia rechazada. ${driver.name} puede subir fotos nuevas.',
    );
  }

  /// The same activation as on Choferes. Offered before the licence is
  /// verified too — the office may have seen it in person — but it asks.
  Future<void> _activate(Driver driver) async {
    final verified =
        driver.licenseVerification?.state == LicenseVerificationState.verified;
    if (!verified) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('La licencia no está verificada'),
          content: const Text(
            '¿Activar al chofer de todas formas? Solo hazlo si la oficina '
            'revisó la licencia por su cuenta.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Activar'),
            ),
          ],
        ),
      );
      if (sure != true || !mounted) return;
    }

    final reason =
        await showDriverStatusDialog(context, driver, DriverStatus.active);
    if (reason == null || !mounted) return;
    await _run(
      () => ref.read(functionsGatewayProvider).setDriverStatus(
            driverId: driver.id,
            status: DriverStatus.active,
            reason: reason,
          ),
      done: '${driver.name} ya puede trabajar.',
    );
  }

  Future<void> _run(
    Future<Result<void>> Function() action, {
    required String done,
  }) async {
    final toast = Toaster.of(context);
    setState(() => _busy = true);
    final result = await action();
    if (mounted) setState(() => _busy = false);
    toast.show(
      result.isErr
          ? result.failureOrNull?.userMessage ?? 'No se pudo completar.'
          : done,
      tone: result.isErr ? ToastTone.error : ToastTone.success,
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.driver, required this.verification});

  final Driver driver;
  final LicenseVerification verification;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xxl,
        Insets.xl,
        Insets.lg,
        Insets.lg,
      ),
      child: Row(
        children: [
          DriverAvatar.of(driver, size: 56),
          const SizedBox(width: Insets.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(driver.name, style: text.titleLarge),
                const SizedBox(height: Insets.xxs),
                Row(
                  children: [
                    LicenseStatePill(state: verification.state),
                    const SizedBox(width: Insets.sm),
                    Text(
                      driver.status == DriverStatus.active
                          ? 'Cuenta activa'
                          : 'Cuenta inactiva',
                      style: text.bodySmall
                          ?.copyWith(color: palette.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Cerrar',
          ),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Row(
        children: [
          FieldLabel(title.toUpperCase()),
          const SizedBox(width: Insets.sm),
          Expanded(child: Divider(color: context.palette.border)),
        ],
      ),
    );
  }
}

/// Front, back and profile photo side by side; a tap opens them full size.
class _Photos extends ConsumerWidget {
  const _Photos({required this.driver});

  final Driver driver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(_documentsProvider(driver.id)).value ?? const [];
    String? pathOf(DriverDocumentType type) =>
        docs.where((d) => d.type == type).firstOrNull?.storagePath;

    String? urlOf(String? path) => path == null || path.isEmpty
        ? null
        : ref.watch(_documentUrlProvider(path)).value;

    final tiles = [
      ('Frente', urlOf(pathOf(DriverDocumentType.licencia))),
      ('Reverso', urlOf(pathOf(DriverDocumentType.licenciaReverso))),
      (
        'Foto de perfil',
        driver.photoUrl.isEmpty ? null : driver.photoUrl,
      ),
    ];
    final urls = [for (final (_, url) in tiles) ?url];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, (label, url)) in tiles.indexed) ...[
          if (i > 0) const SizedBox(width: Insets.md),
          Expanded(
            child: _PhotoTile(
              label: label,
              url: url,
              onTap: url == null
                  ? null
                  : () => showVehiclePhotos(
                        context,
                        urls,
                        initial: urls.indexOf(url),
                      ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.label, required this.url, this.onTap});

  final String label;
  final String? url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: text.labelMedium),
        const SizedBox(height: Insets.xs),
        InkWell(
          onTap: onTap,
          borderRadius: Corners.brMd,
          child: ClipRRect(
            borderRadius: Corners.brMd,
            child: AspectRatio(
              aspectRatio: 1.58, // An ID-1 card.
              child: url == null
                  ? ColoredBox(
                      color: palette.surfaceSubtle,
                      child: Center(
                        child: Text(
                          'Sin foto',
                          style: text.bodySmall
                              ?.copyWith(color: palette.textFaint),
                        ),
                      ),
                    )
                  : VehiclePhoto(url: url!, fit: BoxFit.cover),
            ),
          ),
        ),
      ],
    );
  }
}

/// What the chofer typed beside what the card says.
class _Comparison extends StatelessWidget {
  const _Comparison({required this.driver, required this.read});

  final Driver driver;
  final LicenseReading? read;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    String orDash(String? v) => v == null || v.trim().isEmpty ? '—' : v;

    final rows = [
      ('Nombre', driver.name, read?.fullName),
      ('Cédula', driver.displayCedula, read?.cedula),
      ('Número de licencia', driver.licenseNumber, read?.licenseNumber),
      (
        'Vencimiento',
        driver.licenseExpiry == null
            ? ''
            : DoTime.fullDate(driver.licenseExpiry!),
        read?.expiryDate,
      ),
    ];

    TableRow row(List<String> cells, {bool header = false}) => TableRow(
          children: [
            for (final cell in cells)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                child: Text(
                  cell,
                  style: header
                      ? text.labelSmall?.copyWith(color: palette.textMuted)
                      : text.bodyMedium,
                ),
              ),
          ],
        );

    return Table(
      columnWidths: const {0: FixedColumnWidth(170)},
      children: [
        row(['', 'ESCRITO POR EL CHOFER', 'LEÍDO EN LA LICENCIA'], header: true),
        for (final (label, typed, printed) in rows)
          row([label, orDash(typed), orDash(printed)]),
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});

  final LicenseCheck check;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final (icon, color) = check.passed
        ? (Icons.check_circle, palette.success)
        : check.failed
            ? (Icons.cancel, palette.danger)
            : (Icons.help, palette.warning);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(check.label, style: text.bodyMedium),
                if (check.detail.isNotEmpty)
                  Text(
                    check.detail,
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.driver,
    required this.verification,
    required this.busy,
    required this.onApprove,
    required this.onReject,
    required this.onActivate,
  });

  final Driver driver;
  final LicenseVerification verification;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final state = verification.state;
    final compact = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
    );

    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(top: BorderSide(color: palette.border)),
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(Corners.md),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: Insets.sm,
          runSpacing: Insets.sm,
          children: [
            if (state != LicenseVerificationState.rejected)
              OutlinedButton.icon(
                onPressed: busy ? null : onReject,
                style: compact.copyWith(
                  foregroundColor: WidgetStatePropertyAll(palette.danger),
                ),
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Rechazar'),
              ),
            if (state != LicenseVerificationState.verified)
              OutlinedButton.icon(
                onPressed: busy ? null : onApprove,
                style: compact,
                icon: const Icon(Icons.verified_outlined, size: 18),
                label: const Text('Aprobar licencia'),
              ),
            if (driver.status != DriverStatus.active)
              ElevatedButton.icon(
                onPressed: busy ? null : onActivate,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                ),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('Activar chofer'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Asks why; the chofer reads the answer on their phone.
class _RejectDialog extends StatefulWidget {
  const _RejectDialog();

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rechazar licencia'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: TextFormField(
            controller: _reason,
            autofocus: true,
            maxLength: 300,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Ej.: La foto del reverso está cortada.',
              helperText: 'El chofer lo lee en la app y podrá subir fotos '
                  'nuevas.',
            ),
            validator: (value) => (value ?? '').trim().length < 3
                ? 'Escribe el motivo del rechazo.'
                : null,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop(_reason.text.trim());
          },
          child: const Text('Rechazar'),
        ),
      ],
    );
  }
}
