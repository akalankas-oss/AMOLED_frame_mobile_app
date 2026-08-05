import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

// Matches PANEL_H_RES/PANEL_V_RES in the ESP32-P4 firmware's config.h -- the
// panel is a fixed 192 (wide) x 960 (tall) physical strip. The firmware just
// memcpy's decoded pixels straight into a panelWidth x panelHeight
// framebuffer with no scaling or rotation -- any JPEG that isn't exactly
// that size (in that orientation) renders corrupted/sheared on real
// hardware. No firmware/delivery changes here -- both pipelines below
// produce a native panelWidth x panelHeight JPEG, matching what's always
// been sent to the device.
const int panelWidth = 192;
const int panelHeight = 960;

// Cover-fits arbitrary source image bytes into a landscape working canvas
// (panelHeight x panelWidth, e.g. 960x192 -- the natural way to view/compose
// content), then rotates 90 deg clockwise into the panel's native
// panelWidth x panelHeight buffer for delivery. Mirrors renderTextToPanelImage
// below so photos and text-composed images are treated identically.
Uint8List fitImageToPanel(Uint8List sourceBytes) {
  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) {
    throw Exception('Could not decode image');
  }

  const targetWidth = panelHeight; // 960 -- landscape working canvas
  const targetHeight = panelWidth; // 192

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

  final rotated = img.copyRotate(cropped, angle: 90);
  return Uint8List.fromList(img.encodeJpg(rotated, quality: 90));
}

// Renders text on the same landscape working canvas (panelHeight x
// panelWidth) as fitImageToPanel, then rotates 90 deg clockwise into the
// panel's native panelWidth x panelHeight buffer for delivery.
Future<Uint8List> renderTextToPanelImage({
  required String text,
  required Color textColor,
  required Color backgroundColor,
  double fontSize = 64,
}) async {
  final logicalWidth = panelHeight.toDouble(); // 960 -- landscape canvas
  final logicalHeight = panelWidth.toDouble(); // 192

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
  final rotated = img.copyRotate(decoded, angle: 90);
  return Uint8List.fromList(img.encodeJpg(rotated, quality: 90));
}

// Downscales an already-native (panelWidth x panelHeight) JPEG to a tiny
// version for the on-screen image list -- both to avoid re-decoding a
// full-size image just to render a 60x30 thumbnail, and so the same tiny
// bytes can be uploaded alongside the full image (see main/jpeg_reassembly.h's
// THMB command) for fast list syncing without downloading full-resolution
// images from the device.
const int thumbWidth = panelWidth ~/ 4; // 48
const int thumbHeight = panelHeight ~/ 4; // 240

Uint8List makeThumbnail(Uint8List nativeJpeg) {
  final decoded = img.decodeImage(nativeJpeg);
  if (decoded == null) {
    throw Exception('Could not decode image for thumbnail');
  }
  final resized = img.copyResize(decoded, width: thumbWidth, height: thumbHeight);
  return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
}
