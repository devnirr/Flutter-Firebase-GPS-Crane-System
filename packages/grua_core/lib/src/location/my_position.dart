import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/value_objects.dart';
import '../providers.dart';

/// Where this phone says its holder is, for their own map — the chofer's
/// home and job screens, the customer's home.
///
/// Separate from the chofer's location publisher on purpose: that one runs
/// only while online and exists to feed dispatch, this one runs whenever the
/// screen is open, so anyone can see themselves before doing anything else.
typedef MyFix = ({LatLng position, double heading});

/// The live position, or null until the first fix or while location is
/// blocked. [locationBlockerProvider] errors where there is no location plugin
/// at all, which leaves this null: the map still draws, with nobody on it.
final myPositionProvider = StreamProvider<MyFix?>((ref) {
  final blocker = ref.watch(locationBlockerProvider).value;
  if (blocker == null || blocker.isBlocking) return Stream.value(null);

  final location = ref.watch(locationServiceProvider);
  final controller = StreamController<MyFix?>();

  // One quick fix first, so the pin is on the map without waiting for the
  // holder to move 10 m.
  unawaited(
    location.currentPlace(geocode: false).then((result) {
      final place = result.valueOrNull;
      if (place != null && !controller.isClosed) {
        controller.add((position: place.position, heading: 0));
      }
    }),
  );

  final subscription = location.watchPosition(distanceFilter: 10).listen(
        (p) => controller.add(
          (position: LatLng(p.latitude, p.longitude), heading: p.heading),
        ),
        // A dropped GPS is not worth an error screen; the last fix stays.
        onError: (Object _) {},
      );

  ref.onDispose(() {
    unawaited(subscription.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
});

/// Snaps a point to ~100 m, the grain road routes are fetched at: a truck
/// creeping down a street should not cost a Routes API call per metre.
LatLng routeGrain(LatLng p) => LatLng(
      (p.latitude * 1000).roundToDouble() / 1000,
      (p.longitude * 1000).roundToDouble() / 1000,
    );
