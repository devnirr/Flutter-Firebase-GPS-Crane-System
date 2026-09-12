import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

/// Picks a point on the map.
///
/// The map moves and the pin stays fixed in the centre. That is the opposite of
/// dragging a marker, and it is the right way round on a phone: the pin never
/// ends up under the thumb that is placing it, and the target is always the
/// same spot on screen.
///
/// The resolved address is shown as *editable* text and paired with a mandatory
/// landmark reference at pickup, because Dominican street addressing is
/// unreliable enough that a reverse-geocoded string is a hint, not an answer.
class LocationPickerScreen extends ConsumerStatefulWidget {
  const LocationPickerScreen({
    required this.title,
    required this.initial,
    this.requireReference = false,
    super.key,
  });

  final String title;
  final ServiceLocation? initial;

  /// Pickup needs a landmark; a destination usually does not.
  final bool requireReference;

  @override
  ConsumerState<LocationPickerScreen> createState() =>
      _LocationPickerScreenState();
}

class _LocationPickerScreenState extends ConsumerState<LocationPickerScreen> {
  final _address = TextEditingController();
  final _reference = TextEditingController();

  late LatLng _center;
  Timer? _debounce;
  Timer? _suggestDebounce;
  var _resolving = false;
  var _locating = false;
  String? _error;

  /// What the typed text matches, newest answer only.
  var _suggestions = <PlaceSuggestion>[];

  /// Bumped per keystroke, so a slow answer to an older query is dropped
  /// rather than replacing the list under the customer's finger.
  var _suggestQuery = 0;

  /// The address came from a suggestion the customer chose. The camera move
  /// that follows must not have it overwritten by the reverse geocoder, whose
  /// answer for the same point is usually a street number.
  var _addressIsChosen = false;

  @override
  void initState() {
    super.initState();
    // Open where the phone already knows it is, rather than at the centre of
    // Santo Domingo: the position stream on the home map and the fix taken
    // for the pickup are both resolved by now, and waiting on a fresh
    // `getCurrentPosition` left the map sitting on the wrong city for
    // seconds, then animating across it.
    _center = widget.initial?.geo ?? _positionAlreadyKnown() ??
        DoLocations.defaultCenter;
    _address.text = widget.initial?.address ?? '';
    _reference.text = widget.initial?.reference ?? '';
    if (widget.initial == null) unawaited(_useCurrentLocation());
  }

  /// A position some other screen has already paid for, if there is one.
  LatLng? _positionAlreadyKnown() =>
      ref.read(myPositionProvider).value?.position ??
      ref.read(currentPlaceProvider).value?.position;

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestDebounce?.cancel();
    _address.dispose();
    _reference.dispose();
    super.dispose();
  }

  /// Reverse-geocodes after the camera settles.
  ///
  /// Debounced because a pan fires many idle events and each one is a
  /// platform-channel round trip; without it a slow drag hammers the geocoder
  /// and the address field flickers through a dozen intermediate streets.
  void _onCameraIdle(LatLng center) {
    _center = center;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _resolveAddress);
  }

  Future<void> _resolveAddress() async {
    if (!mounted) return;
    // The customer picked this place by name; naming it again by street would
    // replace what they chose with something they did not.
    if (_addressIsChosen) {
      _addressIsChosen = false;
      return;
    }

    setState(() => _resolving = true);

    final place = await ref.read(locationServiceProvider).describe(_center);
    if (!mounted) return;

    setState(() {
      _resolving = false;
      if (place.address.isNotEmpty) _address.text = place.address;
    });
  }

  /// Asks for suggestions a moment after the typing stops.
  ///
  /// Debounced because every call is billed and a five-letter street would
  /// otherwise cost five of them; biased to where the map is looking, so
  /// "Duarte" offers the one in this city first.
  void _onAddressTyped(String value) {
    _addressIsChosen = false;
    _suggestDebounce?.cancel();

    if (value.trim().length < 2) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }

    _suggestDebounce = Timer(const Duration(milliseconds: 250), () async {
      final query = ++_suggestQuery;
      final found = await ref
          .read(placesServiceProvider)
          .suggest(value, near: _center);
      if (!mounted || query != _suggestQuery) return;
      setState(() => _suggestions = found);
    });
  }

  /// Takes the chosen place as the answer: the map goes there, the field says
  /// its name, and the list closes.
  Future<void> _choose(PlaceSuggestion suggestion) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _suggestions = const [];
      _resolving = true;
    });

    final place = await ref.read(placesServiceProvider).details(suggestion.placeId);
    if (!mounted) return;

    setState(() {
      _resolving = false;
      if (place == null) {
        // The name is still worth keeping; the pin stays where it was and the
        // customer can drag it.
        _address.text = suggestion.title;
        return;
      }
      _addressIsChosen = true;
      _center = place.position;
      _address.text = place.address.isNotEmpty ? place.address : suggestion.title;
    });
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _locating = true;
      _error = null;
    });

    final service = ref.read(locationServiceProvider);
    var blocker = await service.check();
    if (blocker == LocationBlocker.notRequested) {
      blocker = await service.request();
    }

    if (!mounted) return;

    if (blocker.isBlocking) {
      setState(() {
        _locating = false;
        _error = blocker.message;
      });
      return;
    }

    final result = await service.currentPlace();
    if (!mounted) return;

    result.fold(
      (place) => setState(() {
        _locating = false;
        _center = place.position;
        if (place.address.isNotEmpty) _address.text = place.address;
      }),
      (failure) => setState(() {
        _locating = false;
        _error = failure.userMessage;
      }),
    );
  }

  Future<void> _openSettings() async {
    final service = ref.read(locationServiceProvider);
    final blocker = await service.check();
    if (blocker == LocationBlocker.serviceDisabled) {
      await service.openLocationSettings();
    } else {
      await service.openAppSettings();
    }
  }

  void _confirm() {
    if (widget.requireReference && _reference.text.trim().isEmpty) {
      setState(() => _error = 'Escribe una referencia para que el chofer te '
          'encuentre.');
      return;
    }

    Navigator.of(context).pop(
      ServiceLocation(
        geo: _center,
        address: _address.text.trim(),
        reference: _reference.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasApiKey = ref.watch(hasMapsKeyProvider);

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          Expanded(
            // Every child is positioned. A Stack takes the size of its
            // unpositioned children, and the pin alone is 44 px wide — which
            // is exactly how wide the map became.
            child: Stack(
              children: [
                Positioned.fill(
                  child: GruaMap(
                    center: _center,
                    hasApiKey: hasApiKey,
                    zoom: 16,
                    onCameraIdle: _onCameraIdle,
                    // No marker at the centre: the fixed pin below is the
                    // pointer, and a second one would be two truths.
                    markers: const [],
                  ),
                ),
                const Positioned.fill(child: Center(child: _CentrePin())),
                Positioned(
                  right: Insets.lg,
                  bottom: Insets.lg,
                  child: FloatingCard(
                    padding: const EdgeInsets.all(Insets.md),
                    borderRadius: Corners.brMd,
                    onTap: _locating ? null : _useCurrentLocation,
                    child: _locating
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : const Icon(Icons.my_location, color: BrandColors.red),
                  ),
                ),
                // The matches sit directly above the address field, over the
                // bottom of the map, the way a search bar's dropdown does.
                if (_suggestions.isNotEmpty)
                  Positioned(
                    left: Insets.lg,
                    right: Insets.lg,
                    bottom: Insets.md,
                    child: _SuggestionList(
                      suggestions: _suggestions,
                      onChosen: _choose,
                    ),
                  ),
                if (!hasApiKey)
                  const Positioned(
                    top: Insets.md,
                    left: Insets.lg,
                    right: Insets.lg,
                    child: InlineNotice(
                      message: 'Mapa de demostración: arrastra para elegir el '
                          'punto. Con la llave de Google Maps configurada verás '
                          'el mapa real.',
                      icon: Icons.map_outlined,
                      tone: NoticeTone.info,
                    ),
                  ),
              ],
            ),
          ),
          BottomActionSheet(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const FieldLabel('Dirección'),
                const SizedBox(height: Insets.sm),
                TextField(
                  key: const Key('address-field'),
                  controller: _address,
                  textInputAction: TextInputAction.search,
                  onChanged: _onAddressTyped,
                  decoration: InputDecoration(
                    hintText: 'Escribe o elige un lugar',
                    suffixIcon: _resolving
                        ? const Padding(
                            padding: EdgeInsets.all(Insets.md),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: Insets.md),
                FieldLabel(
                  widget.requireReference
                      ? 'Referencia (obligatoria)'
                      : 'Referencia (opcional)',
                ),
                const SizedBox(height: Insets.sm),
                TextField(
                  controller: _reference,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  decoration: const InputDecoration(
                    hintText: 'Frente al colmado, km 12 Autopista Duarte…',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: Insets.md),
                  InlineNotice(
                    message: _error!,
                    tone: NoticeTone.error,
                    actionLabel: _error!.contains('ajustes') ? 'Abrir' : null,
                    onAction:
                        _error!.contains('ajustes') ? _openSettings : null,
                  ),
                ],
                const SizedBox(height: Insets.lg),
                ElevatedButton(
                  onPressed: _confirm,
                  child: const Text('CONFIRMAR UBICACIÓN'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the typed address matches, nearest the map's centre first.
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.suggestions, required this.onChosen});

  final List<PlaceSuggestion> suggestions;
  final ValueChanged<PlaceSuggestion> onChosen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Material(
      key: const Key('address-suggestions'),
      color: BrandColors.white,
      borderRadius: Corners.brMd,
      elevation: 6,
      child: ConstrainedBox(
        // Five rows at most: a list that covers the map hides the thing the
        // customer is aiming at.
        constraints: const BoxConstraints(maxHeight: 260),
        child: ListView.separated(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: suggestions.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: BrandColors.grey100),
          itemBuilder: (context, index) {
            final suggestion = suggestions[index];
            return ListTile(
              dense: true,
              leading: const Icon(
                Icons.place_outlined,
                color: BrandColors.grey600,
              ),
              title: Text(
                suggestion.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall,
              ),
              subtitle: suggestion.subtitle.isEmpty
                  ? null
                  : Text(
                      suggestion.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: BrandColors.grey600,
                      ),
                    ),
              onTap: () => onChosen(suggestion),
            );
          },
        ),
      ),
    );
  }
}

/// The fixed pin at the centre of the map, with a shadow that stays put while
/// the pin lifts — the standard cue that the map is what is moving.
class _CentrePin extends StatelessWidget {
  const _CentrePin();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_on, size: 44, color: BrandColors.red),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.28),
              shape: BoxShape.circle,
            ),
          ),
          // Offsets the pin so its tip, not its centre, sits on the target.
          const SizedBox(height: 44),
        ],
      ),
    );
  }
}
