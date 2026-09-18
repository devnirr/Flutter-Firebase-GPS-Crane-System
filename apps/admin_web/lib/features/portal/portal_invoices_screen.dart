import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../invoices/invoice_view.dart';
import '../invoices/invoices_screen.dart';
import 'portal_shell.dart';

/// The company's monthly invoices, for its managers.
class PortalInvoicesScreen extends ConsumerWidget {
  const PortalInvoicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final invoicesAsync = ref.watch(myInsurerInvoicesProvider);
    final invoices = invoicesAsync.value ?? const <InsurerInvoice>[];
    final now = DateTime.now().toUtc();
    final owed = invoices.where((i) => i.isIssued).fold<int>(0, (s, i) => s + i.totalCents);
    final overdue = invoices.where((i) => i.isOverdueAt(now)).length;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        const PortalHeader(
          title: 'Facturas',
          subtitle: 'La factura de cada mes, con su NCF. Se emite el día 1 por '
              'los servicios terminados el mes anterior.',
        ),
        const SizedBox(height: Insets.xl),
        Wrap(
          spacing: Insets.lg,
          runSpacing: Insets.lg,
          children: [
            PortalKpi(
              key: const Key('portal-kpi-owed'),
              label: 'Por pagar',
              value: owed.formatDOP,
              icon: Icons.account_balance_wallet_outlined,
              detail: overdue == 0 ? 'Al día' : '$overdue vencida(s)',
              color: overdue == 0 ? null : palette.danger,
            ),
            PortalKpi(
              label: 'Facturas',
              value: '${invoices.length}',
              icon: Icons.receipt_long_outlined,
            ),
          ],
        ),
        const SizedBox(height: Insets.xl),
        FloatingCard(
          child: switch (invoicesAsync) {
            AsyncValue(:final error?) when !invoicesAsync.hasValue => Text(
                error is Failure ? error.userMessage : 'No pudimos cargar tus facturas.',
                style: text.bodyMedium?.copyWith(color: palette.danger),
              ),
            _ when invoices.isEmpty => Text(
                invoicesAsync.isLoading
                    ? 'Cargando…'
                    : 'Todavía no tienes facturas. La primera se emite el día 1 '
                        'del mes siguiente a tu primer servicio.',
                key: const Key('portal-invoices-empty'),
                style: text.bodyMedium?.copyWith(color: palette.textMuted),
              ),
            _ => Column(
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
        ),
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
      AsyncValue(:final value?) when value.insurerId == insurerId => InsurerInvoiceView(
          invoice: value,
          onBack: () => context.go(Routes.portalInvoices),
        ),
      AsyncValue(isLoading: true) => const Center(child: CircularProgressIndicator()),
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
