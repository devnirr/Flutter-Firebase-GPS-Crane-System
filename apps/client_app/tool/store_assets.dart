// Makes the two images Play asks for, from the company logo:
//
//   dart run tool/store_assets.dart
//
// - store/play-icon-512.png     the listing icon, 512x512
// - store/play-feature-1024.png the feature graphic, 1024x500
//
// Run from an app folder; both files land in <repo>/store.
import 'dart:io';

import 'package:image/image.dart';

/// The blue the logo sits on, as the graphic's background.
final _background = ColorRgb8(0x1B, 0x4F, 0xD8);

void main() {
  final root = Directory.current.path.replaceAll(r'\', '/');
  final logoPath = '$root/assets/logo_icon.jpeg';
  final logo = decodeImage(File(logoPath).readAsBytesSync());
  if (logo == null) {
    stderr.writeln('Could not read $logoPath');
    exitCode = 1;
    return;
  }

  final out = Directory('$root/../../store')..createSync(recursive: true);

  // The listing icon: the logo, square, at exactly the size Play wants.
  final icon = copyResize(
    logo,
    width: 512,
    height: 512,
    interpolation: Interpolation.cubic,
  );
  File('${out.path}/play-icon-512.png').writeAsBytesSync(encodePng(icon));

  // The feature graphic: the logo centred on its blue, with room around it
  // so Play's own crops cannot clip the lettering.
  final feature = Image(width: 1024, height: 500)..clear(_background);
  final badge = copyResize(
    logo,
    width: 420,
    height: 420,
    interpolation: Interpolation.cubic,
  );
  compositeImage(
    feature,
    badge,
    dstX: (feature.width - badge.width) ~/ 2,
    dstY: (feature.height - badge.height) ~/ 2,
  );
  File(
    '${out.path}/play-feature-1024.png',
  ).writeAsBytesSync(encodePng(feature));

  stdout.writeln('Wrote ${out.path}/play-icon-512.png');
  stdout.writeln('Wrote ${out.path}/play-feature-1024.png');
}
