import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'truck_search.dart';

/// The "Grúas cerca de ti" row: what the search has found, whether it is
/// still looking, and the way to stop, restart or reconfigure it.
///
/// Tapping the row toggles the search. The gear opens its settings.
class NearbyTrucksRow extends ConsumerStatefulWidget {
  const NearbyTrucksRow({super.key});

  @override
  ConsumerState<NearbyTrucksRow> createState() => _NearbyTrucksRowState();
}

class _NearbyTrucksRowState extends ConsumerState<NearbyTrucksRow> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Repaints the countdown once a second, and only while there is one.
  void _syncTicker(bool searching) {
    if (searching && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!searching) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(truckSearchProvider);
    final settings = ref.watch(truckSearchSettingsProvider);
    final text = Theme.of(context).textTheme;
    _syncTicker(search.isSearching);

    final count = search.results.length;
    final found = count == 1 ? '1 grúa disponible' : '$count grúas disponibles';
    final subtitle = switch ((search.isSearching, search.center, count)) {
      (_, null, _) => 'Esperando tu ubicación…',
      (true, _, 0) => 'Buscando en ${settings.radiusLabel}',
      (false, _, 0) => 'Ninguna grúa en ${settings.radiusLabel}',
      _ => '$found en ${settings.radiusLabel}',
    };

    final left = search.endsAt?.difference(clock.now()).inSeconds ?? 0;
    // A finished search is a snapshot: trucks come online after it stops, so
    // the label says how to look again rather than calling the count final.
    final status = search.isSearching
        ? 'Buscando… ${left.clamp(0, 999)} s'
        : 'Buscar de nuevo';

    return ListTile(
      key: const Key('nearby-trucks-row'),
      onTap: ref.read(truckSearchProvider.notifier).toggle,
      dense: true,
      leading: const Icon(Icons.local_shipping_outlined, color: BrandColors.grey800),
      title: Text('Grúas cerca de ti', style: text.titleSmall),
      subtitle: Text(
        search.error ?? subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodySmall?.copyWith(
          color: search.error != null
              ? BrandColors.danger
              : count > 0
                  ? BrandColors.success
                  : BrandColors.grey600,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (search.isSearching) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: Insets.xs),
          ],
          Text(
            status,
            style: text.labelMedium?.copyWith(
              color: search.isSearching ? BrandColors.grey600 : BrandColors.success,
            ),
          ),
          IconButton(
            tooltip: 'Ajustes de búsqueda',
            visualDensity: VisualDensity.compact,
            onPressed: () => unawaited(_openSettings(settings)),
            icon: const Icon(Icons.tune, size: 20),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings(TruckSearchSettings current) async {
    final chosen = await showDialog<TruckSearchSettings>(
      context: context,
      builder: (_) => TruckSearchSettingsDialog(initial: current),
    );
    if (chosen == null || !mounted) return;
    await ref.read(truckSearchSettingsProvider.notifier).save(chosen);
    // Saving restarts a running search on its own; a finished one is
    // restarted too, since new settings are a request to look again.
    if (!ref.read(truckSearchProvider).isSearching) {
      ref.read(truckSearchProvider.notifier).start();
    }
  }
}

/// Opens the card for a truck tapped on the home map.
Future<void> showNearbyTruckSheet(BuildContext context, NearbyTruck truck) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => NearbyTruckSheet(truck: truck),
    );

/// One nearby truck: what it is, how far, and the two things to do with it.
///
/// Anonymous on purpose — no name, no plate, no phone: a customer searching
/// must not be able to collect the fleet. "Pedir esta grúa" opens the request
/// with this truck offered the job first; "Chatear" asks this truck's chofer
/// to talk before any job, through the same sealed ref, so the chofer stays
/// anonymous until they choose to answer.
class NearbyTruckSheet extends ConsumerStatefulWidget {
  const NearbyTruckSheet({required this.truck, super.key});

  final NearbyTruck truck;

  @override
  ConsumerState<NearbyTruckSheet> createState() => _NearbyTruckSheetState();
}

class _NearbyTruckSheetState extends ConsumerState<NearbyTruckSheet> {
  var _requestingChat = false;
  String? _chatError;

  /// With a job under way, straight to that job's chat. Otherwise the chofer
  /// of this truck is asked to talk, and the customer waits for the answer on
  /// the conversation screen.
  Future<void> _chat() async {
    final active = ref.read(activeClientServiceProvider).value;
    if (active != null && active.canChat) {
      Navigator.of(context).pop();
      unawaited(context.push(Routes.chatFor(active.id)));
      return;
    }
    if (_requestingChat) return;

    setState(() {
      _requestingChat = true;
      _chatError = null;
    });
    final result =
        await ref.read(functionsGatewayProvider).requestChat(widget.truck.ref);
    if (!mounted) return;

    final requestId = result.valueOrNull;
    if (requestId == null || requestId.isEmpty) {
      setState(() {
        _requestingChat = false;
        _chatError =
            (result.failureOrNull ?? const Failure(FailureCode.unknown))
                .userMessage;
      });
      return;
    }
    Navigator.of(context).pop();
    unawaited(context.push(Routes.chatRequestFor(requestId)));
  }

  void _request() {
    Navigator.of(context).pop();
    unawaited(context.push(Routes.requestTruck(widget.truck)));
  }

  @override
  Widget build(BuildContext context) {
    final truck = widget.truck;
    final text = Theme.of(context).textTheme;

    return BottomActionSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: BrandColors.successTint,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.local_shipping, color: BrandColors.success),
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Grúa disponible', style: text.titleMedium),
                    Text(
                      '${truck.truckType.label} · a ${truck.distanceLabel} de ti',
                      style: text.bodySmall?.copyWith(color: BrandColors.grey600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_chatError != null) ...[
            const SizedBox(height: Insets.md),
            InlineNotice(
              key: const Key('chat-error'),
              icon: Icons.chat_bubble_outline,
              tone: NoticeTone.error,
              message: _chatError!,
            ),
          ],
          const SizedBox(height: Insets.lg),
          Row(
            children: [
              OutlinedButton.icon(
                key: const Key('truck-chat'),
                onPressed: _requestingChat ? null : _chat,
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                icon: _requestingChat
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chat_bubble_outline, size: 20),
                label: const Text('Chatear'),
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: ElevatedButton.icon(
                  key: const Key('truck-request'),
                  onPressed: _request,
                  style: ElevatedButton.styleFrom(minimumSize: const Size(0, 52)),
                  icon: const Icon(Icons.local_shipping, size: 20),
                  label: const Text('PEDIR ESTA GRÚA'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Radius and duration for the nearby search.
class TruckSearchSettingsDialog extends StatefulWidget {
  const TruckSearchSettingsDialog({required this.initial, super.key});

  final TruckSearchSettings initial;

  @override
  State<TruckSearchSettingsDialog> createState() =>
      _TruckSearchSettingsDialogState();
}

class _TruckSearchSettingsDialogState extends State<TruckSearchSettingsDialog> {
  static const List<double> _radii = TruckSearchSettings.radiusOptions;

  late int _radiusIndex;
  late int _seconds;

  @override
  void initState() {
    super.initState();
    final index = _radii.indexOf(widget.initial.radiusKm);
    _radiusIndex = index == -1 ? _radii.indexOf(TruckSearchSettings.defaultRadiusKm) : index;
    _seconds = widget.initial.duration.inSeconds
        .clamp(TruckSearchSettings.minSeconds, TruckSearchSettings.maxSeconds);
  }

  TruckSearchSettings get _chosen => TruckSearchSettings(
        radiusKm: _radii[_radiusIndex],
        duration: Duration(seconds: _seconds),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return AlertDialog(
      title: const Text('Ajustes de búsqueda'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Radio', style: text.titleSmall)),
                Text(_chosen.radiusLabel, style: text.titleSmall),
              ],
            ),
            Slider(
              key: const Key('radius-slider'),
              value: _radiusIndex.toDouble(),
              max: (_radii.length - 1).toDouble(),
              divisions: _radii.length - 1,
              label: _chosen.radiusLabel,
              onChanged: (v) => setState(() => _radiusIndex = v.round()),
            ),
            Text(
              'Qué tan lejos buscar grúas disponibles.',
              style: text.bodySmall?.copyWith(color: BrandColors.grey600),
            ),
            const SizedBox(height: Insets.lg),
            Row(
              children: [
                Expanded(child: Text('Duración', style: text.titleSmall)),
                Text('$_seconds s', style: text.titleSmall),
              ],
            ),
            Slider(
              key: const Key('duration-slider'),
              value: _seconds.toDouble(),
              min: TruckSearchSettings.minSeconds.toDouble(),
              max: TruckSearchSettings.maxSeconds.toDouble(),
              divisions: (TruckSearchSettings.maxSeconds - TruckSearchSettings.minSeconds) ~/ 10,
              label: '$_seconds s',
              onChanged: (v) => setState(() => _seconds = (v / 10).round() * 10),
            ),
            Text(
              'Cuánto tiempo seguir buscando. Revisamos cada '
              '${TruckSearchController.pollEvery.inSeconds} s.',
              style: text.bodySmall?.copyWith(color: BrandColors.grey600),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_chosen),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
