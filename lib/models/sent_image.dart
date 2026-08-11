import 'dart:typed_data';

class SentImage {
  SentImage({
    this.fullBytes,
    this.thumbnailBytes,
    required this.label,
    this.deviceIndex,
    this.needsDisplayRotation = true,
  });
  
  Uint8List? fullBytes;
  Uint8List? thumbnailBytes;
  final String label;
  int? deviceIndex;
  bool selectedForRotation = false;
  // Native panel bytes are stored in 192x960 portrait buffer for direct delivery.
  // needsDisplayRotation = true un-rotates the image on phone screen previews (quarterTurns: 3)
  // so it is displayed right side up in landscape.
  final bool needsDisplayRotation;
}
