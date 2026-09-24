import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'app_presence.dart';
import 'correct_registration_screen.dart';
import 'license_upload.dart';

/// What a self-registered chofer sees until the office activates them: where
/// the licence check stands, and new photos to send when it asks for them.
///
/// Everything here follows `drivers/{uid}.licenseVerification`, which the
/// check writes as it goes, so the screen moves on by itself.
class LicenseVerificationView extends ConsumerWidget {
  const LicenseVerificationView({required this.driver, super.key});

  final Driver driver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verification = driver.licenseVerification!;
    final submitting = ref.watch(licenseSubmittingProvider);
    final state = verification.state;

    // "Sending" wins over whatever the record says: new photos are on their
    // way, and the old verdict is about to be replaced.
    final body = submitting || state == LicenseVerificationState.processing
        ? _Progress(sending: submitting)
        : switch (state) {
            LicenseVerificationState.verified => const _Outcome(
              icon: Icons.verified_outlined,
              color: BrandColors.success,
              title: 'Licencia verificada',
              message:
                  'Tu licencia pasó la verificación. La oficina '
                  'activará tu cuenta pronto.',
            ),
            LicenseVerificationState.manualReview => const _Outcome(
              icon: Icons.manage_search_outlined,
              color: BrandColors.warning,
              title: 'En revisión',
              message:
                  'La oficina revisará tus documentos y activará tu '
                  'cuenta.',
            ),
            LicenseVerificationState.rejected => _Resubmit(
              driver: driver,
              title: 'Licencia rechazada',
              message: verification.reason.isNotEmpty
                  ? verification.reason
                  : 'No pudimos verificar tu licencia. Sube fotos nuevas.',
            ),
            _ => _Resubmit(
              driver: driver,
              title: 'Falta tu licencia',
              message:
                  'No recibimos las fotos de tu licencia. Súbelas '
                  'para verificar tu cuenta.',
            ),
          };

    return Scaffold(
      backgroundColor: BrandColors.white,
      body: SafeArea(
        // A result sits in the exact middle of the screen, with the steps on
        // top and sign-out at the bottom laid over it. The photo form is
        // taller than a phone, so it gets a page that scrolls instead.
        child: body is! _Resubmit
            ? Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.gutter,
                      ),
                      child: Center(child: body),
                    ),
                  ),
                  Positioned(
                    top: Insets.gutter + Insets.xl,
                    left: Insets.gutter,
                    right: Insets.gutter,
                    child: _Steps(state: state, sending: submitting),
                  ),
                  Positioned(
                    bottom: Insets.gutter,
                    left: Insets.gutter,
                    right: Insets.gutter,
                    child: TextButton(
                      onPressed: submitting ? null : () => signOutDriver(ref),
                      child: const Text('Cerrar sesión'),
                    ),
                  ),
                ],
              )
            : CustomScrollView(
                slivers: [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.all(Insets.gutter),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: Insets.xl),
                          _Steps(state: state, sending: submitting),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: Insets.xxl,
                              ),
                              child: Center(child: body),
                            ),
                          ),
                          TextButton(
                            onPressed: submitting
                                ? null
                                : () => signOutDriver(ref),
                            child: const Text('Cerrar sesión'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Fotos → Verificación → Resultado, with the current one lit.
class _Steps extends StatelessWidget {
  const _Steps({required this.state, required this.sending});

  final LicenseVerificationState state;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final step = sending
        ? 0
        : switch (state) {
            LicenseVerificationState.awaitingDocuments => 0,
            LicenseVerificationState.processing => 1,
            _ => 2,
          };
    const labels = ['Fotos', 'Verificación', 'Resultado'];
    final text = Theme.of(context).textTheme;

    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Divider(
                thickness: 2,
                color: i <= step ? BrandColors.red : BrandColors.grey200,
              ),
            ),
          Column(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: i <= step
                    ? BrandColors.red
                    : BrandColors.grey200,
                child: i < step
                    ? const Icon(
                        Icons.check,
                        size: 16,
                        color: BrandColors.white,
                      )
                    : Text(
                        '${i + 1}',
                        style: text.labelMedium?.copyWith(
                          color: i <= step
                              ? BrandColors.white
                              : BrandColors.grey600,
                        ),
                      ),
              ),
              const SizedBox(height: Insets.xs),
              Text(labels[i], style: text.labelSmall),
            ],
          ),
        ],
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.sending});

  final bool sending;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 56,
          height: 56,
          child: CircularProgressIndicator(strokeWidth: 4),
        ),
        const SizedBox(height: Insets.xl),
        Text(
          sending ? 'Enviando tu licencia…' : 'Verificando tu licencia…',
          textAlign: TextAlign.center,
          style: text.headlineSmall,
        ),
        const SizedBox(height: Insets.sm),
        Text(
          'Estamos revisando que tu licencia esté vigente y que coincida con '
          'tus datos. Esto toma menos de un minuto; no cierres la app.',
          textAlign: TextAlign.center,
          style: text.bodyLarge?.copyWith(color: BrandColors.grey600),
        ),
      ],
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 64, color: color),
        const SizedBox(height: Insets.lg),
        Text(title, textAlign: TextAlign.center, style: text.headlineSmall),
        const SizedBox(height: Insets.sm),
        Text(
          message,
          textAlign: TextAlign.center,
          style: text.bodyLarge?.copyWith(color: BrandColors.grey600),
        ),
      ],
    );
  }
}

/// The reason, a way to fix mistyped details, and two fresh photos to send.
class _Resubmit extends ConsumerStatefulWidget {
  const _Resubmit({
    required this.driver,
    required this.title,
    required this.message,
  });

  final Driver driver;
  final String title;
  final String message;

  @override
  ConsumerState<_Resubmit> createState() => _ResubmitState();
}

class _ResubmitState extends ConsumerState<_Resubmit> {
  PickedPhoto? _front;
  PickedPhoto? _back;
  String? _frontError;
  String? _backError;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final attempts = widget.driver.licenseVerification?.attempts ?? 0;
    // Only a rejection has compared the details with the card; with no
    // photos yet there is nothing to correct them against.
    final canCorrect =
        widget.driver.licenseVerification?.state ==
        LicenseVerificationState.rejected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(
          Icons.gpp_maybe_outlined,
          size: 64,
          color: BrandColors.danger,
        ),
        const SizedBox(height: Insets.lg),
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: text.headlineSmall,
        ),
        const SizedBox(height: Insets.sm),
        Text(
          widget.message,
          textAlign: TextAlign.center,
          style: text.bodyLarge?.copyWith(color: BrandColors.grey600),
        ),
        if (attempts > 0) ...[
          const SizedBox(height: Insets.xs),
          Text(
            'Intento $attempts de 3. Después, la oficina revisa tus '
            'documentos.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
        ],
        if (canCorrect) ...[
          const SizedBox(height: Insets.lg),
          OutlinedButton.icon(
            onPressed: () => showCorrectRegistration(context, widget.driver),
            icon: const Icon(Icons.edit_outlined, size: 20),
            label: const Text('Corregir mis datos'),
          ),
          const SizedBox(height: Insets.sm),
          Text(
            'O sube fotos nuevas de tu licencia:',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
        ],
        const SizedBox(height: Insets.xl),
        const FieldLabel('LICENCIA (FRENTE) *'),
        const SizedBox(height: Insets.sm),
        LicensePhotoField(
          photo: _front,
          error: _frontError,
          onPick: () => _pick(back: false),
          onClear: () => setState(() => _front = null),
        ),
        const SizedBox(height: Insets.lg),
        const FieldLabel('LICENCIA (REVERSO) *'),
        const SizedBox(height: Insets.sm),
        LicensePhotoField(
          photo: _back,
          error: _backError,
          onPick: () => _pick(back: true),
          onClear: () => setState(() => _back = null),
        ),
        if (_error != null) ...[
          const SizedBox(height: Insets.lg),
          InlineNotice(message: _error!, tone: NoticeTone.error),
        ],
        const SizedBox(height: Insets.xl),
        ElevatedButton(onPressed: _send, child: const Text('ENVIAR LICENCIA')),
      ],
    );
  }

  Future<void> _pick({required bool back}) async {
    final picked = await choosePhoto(context, ref);
    if (picked == null || !mounted) return;
    final error = licensePhotoTooBig(picked);
    final photo = error == null ? picked : null;
    setState(() {
      if (back) {
        _back = photo;
        _backError = error;
      } else {
        _front = photo;
        _frontError = error;
      }
    });
  }

  Future<void> _send() async {
    setState(() {
      _frontError = _front == null ? 'Sube el frente de la licencia.' : null;
      _backError = _back == null ? 'Sube el reverso de la licencia.' : null;
      _error = null;
    });
    final front = _front;
    final back = _back;
    if (front == null || back == null) return;

    // Sending swaps this form for the progress view, disposing it, so a
    // problem is reported through the scaffold rather than this State.
    final messenger = ScaffoldMessenger.of(context);
    final problem = await submitLicense(
      drivers: ref.read(driverRepositoryProvider),
      gateway: ref.read(functionsGatewayProvider),
      submitting: ref.read(licenseSubmittingProvider.notifier),
      driverId: widget.driver.id,
      front: front,
      back: back,
      expiry: widget.driver.licenseExpiry,
    );
    if (problem == null) return;
    if (mounted) {
      setState(() => _error = problem);
    } else {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
    }
  }
}
