import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

class SentImage {
  // ignore: prefer_initializing_formals
  SentImage({
    Uint8List? fullBytes,
    this.thumbnailBytes,
    required this.label,
    this.deviceIndex,
    this.needsDisplayRotation = true,
    // Multi-frame sequence support (e.g. Flash Banner animations)
    this.isSequence = false,
    this.sequenceFrames,
    this.sequenceThumbnails,
    this.sequenceDeviceIndices,
  }) : _fullBytes = fullBytes;

  /// In-memory full JPEG bytes. Null once bytes have been persisted to disk.
  Uint8List? _fullBytes;

  /// Temporary file on disk holding full JPEG bytes after [persistFullBytes] is called.
  File? _fullBytesFile;

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
  /// After [persistSequenceFrames] is called these are nulled to free RAM.
  List<Uint8List>? sequenceFrames;

  /// Temporary disk files for each sequence frame, populated by [persistSequenceFrames].
  List<File?>? sequenceFrameFiles;

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

  // ── Disk-persistence helpers ──────────────────────────────────────────────

  /// Write [bytes] to a temporary file and clear the in-memory reference.
  /// Subsequent calls to [loadFullBytes] will read from disk.
  Future<void> persistFullBytes(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/amoled_${label.hashCode}_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes, flush: true);
    _fullBytesFile = file;
    _fullBytes = null;
  }

  /// Load and return the full JPEG bytes: reads from the disk file if
  /// [persistFullBytes] was called, otherwise returns the in-memory reference.
  /// Returns null if neither is available.
  Future<Uint8List?> loadFullBytes() async {
    if (_fullBytes != null) return _fullBytes;
    if (_fullBytesFile != null && await _fullBytesFile!.exists()) {
      return _fullBytesFile!.readAsBytes();
    }
    return null;
  }

  /// Frees in-memory full bytes without deleting the disk file.
  void evictFullBytes() {
    _fullBytes = null;
  }

  /// Deletes the persisted temp file from disk (call when the image is removed).
  Future<void> deletePersistedFile() async {
    final f = _fullBytesFile;
    if (f != null && await f.exists()) {
      await f.delete();
      _fullBytesFile = null;
    }
  }

  // ── Sequence frame disk-persistence helpers ───────────────────────────────

  /// Write each sequence frame to a temp file and clear in-memory frame bytes.
  Future<void> persistSequenceFrames() async {
    if (sequenceFrames == null) return;
    final dir = await getTemporaryDirectory();
    final files = <File?>[];
    for (int i = 0; i < sequenceFrames!.length; i++) {
      final file = File('${dir.path}/amoled_seq_${label.hashCode}_${i}_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await file.writeAsBytes(sequenceFrames![i], flush: true);
      files.add(file);
    }
    sequenceFrameFiles = files;
    sequenceFrames = null;
  }

  /// Load the bytes for a single sequence frame from disk (or in-memory fallback).
  Future<Uint8List?> loadSequenceFrame(int index) async {
    // In-memory fallback (before persistence)
    if (sequenceFrames != null && index < sequenceFrames!.length) {
      return sequenceFrames![index];
    }
    final files = sequenceFrameFiles;
    if (files != null && index < files.length && files[index] != null) {
      final f = files[index]!;
      if (await f.exists()) return f.readAsBytes();
    }
    return null;
  }

  /// Deletes all persisted sequence frame temp files from disk.
  Future<void> deletePersistedSequenceFiles() async {
    final files = sequenceFrameFiles;
    if (files == null) return;
    for (final f in files) {
      if (f != null && await f.exists()) await f.delete();
    }
    sequenceFrameFiles = null;
  }
}
