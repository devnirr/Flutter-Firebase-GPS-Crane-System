import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'browser_stub.dart'
    if (dart.library.js_interop) 'browser_web.dart' as platform;

/// Opens an invoice as a printable page, where the browser's own "Guardar
/// como PDF" makes the document the company files.
abstract interface class InvoicePrinter {
  /// False when the page could not be opened — a pop-up blocker, most often.
  bool open(InsurerInvoice invoice);
}

class BrowserInvoicePrinter implements InvoicePrinter {
  const BrowserInvoicePrinter();

  @override
  bool open(InsurerInvoice invoice) => platform.openHtmlPage(
        InvoiceDocument.html(invoice),
        title: InvoiceDocument.fileTitle(invoice),
      );
}

/// Swapped in tests, which have no browser to open a tab in.
final invoicePrinterProvider = Provider<InvoicePrinter>(
  (ref) => const BrowserInvoicePrinter(),
);
