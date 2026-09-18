import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Opens [html] in a new tab from a blob, so nothing is uploaded anywhere.
bool openHtmlPage(String html, {required String title}) {
  final blob = web.Blob(
    [html.toJS].toJS,
    web.BlobPropertyBag(type: 'text/html;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final opened = web.window.open(url, '_blank');
  // The tab keeps its own copy once loaded; the URL can go after a while.
  Future<void>.delayed(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
  return opened != null;
}

/// Saves [bytes] as [fileName] through the browser's own download.
bool downloadBytes(Uint8List bytes, {required String fileName, required String mimeType}) {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(link);
  link
    ..click()
    ..remove();
  Future<void>.delayed(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
  return true;
}
