import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// A photo taken or chosen for upload, already read into memory.
class PickedPhoto {
  const PickedPhoto({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;

  /// Only the types storage.rules accepts; anything unrecognised is sent as a
  /// JPEG, which is what a phone camera produces anyway.
  String get contentType {
    final dot = name.lastIndexOf('.');
    final ext = dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      _ => 'image/jpeg',
    };
  }

  String get sizeLabel {
    final kb = bytes.lengthInBytes / 1024;
    return kb < 1024
        ? '${kb.toStringAsFixed(0)} KB'
        : '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}

enum PhotoSource { camera, gallery }

/// How a screen gets a photo off the phone.
///
/// A provider rather than a direct call so a widget test can hand a form its
/// licence, or a chat its photo: there is no camera to drive in a test, and a
/// form whose required photo cannot be supplied cannot be submitted.
typedef PhotoPicker = Future<PickedPhoto?> Function(PhotoSource source);

final photoPickerProvider = Provider<PhotoPicker>((ref) => pickPhoto);

/// The real picker.
Future<PickedPhoto?> pickPhoto(PhotoSource source) async {
  final file = await ImagePicker().pickImage(
    source: source == PhotoSource.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    // A licence stays legible at this size, and it keeps a phone photo well
    // under the bucket's 10 MB ceiling.
    maxWidth: 2000,
    imageQuality: 85,
  );
  if (file == null) return null;
  return PickedPhoto(name: file.name, bytes: await file.readAsBytes());
}

/// Asks camera or gallery. Null when the sheet is dismissed.
Future<PhotoSource?> askPhotoSource(BuildContext context) =>
    showModalBottomSheet<PhotoSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Tomar foto'),
              onTap: () => Navigator.of(context).pop(PhotoSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Elegir de la galería'),
              onTap: () => Navigator.of(context).pop(PhotoSource.gallery),
            ),
          ],
        ),
      ),
    );
