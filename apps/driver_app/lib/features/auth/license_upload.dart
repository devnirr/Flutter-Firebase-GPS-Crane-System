import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// The licence photos, shared by the registration form and the screen that
/// asks for new ones after a rejected check.

/// True while this app is uploading licence photos and waiting on the check.
///
/// The upload after registration outlives the form — the router moves the
/// chofer on as soon as they are signed in — so the waiting screen reads this
/// to tell "still sending" from "never arrived".
final licenseSubmittingProvider =
    NotifierProvider<LicenseSubmitting, bool>(LicenseSubmitting.new);

class LicenseSubmitting extends Notifier<bool> {
  @override
  bool build() => false;

  // A setter would read as a field; this is a state change others watch.
  // ignore: use_setters_to_change_properties
  void set({required bool busy}) => state = busy;
}

/// Asks camera or gallery, then fetches the photo. Null when cancelled.
Future<PickedPhoto?> choosePhoto(BuildContext context, WidgetRef ref) async {
  final source = await showModalBottomSheet<PhotoSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Tomar foto'),
            onTap: () => Navigator.of(context).pop(PhotoSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Elegir de la galería'),
            onTap: () => Navigator.of(context).pop(PhotoSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;
  return await ref.read(photoPickerProvider)(source);
}

/// Matches the 10 MB ceiling in storage.rules — better said when picking than
/// as a refused upload afterwards.
String? licensePhotoTooBig(PickedPhoto photo) =>
    photo.bytes.lengthInBytes > 10 * 1024 * 1024
        ? 'La foto pesa más de 10 MB.'
        : null;

/// Uploads both sides, records them, and starts the automatic check. Returns
/// what went wrong for the chofer to read, or null.
///
/// Takes its collaborators rather than a `ref`: after registration the widget
/// that started this is disposed long before it finishes.
Future<String?> submitLicense({
  required DriverRepository drivers,
  required FunctionsGateway gateway,
  required LicenseSubmitting submitting,
  required String driverId,
  required PickedPhoto front,
  required PickedPhoto back,
  required DateTime? expiry,
}) async {
  submitting.set(busy: true);
  try {
    for (final (type, side, photo) in [
      (DriverDocumentType.licencia, 'el frente', front),
      (DriverDocumentType.licenciaReverso, 'el reverso', back),
    ]) {
      final problem = await _attachSide(
        drivers: drivers,
        gateway: gateway,
        driverId: driverId,
        type: type,
        side: side,
        photo: photo,
        expiry: expiry,
      );
      if (problem != null) return problem;
    }

    // The verdict also lands on the driver record, which the waiting screen
    // streams; the result here only matters when the call itself failed.
    final verified = await gateway.verifyDriverLicense();
    if (verified.isErr) {
      return verified.failureOrNull?.userMessage ??
          'No pudimos verificar tu licencia. Inténtalo de nuevo.';
    }
    return null;
  } finally {
    submitting.set(busy: false);
  }
}

Future<String?> _attachSide({
  required DriverRepository drivers,
  required FunctionsGateway gateway,
  required String driverId,
  required DriverDocumentType type,
  required String side,
  required PickedPhoto photo,
  required DateTime? expiry,
}) async {
  final upload = await drivers.uploadDocument(
    driverId: driverId,
    type: type,
    bytes: photo.bytes,
    fileName: photo.name,
    contentType: photo.contentType,
  );

  final path = upload.valueOrNull;
  if (path == null) {
    return 'No se pudo subir $side de la licencia. Inténtalo de nuevo.';
  }

  final attached = await gateway.attachDriverDocument(
    driverId: driverId,
    type: type,
    storagePath: path,
    fileName: photo.name,
    contentType: photo.contentType,
    sizeBytes: photo.bytes.lengthInBytes,
    expiresAt: expiry,
  );
  if (attached.isErr) {
    return 'No se pudo registrar $side de la licencia. Inténtalo de nuevo.';
  }
  return null;
}

/// One picked photo, or the button to pick it.
class LicensePhotoField extends StatelessWidget {
  const LicensePhotoField({
    required this.photo,
    required this.error,
    required this.onPick,
    required this.onClear,
    super.key,
  });

  final PickedPhoto? photo;
  final String? error;
  final VoidCallback? onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final picked = photo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(Insets.md),
          decoration: BoxDecoration(
            color: BrandColors.offWhite,
            borderRadius: Corners.brMd,
            border: Border.all(
              color: error != null ? BrandColors.danger : BrandColors.grey200,
            ),
          ),
          child: Row(
            children: [
              if (picked != null) ...[
                ClipRRect(
                  borderRadius: Corners.brSm,
                  child: Image.memory(
                    picked.bytes,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 48,
                      height: 48,
                      color: BrandColors.grey100,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.image_outlined,
                        color: BrandColors.grey600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        picked.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium,
                      ),
                      Text(
                        picked.sizeLabel,
                        style: text.bodySmall
                            ?.copyWith(color: BrandColors.grey600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Quitar',
                  onPressed: onClear,
                  icon: const Icon(Icons.delete_outline),
                ),
              ] else ...[
                const Icon(Icons.badge_outlined, color: BrandColors.grey600),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Text(
                    'Ningún archivo seleccionado',
                    style: text.bodyMedium
                        ?.copyWith(color: BrandColors.grey600),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: onPick,
                  // The theme's buttons are full width; inside a row they have
                  // to be told their own size.
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                  ),
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('Subir foto'),
                ),
              ],
            ],
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: Insets.xs),
          Text(
            error!,
            style: text.bodySmall?.copyWith(color: BrandColors.danger),
          ),
        ],
      ],
    );
  }
}
