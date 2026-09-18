import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser_stub.dart'
    if (dart.library.js_interop) 'browser_web.dart' as platform;

/// Hands a file to the person: the browser's download, here.
abstract interface class FileSaver {
  /// False when nothing could be saved.
  bool save(Uint8List bytes, {required String fileName, required String mimeType});
}

class BrowserFileSaver implements FileSaver {
  const BrowserFileSaver();

  @override
  bool save(Uint8List bytes, {required String fileName, required String mimeType}) =>
      platform.downloadBytes(bytes, fileName: fileName, mimeType: mimeType);
}

/// Swapped in tests, which have no browser to download into.
final fileSaverProvider = Provider<FileSaver>((ref) => const BrowserFileSaver());

const xlsxMimeType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
