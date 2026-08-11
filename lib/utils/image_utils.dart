import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

// Matches PANEL_H_RES/PANEL_V_RES in the ESP32-P4 firmware's config.h -- the
// panel is a fixed 960 (wide) x 192 (tall) landscape strip. The firmware just
// memcpy's decoded pixels straight into the framebuffer with no scaling or
// rotation -- any JPEG that isn't exactly 960x192 renders corrupted/sheared
// on real hardware.
const int panelWidth = 960;
const int panelHeight = 192;

// Cover-fits arbitrary source image bytes into the panel's native landscape
// canvas (panelWidth x panelHeight, i.e. 960x192). Mirrors
// renderTextToPanelImage below so photos and text-composed images are
// treated identically.
Uint8List fitImageToPanel(Uint8List sourceBytes) {
  final rawDecoded = img.decodeImage(sourceBytes);
  if (rawDecoded == null) {
    throw Exception('Could not decode image');
  }
  // Apply EXIF orientation tag (e.g. portrait photos shot on Android/iOS
  // arrive with Rotate-90 CW in EXIF but physical pixels still landscape).
  // bakeOrientation() rotates the pixel data to match the tag, then clears
  // the tag so the output JPEG has no misleading orientation metadata.
  final decoded = img.bakeOrientation(rawDecoded);

  const targetWidth = panelWidth;  // 960
  const targetHeight = panelHeight; // 192

  final srcAspect = decoded.width / decoded.height;
  const dstAspect = targetWidth / targetHeight;

  img.Image scaled;
  if (srcAspect > dstAspect) {
    // Source is relatively wider than the target -- match height, crop width.
    scaled = img.copyResize(decoded, height: targetHeight);
  } else {
    // Source is relatively taller than the target -- match width, crop height.
    scaled = img.copyResize(decoded, width: targetWidth);
  }

  final xOffset = ((scaled.width - targetWidth) / 2).round();
  final yOffset = ((scaled.height - targetHeight) / 2).round();
  final cropped = img.copyCrop(scaled, x: xOffset, y: yOffset, width: targetWidth, height: targetHeight);

  return Uint8List.fromList(img.encodeJpg(cropped, quality: 90));
}

// Renders text on the panel's native landscape canvas
// (panelWidth x panelHeight, i.e. 960x192). Mirrors fitImageToPanel so
// photos and text-composed images are treated identically.
Future<Uint8List> renderTextToPanelImage({
  required String text,
  required Color textColor,
  required Color backgroundColor,
  double fontSize = 64,
}) async {
  final logicalWidth = panelWidth.toDouble();  // 960
  final logicalHeight = panelHeight.toDouble(); // 192

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, logicalWidth, logicalHeight));
  canvas.drawRect(Rect.fromLTWH(0, 0, logicalWidth, logicalHeight), Paint()..color = backgroundColor);

  final textPainter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: textColor, fontSize: fontSize, fontWeight: FontWeight.bold),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  );
  textPainter.layout(maxWidth: logicalWidth - 32);
  final offset = Offset(
    (logicalWidth - textPainter.width) / 2,
    (logicalHeight - textPainter.height) / 2,
  );
  textPainter.paint(canvas, offset);

  final picture = recorder.endRecording();
  final logicalImage = await picture.toImage(logicalWidth.round(), logicalHeight.round());
  final byteData = await logicalImage.toByteData(format: ui.ImageByteFormat.png);
  final pngBytes = byteData!.buffer.asUint8List();

  final decoded = img.decodeImage(pngBytes)!;
  return Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
}

// Downscales an already-native (panelWidth x panelHeight) JPEG to a tiny
// version for the on-screen image list -- both to avoid re-decoding a
// full-size image just to render a thumbnail, and so the same tiny
// bytes can be uploaded alongside the full image (see main/jpeg_reassembly.h's
// THMB command) for fast list syncing without downloading full-resolution
// images from the device.
const int thumbWidth = panelWidth ~/ 4;  // 240
const int thumbHeight = panelHeight ~/ 4; // 48

Uint8List makeThumbnail(Uint8List nativeJpeg) {
  final decoded = img.decodeImage(nativeJpeg);
  if (decoded == null) {
    throw Exception('Could not decode image for thumbnail');
  }
  final resized = img.copyResize(decoded, width: thumbWidth, height: thumbHeight);
  return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
}
