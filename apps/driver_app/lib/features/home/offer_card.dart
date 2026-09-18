import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// The offer to show, or null.
///
/// An offer's document stays `sent` for a moment after it lapses, until the
/// server's sweep marks it expired, so this also drops it on its own clock at
/// [Offer.expiresAt]. A card counting down past zero invites a tap that can
/// only fail.
final openOfferProvider = Provider<Offer?>((ref) {
  final offer = ref.watch(incomingOfferProvider).value;
  if (offer == null || !offer.isOpen) return null;

  final expiresAt = offer.expiresAt;
  if (expiresAt == null) return offer;
  final left = expiresAt.difference(clock.now().toUtc());
  if (left <= Duration.zero) return null;

  final timer = Timer(left, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return offer;
});

/// The request the server is offering this chofer, and nobody else, until
/// `expiresAt`.
///
/// Everything needed to decide is on the card: what they take home, how far
/// the customer is by road, what is wrong with the vehicle and where it goes.
/// Accepting is a server call that can lose a race — another chofer, or the
/// clock — and the refusal says which.
class OfferCard extends ConsumerStatefulWidget {
  const OfferCard({required this.offer, super.key});

  final Offer offer;

  @override
  ConsumerState<OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends ConsumerState<OfferCard> {
  Timer? _tick;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    // Repaints the countdown. The time itself comes from the server's
    // expiresAt, never from counting ticks.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _respond({required bool accept}) async {
    if (_busy) return;
    setState(() => _busy = true);

    // Taken *before* the call, and used whether or not this card is still on
    // screen afterwards. The card is pulled the moment the offer lapses —
    // `openOfferProvider` drops it on its own clock — so a `mounted` check
    // here swallowed exactly the answer the chofer needed: they tapped
    // ACEPTAR, the card vanished, and nothing ever said why.
    final messenger = ScaffoldMessenger.of(context);

    final gateway = ref.read(functionsGatewayProvider);
    final serviceId = widget.offer.serviceId;
    final result = accept
        ? await gateway.acceptService(serviceId)
        : await gateway.rejectService(serviceId, reason: DriverCancelReason.other);

    if (mounted) setState(() => _busy = false);

    // On success there is nothing to say: an accepted job moves the router to
    // the service screen, and a rejected offer disappears.
    if (result case Err(:final failure)) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(failure.userMessage),
          backgroundColor: BrandColors.danger,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final text = Theme.of(context).textTheme;
    final now = clock.now().toUtc();
    final seconds = offer.secondsRemaining(now);

    final me = ref.watch(myPositionProvider).value;
    final toPickup = me == null
        ? null
        : ref.watch(roadRouteProvider((routeGrain(me.position), offer.pickupGeo))).value;
    final tow = offer.dropoffGeo == null
        ? null
        : ref.watch(roadRouteProvider((offer.pickupGeo, offer.dropoffGeo!))).value;

    // The road figure when we have it; the server's straight-line estimate
    // until then.
    final distance = toPickup?.distanceLabel ?? offer.distanceLabel;
    final minutes = toPickup?.durationLabel ??
        '${(offer.etaSeconds / 60).ceil().clamp(1, 999)} min';

    return FloatingCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(Corners.lg)),
            child: LinearProgressIndicator(
              value: offer.progress(now),
              minHeight: 5,
              backgroundColor: BrandColors.grey100,
              color: seconds <= 8 ? BrandColors.danger : BrandColors.red,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'NUEVA SOLICITUD',
                        style: text.labelMedium?.copyWith(color: BrandColors.red),
                      ),
                    ),
                    Text(
                      '$seconds s',
                      style: text.titleMedium?.copyWith(
                        color: seconds <= 8 ? BrandColors.danger : BrandColors.ink,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Insets.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            offer.netEarningsCents.formatDOP,
                            style: text.headlineSmall?.copyWith(color: BrandColors.red),
                          ),
                          Text(
                            'Ganancia por este servicio · ${offer.paymentMethod.label}',
                            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('$distance · $minutes', style: text.titleSmall),
                        Text(
                          'hasta el cliente',
                          style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                        ),
                      ],
                    ),
                  ],
                ),
                const Divider(height: Insets.xl),
                Text(
                  offer.vehicleLabel.isEmpty ? 'Vehículo' : offer.vehicleLabel,
                  style: text.titleSmall,
                ),
                Text(
                  offer.condition.label,
                  style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                ),
                // What the customer photographed: a car on its side and one
                // with a flat are different jobs.
                if (offer.vehiclePhotoUrls.isNotEmpty) ...[
                  const SizedBox(height: Insets.sm),
                  VehiclePhotoStrip(
                    key: const Key('offer-vehicle-photos'),
                    urls: offer.vehiclePhotoUrls,
                  ),
                ],
                const SizedBox(height: Insets.md),
                RouteSummary(
                  pickup: offer.pickupAddress.isEmpty
                      ? 'Ubicación en el mapa'
                      : offer.pickupAddress,
                  pickupReference: offer.pickupReference,
                  dropoff: offer.dropoffAddress.isEmpty ? null : offer.dropoffAddress,
                ),
                if (tow != null) ...[
                  const SizedBox(height: Insets.sm),
                  Text(
                    'Remolque: ${tow.distanceLabel} · ${tow.durationLabel}',
                    style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: _busy ? null : () => _respond(accept: false),
                  style: TextButton.styleFrom(
                    foregroundColor: BrandColors.grey600,
                    padding: const EdgeInsets.symmetric(vertical: Insets.lg),
                    shape: const RoundedRectangleBorder(),
                  ),
                  child: const Text('RECHAZAR'),
                ),
              ),
              Container(width: 1, height: 44, color: BrandColors.grey100),
              Expanded(
                child: TextButton(
                  onPressed: _busy ? null : () => _respond(accept: true),
                  style: TextButton.styleFrom(
                    foregroundColor: BrandColors.red,
                    padding: const EdgeInsets.symmetric(vertical: Insets.lg),
                    shape: const RoundedRectangleBorder(),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Text('ACEPTAR'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
