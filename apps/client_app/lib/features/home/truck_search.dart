import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How far and for how long "Grúas cerca de ti" looks.
@immutable
class TruckSearchSettings {
  const TruckSearchSettings({
    this.radiusKm = defaultRadiusKm,
    this.duration = const Duration(seconds: defaultSeconds),
  });

  /// Dispatch starts its own cascade at 5 km, so this shows the pool a request
  /// would draw on first.
  static const defaultRadiusKm = 5.0;
  static const defaultSeconds = 30;

  /// The radii offered. 40 km is as far as dispatch ever looks.
  static const radiusOptions = <double>[1, 2, 3, 5, 10, 15, 20, 30, 40];
  static const minSeconds = 10;
  static const maxSeconds = 120;

  final double radiusKm;
  final Duration duration;

  String get radiusLabel =>
      '${radiusKm == radiusKm.roundToDouble() ? radiusKm.round() : radiusKm} km';

  @override
  bool operator ==(Object other) =>
      other is TruckSearchSettings &&
      other.radiusKm == radiusKm &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(radiusKm, duration);
}

/// The settings, remembered on this device.
final truckSearchSettingsProvider =
    NotifierProvider<TruckSearchSettingsNotifier, TruckSearchSettings>(
  TruckSearchSettingsNotifier.new,
);

class TruckSearchSettingsNotifier extends Notifier<TruckSearchSettings> {
  static const _radiusKey = 'nearby.radiusKm';
  static const _secondsKey = 'nearby.durationSeconds';

  @override
  TruckSearchSettings build() {
    unawaited(_load());
    return const TruckSearchSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final radius = prefs.getDouble(_radiusKey);
      final seconds = prefs.getInt(_secondsKey);
      if (radius == null && seconds == null) return;
      state = TruckSearchSettings(
        radiusKm: radius ?? state.radiusKm,
        duration: seconds == null ? state.duration : Duration(seconds: seconds),
      );
    } on Object {
      // No storage on this platform: the defaults stand.
    }
  }

  Future<void> save(TruckSearchSettings settings) async {
    state = settings;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_radiusKey, settings.radiusKm);
      await prefs.setInt(_secondsKey, settings.duration.inSeconds);
    } on Object {
      // Kept for this session even if it cannot be stored.
    }
  }
}

enum TruckSearchPhase { searching, complete }

/// Where the search is, and what it has found.
class TruckSearchState {
  const TruckSearchState({
    required this.phase,
    this.results = const [],
    this.center,
    this.endsAt,
    this.error,
  });

  final TruckSearchPhase phase;

  /// The latest answer: trucks move, so each check replaces the last.
  final List<NearbyTruck> results;

  /// Where the search is centred: the customer's position when it began, or
  /// their first fix if it began before one arrived. Null until then.
  final LatLng? center;
  final DateTime? endsAt;

  /// The last check's failure, shown until a later check succeeds.
  final String? error;

  bool get isSearching => phase == TruckSearchPhase.searching;

  TruckSearchState copyWith({
    TruckSearchPhase? phase,
    List<NearbyTruck>? results,
    LatLng? center,
    String? error,
    bool clearError = false,
  }) =>
      TruckSearchState(
        phase: phase ?? this.phase,
        results: results ?? this.results,
        center: center ?? this.center,
        endsAt: endsAt,
        error: clearError ? null : (error ?? this.error),
      );
}

final truckSearchProvider =
    NotifierProvider<TruckSearchController, TruckSearchState>(
  TruckSearchController.new,
);

/// Runs "Grúas cerca de ti": asks the server who is free within the radius,
/// again every few seconds while the search lasts, so a truck that comes
/// online meanwhile appears — then stops, by itself or when the customer taps.
class TruckSearchController extends Notifier<TruckSearchState> {
  /// Often enough to catch a truck coming online, rarely enough that a
  /// two-minute search is two dozen calls rather than a hundred.
  static const pollEvery = Duration(seconds: 5);

  Timer? _poller;
  Timer? _finisher;

  /// Bumped on every start and stop, so an answer to a search that has since
  /// been cancelled or restarted is thrown away.
  var _generation = 0;

  @override
  TruckSearchState build() {
    ref.onDispose(_stopTimers);

    // A search that began before the first fix checks the moment one arrives
    // rather than waiting for the next tick.
    ref.listen(myPositionProvider, (previous, next) {
      if (state.isSearching && state.center == null && next.value != null) {
        unawaited(_poll(_generation));
      }
    });

    // New settings mean a new search, as the customer would expect.
    ref.listen(truckSearchSettingsProvider, (previous, next) {
      if (previous != next && state.isSearching) start();
    });

    // Opening the home screen starts looking, as it always said it did.
    unawaited(Future.microtask(start));
    return const TruckSearchState(phase: TruckSearchPhase.searching);
  }

  void toggle() => state.isSearching ? cancel() : start();

  void start() {
    _stopTimers();
    final generation = ++_generation;
    final settings = ref.read(truckSearchSettingsProvider);

    state = TruckSearchState(
      phase: TruckSearchPhase.searching,
      endsAt: clock.now().add(settings.duration),
    );

    unawaited(_poll(generation));
    _poller = Timer.periodic(pollEvery, (_) => unawaited(_poll(generation)));
    _finisher = Timer(settings.duration, () {
      if (generation == _generation) _finish();
    });
  }

  /// Stops looking and keeps what was found on the map.
  void cancel() => _finish();

  void _finish() {
    _stopTimers();
    _generation++;
    state = state.copyWith(phase: TruckSearchPhase.complete);
  }

  void _stopTimers() {
    _poller?.cancel();
    _finisher?.cancel();
    _poller = null;
    _finisher = null;
  }

  Future<void> _poll(int generation) async {
    // The search stays where it began: re-centring on every 10 m of drift
    // would move the circle, and the camera with it, under the customer.
    final center =
        state.center ?? ref.read(myPositionProvider).value?.position;
    if (center == null) return;

    final radiusKm = ref.read(truckSearchSettingsProvider).radiusKm;
    final result = await ref
        .read(functionsGatewayProvider)
        .nearbyTrucks(center: center, radiusKm: radiusKm);
    if (generation != _generation || !ref.mounted) return;

    state = switch (result) {
      Ok(value: final trucks) =>
        state.copyWith(results: trucks, center: center, clearError: true),
      Err(:final failure) =>
        state.copyWith(center: center, error: failure.userMessage),
    };
  }
}
