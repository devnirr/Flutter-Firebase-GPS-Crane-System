import 'dart:typed_data';

/// No browser here: nothing to open.
bool openHtmlPage(String html, {required String title}) => false;

/// No browser here: nothing to download into.
bool downloadBytes(Uint8List bytes, {required String fileName, required String mimeType}) =>
    false;
