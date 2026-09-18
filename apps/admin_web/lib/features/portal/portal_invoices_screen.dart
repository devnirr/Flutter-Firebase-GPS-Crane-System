import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../invoices/invoice_view.dart';
import '../invoices/invoices_screen.dart';
import '../shared/page_parts.dart';
import 'portal_shell.dart';

/// The company's monthly invoices, for its managers.
class PortalInvoicesScreen extends ConsumerWidget {
  const PortalInvoicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final invoicesAsync = ref.watch(myInsurerInvoicesProvider);
    final invoices = invoicesAsync.value ?? const <InsurerInvoice>[];
    final now = DateTime.now().toUtc();
    final owed = invoices
        .where((i) => i.isIssued)
        .fold<int>(0, (s, i) => s + i.totalCents);
    final overdue = invoices.where((i) => i.isOverdueAt(now)).toList();
    final overdueCents = overdue.fold<int>(0, (s, i) => s + i.totalCents);
    final paid = invoices.where((i) => i.isPaid).length;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        const PortalHeader(
          title: 'Facturas',
          subtitle:
              'La factura de cada mes, con su NCF. Se emite el día 1 por '
              'los servicios terminados el mes anterior.',
        ),
        const SizedBox(height: Insets.xl),
        // Three equal tiles across the page: what is owed, what of it is
        // late, and the invoices in all.
        StatRow(
          children: [
            PortalKpi(
              key: const Key('portal-kpi-owed'),
              width: null,
              label: 'Por pagar',
              value: owed.formatDOP,
              icon: Icons.account_balance_wallet_outlined,
              detail: owed == 0 ? 'Al día' : 'Facturas emitidas sin pagar',
              color: owed == 0 ? null : palette.info,
            ),
            PortalKpi(
              width: null,
              label: 'Vencidas',
              value: overdueCents.formatDOP,
              icon: Icons.warning_amber_rounded,
              detail: overdue.isEmpty
                  ? 'Ninguna vencida'
                  : overdue.length == 1
                  ? '1 factura pasada de fecha'
                  : '${overdue.length} facturas pasadas de fecha',
              color: overdue.isEmpty ? null : palette.danger,
            ),
            PortalKpi(
              width: null,
              label: 'Facturas',
              value: '${invoices.length}',
              icon: Icons.receipt_long_outlined,
              detail: paid == 1 ? '1 pagada' : '$paid pagadas',
            ),
          ],
        ),
        const SizedBox(height: Insets.xl),
        switch (invoicesAsync) {
          AsyncValue(:final error?) when !invoicesAsync.hasValue =>
            FloatingCard(
              child: EmptyState(
                icon: Icons.error_outline,
                tone: EmptyStateTone.error,
                title: 'No pudimos cargar tus facturas',
                message: error is Failure
                    ? error.userMessage
                    : 'Recarga la página para intentarlo de nuevo.',
              ),
            ),
          _ when invoices.isEmpty && invoicesAsync.isLoading =>
            const FloatingCard(
              child: Padding(
                padding: EdgeInsets.all(Insets.xl),
                child: BrandLoader(),
              ),
            ),
          _ when invoices.isEmpty => const FloatingCard(
            child: EmptyState(
              key: Key('portal-invoices-empty'),
              icon: Icons.receipt_long_outlined,
              title: 'Todavía no tienes facturas',
              message:
                  'La primera se emite el día 1 del mes siguiente a tu '
                  'primer servicio.',
            ),
          ),
          _ => ListCard(
            title: 'Tus facturas',
            children: [
              for (final invoice in invoices)
                InvoiceTile(
                  invoice: invoice,
                  now: now,
                  showCompany: false,
                  onTap: () => context.go(Routes.portalInvoiceFor(invoice.id)),
                ),
            ],
          ),
        },
      ],
    );
  }
}

/// One of the company's invoices.
class PortalInvoiceDetailScreen extends ConsumerWidget {
  const PortalInvoiceDetailScreen({required this.invoiceId, super.key});

  final String invoiceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invoice = ref.watch(insurerInvoiceProvider(invoiceId));
    final insurerId = ref.watch(currentInsurerIdProvider).value;

    return switch (invoice) {
      // Another company's is refused by the rules; "not found" either way.
      AsyncValue(:final value?) when value.insurerId == insurerId =>
        InsurerInvoiceView(
          invoice: value,
          onBack: () => context.go(Routes.portalInvoices),
        ),
      AsyncValue(isLoading: true) => const Center(
        child: CircularProgressIndicator(),
      ),
      _ => EmptyState(
        key: const Key('portal-invoice-missing'),
        title: 'Factura no encontrada',
        message: 'Esa factura no existe o no es de tu aseguradora.',
        icon: Icons.search_off,
        actionLabel: 'Ver mis facturas',
        onAction: () => context.go(Routes.portalInvoices),
      ),
    };
  }
}
