import 'package:intl/intl.dart';

/// Dominican time handling.
///
/// The Dominican Republic is UTC-4 year round: Atlantic Standard Time, no
/// daylight saving since 2000. That single fact lets the whole system avoid a
/// timezone database — but it must be applied deliberately, because the night
/// surcharge, the daily rollup boundary and every displayed timestamp all
/// depend on it. Storing UTC and formatting local is the rule; a UTC hour used
/// as a local hour applies the 22:00 surcharge at 6 p.m.
abstract final class DoTime {
  /// Atlantic Standard Time. Fixed — do not make this configurable without
  /// also revisiting the rollup boundaries.
  static const Duration utcOffset = Duration(hours: -4);

  static const String timeZoneName = 'America/Santo_Domingo';

  /// Converts an instant to Dominican wall-clock time.
  ///
  /// The result is a `DateTime` whose fields read as local, flagged UTC so no
  /// further shifting happens by accident.
  static DateTime toLocal(DateTime instant) =>
      instant.toUtc().add(utcOffset);

  /// The inverse: Dominican wall-clock fields to a UTC instant.
  static DateTime fromLocal(DateTime localWallClock) =>
      DateTime.utc(
        localWallClock.year,
        localWallClock.month,
        localWallClock.day,
        localWallClock.hour,
        localWallClock.minute,
        localWallClock.second,
      ).subtract(utcOffset);

  /// `2026-09-08` in Dominican local time — the key daily rollups are stored
  /// under, so "yesterday's revenue" means the day the office actually worked.
  static String dateKey(DateTime instant) {
    final local = toLocal(instant);
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  /// Local midnight that starts the day containing [instant], as a UTC instant.
  static DateTime startOfLocalDay(DateTime instant) {
    final local = toLocal(instant);
    return fromLocal(DateTime.utc(local.year, local.month, local.day));
  }

  static DateTime endOfLocalDay(DateTime instant) =>
      startOfLocalDay(instant).add(const Duration(days: 1));

  /// Local Monday that starts the week containing [instant].
  static DateTime startOfLocalWeek(DateTime instant) {
    final startOfDay = startOfLocalDay(instant);
    final weekday = toLocal(instant).weekday; // 1 = Monday
    return startOfDay.subtract(Duration(days: weekday - 1));
  }

  static DateTime startOfLocalMonth(DateTime instant) {
    final local = toLocal(instant);
    return fromLocal(DateTime.utc(local.year, local.month));
  }

  // ---------------------------------------------------------------------------
  // Display formatting, es-DO
  // ---------------------------------------------------------------------------

  static final DateFormat _time = DateFormat('h:mm a', 'es_DO');
  static final DateFormat _dayMonth = DateFormat('d MMM', 'es_DO');
  static final DateFormat _full = DateFormat("d 'de' MMMM, y", 'es_DO');
  static final DateFormat _fullWithTime =
      DateFormat('d MMM y · h:mm a', 'es_DO');

  /// `3:42 p. m.`
  static String time(DateTime instant) => _time.format(toLocal(instant));

  /// `8 sept`
  static String dayMonth(DateTime instant) => _dayMonth.format(toLocal(instant));

  /// `8 de septiembre, 2026`
  static String fullDate(DateTime instant) => _full.format(toLocal(instant));

  /// `8 sept 2026 · 3:42 p. m.`
  static String dateAndTime(DateTime instant) =>
      _fullWithTime.format(toLocal(instant));

  /// "hace 5 min" / "ayer" / "8 sept" — for history lists, where the exact
  /// second is noise.
  static String relative(DateTime instant, {DateTime? now}) {
    final reference = now ?? DateTime.now().toUtc();
    final diff = reference.difference(instant);

    if (diff.isNegative) return 'ahora';
    if (diff.inMinutes < 1) return 'ahora';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
    if (diff.inHours < 24) {
      return 'hace ${diff.inHours} ${diff.inHours == 1 ? 'hora' : 'horas'}';
    }
    if (diff.inDays == 1) return 'ayer';
    if (diff.inDays < 7) return 'hace ${diff.inDays} días';
    return dayMonth(instant);
  }

  /// `12 min`, `1 h 05 min` — durations on the tracking screen and in reports.
  static String duration(Duration value) {
    if (value.inSeconds < 60) return '${value.inSeconds} s';
    if (value.inMinutes < 60) return '${value.inMinutes} min';
    final hours = value.inHours;
    final minutes = value.inMinutes % 60;
    return '$hours h ${minutes.toString().padLeft(2, '0')} min';
  }

  /// `04:32` — the counting clock on the chofer's waiting timer.
  static String stopwatch(Duration value) {
    final minutes = value.inMinutes.abs();
    final seconds = value.inSeconds.abs() % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}
