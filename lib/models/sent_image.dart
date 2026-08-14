import 'dart:typed_data';

class SentImage {
  SentImage({
    this.fullBytes,
    this.thumbnailBytes,
    required this.label,
    this.deviceIndex,
    this.needsDisplayRotation = true,
    // Multi-frame sequence support (e.g. Flash Banner animations)
    this.isSequence = false,
    this.sequenceFrames,
    this.sequenceThumbnails,
    this.sequenceDeviceIndices,
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

  // ── Sequence fields (Flash Banner etc.) ──────────────────────────────────
  /// True when this item represents a multi-frame animation.
  final bool isSequence;

  /// Raw JPEG bytes for every frame in the sequence.
  List<Uint8List>? sequenceFrames;

  /// Thumbnail JPEG bytes for every frame (used for the animated preview).
  List<Uint8List>? sequenceThumbnails;

  /// Hardware image indices assigned after uploading to the BLE device.
  /// Populated frame-by-frame during upload; null until each frame is sent.
  List<int?>? sequenceDeviceIndices;

  /// True when every frame of the sequence has been uploaded to the device.
  bool get isSequenceFullyUploaded =>
      isSequence &&
      sequenceDeviceIndices != null &&
      sequenceDeviceIndices!.isNotEmpty &&
      sequenceDeviceIndices!.every((idx) => idx != null);

  /// Returns the list of non-null device indices for the sequence.
  List<int> get uploadedSequenceIndices =>
      sequenceDeviceIndices?.whereType<int>().toList() ?? [];
}

