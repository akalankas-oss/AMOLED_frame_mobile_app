import 'dart:typed_data';

class SentImage {
  SentImage({
    this.fullBytes,
    this.thumbnailBytes,
    required this.label,
    this.deviceIndex,
    this.needsDisplayRotation = false,
  });
  
  Uint8List? fullBytes;
  Uint8List? thumbnailBytes;
  final String label;
  int? deviceIndex;
  bool selectedForRotation = false;
  // False for all images: the pipeline no longer bakes a 90° rotation into
  // the JPEG (the panel is landscape 960×192 and the firmware renders pixels
  // directly), so the preview displays the image exactly as stored.
  final bool needsDisplayRotation;
}
