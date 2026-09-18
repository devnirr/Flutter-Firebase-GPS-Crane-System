import 'package:flutter/foundation.dart';

import '../domain/enums.dart';
import '../domain/models/service.dart';
import '../utils/date_time_do.dart';
import 'zone_pricing.dart';

/// The numbers at the top of an insurance company's portal, for the current
/// month in Dominican time.
@immutable
class InsurerStats {
  const InsurerStats({
    required this.monthStart,
    required this.requested,
    required this.completed,
    required this.cancelled,
    required this.active,
    required this.cost,
    required this.averageArrival,
    required this.averageTotal,
  });

  /// Works the numbers out of [services], which must hold at least every tow
  /// the company ordered this month.
  ///
  /// - **Cost** is what the month's invoice will say so far: the price of every
  ///   finished tow plus any cancellation fee, before and after ITBIS.
  /// - **Average arrival** runs from the order to the grúa reaching the
  ///   vehicle; **average total** to the tow being finished.
  factory InsurerStats.of(List<Service> services, DateTime now) {
    final monthStart = DoTime.startOfLocalMonth(now);
    final month = [
      for (final s in services)
        if (_orderedAt(s) case final at? when !at.isBefore(monthStart)) s,
    ];

    bool finished(Service s) =>
        s.status == ServiceStatus.completed || s.status == ServiceStatus.closed;

    // What the month's invoice will hold goes by when a tow finished, as the
    // invoice does, not when it was ordered.
    final subtotal = services.fold<int>(0, (sum, s) {
      final at = _finishedAt(s);
      if (at == null || at.isBefore(monthStart)) return sum;
      if (finished(s)) return sum + s.billedSubtotalCents;
      if (s.status == ServiceStatus.cancelled) {
        return sum + (s.cancellation?.feeCents ?? 0);
      }
      return sum;
    });

    Duration? average(Iterable<Duration> spans) {
      final list = spans.where((d) => !d.isNegative).toList();
      if (list.isEmpty) return null;
      final total = list.fold<int>(0, (sum, d) => sum + d.inSeconds);
      return Duration(seconds: (total / list.length).round());
    }

    return InsurerStats(
      monthStart: monthStart,
      requested: month.length,
      completed: month.where(finished).length,
      cancelled: month.where((s) => s.status == ServiceStatus.cancelled).length,
      active: services.where((s) => s.isActive).length,
      cost: ZonePricing.withItbis(subtotal),
      averageArrival: average([
        for (final s in month)
          if ((_orderedAt(s), s.timeline.arrivedAt) case (final from?, final to?))
            to.difference(from),
      ]),
      averageTotal: average([
        for (final s in month)
          if ((_orderedAt(s), s.timeline.completedAt) case (final from?, final to?))
            to.difference(from),
      ]),
    );
  }

  static DateTime? _orderedAt(Service s) => s.createdAt ?? s.timeline.createdAt;

  static DateTime? _finishedAt(Service s) => s.status == ServiceStatus.cancelled
      ? s.timeline.cancelledAt ?? _orderedAt(s)
      : s.timeline.completedAt ?? s.timeline.closedAt ?? _orderedAt(s);

  final DateTime monthStart;

  /// Tows ordered this month, whatever became of them.
  final int requested;
  final int completed;
  final int cancelled;

  /// In flight right now, whenever they were ordered.
  final int active;
  final ItbisTotals cost;
  final Duration? averageArrival;
  final Duration? averageTotal;

  /// `38 min`, `1 h 05 min`, or `—`.
  static String minutes(Duration? d) {
    if (d == null) return '—';
    final m = (d.inSeconds / 60).round();
    if (m < 60) return '$m min';
    return '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
  }
}
