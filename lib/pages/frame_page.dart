import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/frame_ble_service.dart';
import '../ble/frame_connection.dart';
import '../models/sent_image.dart';
import '../utils/image_utils.dart';
import 'flash_banner_page.dart';
import 'image_editor_page.dart';
import '../widgets/neumorphic_components.dart';

// ── Animated sequence thumbnail ───────────────────────────────────────────
/// Cycles through the thumbnails of a multi-frame sequence at ~8 fps.
class _SequenceThumbnail extends StatefulWidget {
  const _SequenceThumbnail({required this.thumbnails, required this.needsDisplayRotation});
  final List<Uint8List> thumbnails;
  final bool needsDisplayRotation;

  @override
  State<_SequenceThumbnail> createState() => _SequenceThumbnailState();
}

class _SequenceThumbnailState extends State<_SequenceThumbnail> {
  int _frameIndex = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (mounted) setState(() => _frameIndex = (_frameIndex + 1) % widget.thumbnails.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotatedBox(
      quarterTurns: widget.needsDisplayRotation ? 3 : 0,
      child: Image.memory(widget.thumbnails[_frameIndex], fit: BoxFit.cover),
    );
  }
}

class FramePage extends StatefulWidget {
  const FramePage({super.key});

  @override
  State<FramePage> createState() => _FramePageState();
}

class _FramePageState extends State<FramePage> {
  FrameConnState _connState = FrameConnState.disconnected;
  bool _busy = false;
  bool _syncing = false;
  double _brightness = 255;
  final List<String> _log = [];

  final List<SentImage> _sentImages = [];
  int? _activeIndex;
  double _rotationSeconds = 5;
  bool _rotationActive = false;

  final FrameBleService _bleService = FrameBleService.instance;

  @override
  void initState() {
    super.initState();
    _bleService.onLog = _addLog;
    _bleService.connStateNotifier.addListener(_onConnStateChanged);
    _connectToFrame();
  }

  @override
  void dispose() {
    _bleService.connStateNotifier.removeListener(_onConnStateChanged);
    super.dispose();
  }

  void _onConnStateChanged() {
    final newState = _bleService.connState;
    if (newState != _connState) {
      setState(() => _connState = newState);
      if (newState == FrameConnState.connected) {
        _syncFromDevice();
      }
    }
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > 12) _log.removeLast();
    });
  }

  Future<bool> _ensurePermissions() async {
    // BLE + location are required for the device connection.
    final bleStatuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final bleGranted = bleStatuses.values.every((s) => s.isGranted || s.isLimited);

    // Photo/media permissions for image picking.
    // Android 13+ (API 33+): Permission.photos → READ_MEDIA_IMAGES
    // Android ≤ 12         : Permission.storage → READ_EXTERNAL_STORAGE
    // Treated as non-fatal — the system image picker usually works regardless,
    // but requesting avoids silent failures on stricter OEM builds.
    final mediaStatuses = await [
      Permission.photos,
      Permission.storage,
    ].request();
    final mediaGranted = mediaStatuses.values.any((s) => s.isGranted || s.isLimited);
    if (!mediaGranted) {
      _addLog('Warning: Media/photo permission not granted. Image picking may be limited on this device.');
    }

    return bleGranted;
  }

  Future<void> _connectToFrame() async {
    await _bleService.connectToFrame(ensurePermissions: _ensurePermissions);
  }

  Future<void> _syncFromDevice() async {
    if (_bleService.connState != FrameConnState.connected) return;
    setState(() {
      _busy = true;
      _syncing = true;
    });
    try {
      await _syncBrightnessFromDevice();
      await _syncImageListFromDevice();
      await _syncPlaylistFromDevice();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _syncing = false;
        });
      }
    }
  }

  Future<void> _syncBrightnessFromDevice() async {
    try {
      final level = await _bleService.syncBrightnessFromDevice();
      setState(() => _brightness = level);
      _addLog('Synced brightness: ${(_brightness / 255 * 100).round()}%');
    } catch (e) {
      _addLog('Could not sync brightness: $e');
    }
  }

  Future<void> _syncImageListFromDevice() async {
    try {
      final count = await _bleService.syncImageListCountFromDevice();
      final known = _sentImages.map((i) => i.deviceIndex).whereType<int>().toSet();
      final missing = [for (int i = 0; i < count; i++) if (!known.contains(i)) i];
      if (missing.isEmpty) {
        _addLog('Device has $count image(s), already in sync');
        return;
      }

      _addLog('Syncing ${missing.length} image(s) from device...');
      for (final index in missing) {
        Uint8List? thumb;
        try {
          thumb = await _bleService.downloadThumbnail(index);
        } catch (e) {
          _addLog('Could not download thumbnail for image $index: $e');
        }
        setState(() => _sentImages.add(
          SentImage(thumbnailBytes: thumb, label: 'Device Image $index', deviceIndex: index),
        ));
      }
      _addLog('Sync complete');
    } catch (e) {
      _addLog('Could not sync image list: $e');
    }
  }

  Future<void> _syncPlaylistFromDevice() async {
    try {
      final res = await _bleService.syncPlaylistFromDevice();
      setState(() {
        for (final image in _sentImages) {
          image.selectedForRotation = image.deviceIndex != null && res.playlistIndices.contains(image.deviceIndex);
        }
        final interval = res.interval.toDouble();
        if (interval < 2 || interval > 30) {
          _addLog('Warning: Device rotation interval ${res.interval} is out of bounds (2-30s). Normalizing to ${interval.clamp(2.0, 30.0)}.');
        }
        _rotationSeconds = interval.clamp(2.0, 30.0);
        _rotationActive = res.active;
      });
    } catch (e) {
      _addLog('Could not sync rotation state: $e');
    }
  }

  void _showAddContentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.only(top: 8, bottom: 32, left: 16, right: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Text(
                'Add Content',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              _buildAddOption(
                icon: Icons.photo_library_outlined,
                iconColor: AppColors.cyanAccent,
                title: 'Pick Image',
                subtitle: 'Choose a photo from your gallery',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage();
                },
              ),
              const SizedBox(height: 12),
              _buildAddOption(
                icon: Icons.add_photo_alternate_outlined,
                iconColor: AppColors.pinkAccent,
                title: 'Create Image',
                subtitle: 'Design with colors, text, and photos',
                onTap: () {
                  Navigator.pop(ctx);
                  _openCreateImageStudio();
                },
              ),
              const SizedBox(height: 12),
              _buildAddOption(
                icon: Icons.bolt,
                iconColor: AppColors.purpleAccent,
                title: 'Flash Banner',
                subtitle: 'Animated scrolling banner',
                onTap: () {
                  Navigator.pop(ctx);
                  _openFlashBanner();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAddOption({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: NeumorphicCard(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    try {
      final fitted = fitImageToPanel(bytes);
      final thumb = makeThumbnail(fitted);
      final image = SentImage(
        thumbnailBytes: thumb,
        label: 'Image ${_sentImages.length + 1}',
      );
      // Spill full bytes to a temp file; thumbnail stays in RAM for previews.
      await image.persistFullBytes(fitted);
      setState(() {
        _sentImages.add(image);
        _activeIndex = _sentImages.length - 1;
      });
    } catch (e) {
      _addLog('Image processing failed: $e');
    }
  }


  /// Opens the unified "Create Image" design studio.
  /// No initial image is required — the user starts with a solid colour canvas
  /// and can optionally add a photo background from within the editor.
  Future<void> _openCreateImageStudio() async {
    final editedBytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const ImageEditorPage()),
    );

    if (editedBytes != null) {
      if (!mounted) return;
      final thumb = makeThumbnail(editedBytes);
      final image = SentImage(
        thumbnailBytes: thumb,
        label: 'Image ${_sentImages.length + 1}',
      );
      await image.persistFullBytes(editedBytes);
      setState(() {
        _sentImages.add(image);
        _activeIndex = _sentImages.length - 1;
      });
    }
  }

  Future<void> _openFlashBanner() async {
    final frames = await Navigator.of(context).push<List<Uint8List>>(
      MaterialPageRoute(builder: (_) => const FlashBannerPage()),
    );
    if (frames == null || frames.isEmpty) return;
    if (!mounted) return;

    // Build per-frame thumbnails for the animated preview (kept in RAM — small).
    final thumbs = frames.map(makeThumbnail).toList();
    final seqImage = SentImage(
      // First-frame thumbnail stays in RAM as the static fallback
      thumbnailBytes: thumbs.first,
      label: 'Banner ${_sentImages.length + 1}',
      isSequence: true,
      // sequenceFrames holds bytes temporarily until persistSequenceFrames() spills to disk.
      sequenceFrames: frames,
      sequenceThumbnails: thumbs,
      // One nullable slot per frame, filled during BLE upload
      sequenceDeviceIndices: List<int?>.filled(frames.length, null),
    );
    // Spill all frame bytes to temp files to avoid holding them in RAM.
    await seqImage.persistSequenceFrames();
    seqImage.selectedForRotation = true;
    setState(() {
      _sentImages.add(seqImage);
      _activeIndex = _sentImages.length - 1;
    });
    _addLog('Added banner sequence (${frames.length} frames) — press "Send Selected to Device" then "Start Rotation".');
  }


  Future<void> _showImageEntry(int index) async {
    if (_bleService.connState != FrameConnState.connected || _busy) return;
    final image = _sentImages[index];
    setState(() {
      _activeIndex = index;
      _busy = true;
    });
    try {
      if (image.isSequence) {
        // Upload any frames that haven't been sent yet
        final frameCount = image.sequenceFrameFiles?.length ?? image.sequenceFrames?.length ?? 0;
        for (int i = 0; i < frameCount; i++) {
          if ((image.sequenceDeviceIndices?[i]) == null) {
            final frameBytes = await image.loadSequenceFrame(i);
            if (frameBytes == null) continue;
            final tmp = SentImage(
              thumbnailBytes: image.sequenceThumbnails?[i],
              label: '${image.label} [${i + 1}]',
            );
            await tmp.persistFullBytes(frameBytes);
            final idx = await _bleService.uploadImageWithThumbnail(tmp);
            setState(() => image.sequenceDeviceIndices![i] = idx);
          }
        }
        // Play all frames as a fast mini-rotation (1 s per frame)
        final indices = image.uploadedSequenceIndices;
        if (indices.isNotEmpty) {
          await _bleService.startRotation(indices, 1);
          setState(() => _rotationActive = true);
        }
      } else {
        int deviceIndex;
        if (image.deviceIndex != null) {
          deviceIndex = image.deviceIndex!;
        } else if (await image.loadFullBytes() != null) {
          deviceIndex = await _bleService.uploadImageWithThumbnail(image);
          setState(() => image.deviceIndex = deviceIndex);
        } else {
          throw Exception('No data available');
        }
        await _bleService.showImageEntry(deviceIndex);
      }
    } catch (e) {
      _addLog('Show failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleRotationSelected(SentImage image) {
    setState(() => image.selectedForRotation = !image.selectedForRotation);
  }

  bool get _allSelected => _sentImages.isNotEmpty && _sentImages.every((i) => i.selectedForRotation);

  void _toggleSelectAll() {
    final newValue = !_allSelected;
    setState(() {
      for (final image in _sentImages) {
        image.selectedForRotation = newValue;
      }
    });
  }

  Future<void> _sendSelectedToDevice() => _bleService.enqueueBleTask(_doSendSelectedToDevice);
  Future<void> _doSendSelectedToDevice() async {
    if (_bleService.connState != FrameConnState.connected || _busy) return;

    // Collect items that still need uploading (single images and sequence frames)
    final toSend = _sentImages.where((i) {
      if (!i.selectedForRotation) return false;
      if (i.isSequence) {
        // Include the sequence if any frame is still not uploaded
        return i.sequenceFrames != null &&
            (i.sequenceDeviceIndices?.any((idx) => idx == null) ?? true);
      }
      // deviceIndex == null means it hasn't been uploaded yet; bytes are on disk.
      return i.deviceIndex == null;
    }).toList();

    if (toSend.isEmpty) return;

    setState(() => _busy = true);
    int totalFramesSent = 0;
    try {
      for (final image in toSend) {
        if (image.isSequence) {
          final frameCount = image.sequenceFrameFiles?.length ?? image.sequenceFrames?.length ?? 0;
          for (int i = 0; i < frameCount; i++) {
            if ((image.sequenceDeviceIndices?[i]) == null) {
              final frameBytes = await image.loadSequenceFrame(i);
              if (frameBytes == null) continue;
              final tmp = SentImage(
                thumbnailBytes: image.sequenceThumbnails?[i],
                label: '${image.label} [${i + 1}]',
              );
              await tmp.persistFullBytes(frameBytes);
              final idx = await _bleService.uploadImageWithThumbnail(tmp);
              setState(() => image.sequenceDeviceIndices![i] = idx);
              totalFramesSent++;
            }
          }
        } else {
          final index = await _bleService.uploadImageWithThumbnail(image);
          setState(() => image.deviceIndex = index);
          totalFramesSent++;
        }
      }
      _addLog('Sent $totalFramesSent frame(s) to device');
    } catch (e) {
      _addLog('Send failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startRotation() => _bleService.enqueueBleTask(_doStartRotation);
  Future<void> _doStartRotation() async {
    final selected = _sentImages.where((i) => i.selectedForRotation).toList();
    if (selected.isEmpty || _bleService.connState != FrameConnState.connected) return;

    setState(() => _busy = true);
    try {
      // Upload any items (or sequence frames) that haven't been sent yet
      for (final image in selected) {
        if (image.isSequence) {
          final frameCount = image.sequenceFrameFiles?.length ?? image.sequenceFrames?.length ?? 0;
          for (int i = 0; i < frameCount; i++) {
            if ((image.sequenceDeviceIndices?[i]) == null) {
              final frameBytes = await image.loadSequenceFrame(i);
              if (frameBytes == null) continue;
              final tmp = SentImage(
                thumbnailBytes: image.sequenceThumbnails?[i],
                label: '${image.label} [${i + 1}]',
              );
              await tmp.persistFullBytes(frameBytes);
              final idx = await _bleService.uploadImageWithThumbnail(tmp);
              setState(() => image.sequenceDeviceIndices![i] = idx);
            }
          }
        } else if (image.deviceIndex == null && await image.loadFullBytes() != null) {
          final index = await _bleService.uploadImageWithThumbnail(image);
          setState(() => image.deviceIndex = index);
        }
      }

      // Flatten: single images contribute one index; sequences contribute all their frame indices
      final List<int> playlistIndices = [];
      for (final image in selected) {
        if (image.isSequence) {
          playlistIndices.addAll(image.uploadedSequenceIndices);
        } else if (image.deviceIndex != null) {
          playlistIndices.add(image.deviceIndex!);
        }
      }
      if (playlistIndices.isEmpty) return;

      await _bleService.startRotation(playlistIndices, _rotationSeconds.round());
      setState(() => _rotationActive = true);
    } catch (e) {
      _addLog('Start rotation failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopRotation() => _bleService.enqueueBleTask(_doStopRotation, highPriority: true);
  Future<void> _doStopRotation() async {
    if (_bleService.connState != FrameConnState.connected) return;
    setState(() => _busy = true);
    try {
      await _bleService.stopRotation();
      setState(() => _rotationActive = false);
    } catch (e) {
      _addLog('Stop rotation failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _formatDevice() => _bleService.enqueueBleTask(_doFormatDevice, highPriority: true);
  Future<void> _doFormatDevice() async {
    if (_bleService.connState != FrameConnState.connected || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Format device storage?'),
        content: const Text('Permanently delete all images? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Format')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await _bleService.sendFormatCommand();
      setState(() {
        _sentImages.clear();
        _activeIndex = null;
        _rotationActive = false;
      });
    } catch (e) {
      _addLog('Format failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelectedImages() => _bleService.enqueueBleTask(_doDeleteSelectedImages);
  Future<void> _doDeleteSelectedImages() async {
    final toDelete = _sentImages.where((i) => i.selectedForRotation).toList();
    if (toDelete.isEmpty || _bleService.connState != FrameConnState.connected || _busy) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${toDelete.length} item(s)?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;

    final originalOrder = List<SentImage>.from(_sentImages);
    final firstDeletedPos = originalOrder.indexOf(toDelete.first);
    final toKeep = _sentImages.where((i) => !i.selectedForRotation).toList();

    SentImage? neighbor;
    for (int i = firstDeletedPos + 1; i < originalOrder.length; i++) {
      if (toKeep.contains(originalOrder[i])) { neighbor = originalOrder[i]; break; }
    }
    if (neighbor == null) {
      for (int i = firstDeletedPos - 1; i >= 0; i--) {
        if (toKeep.contains(originalOrder[i])) { neighbor = originalOrder[i]; break; }
      }
    }

    setState(() => _busy = true);
    try {
      _addLog('Downloading ${toKeep.length} item(s) before format...');
      for (final image in toKeep) {
        if (image.isSequence) {
          // Sequence frames: download any that aren't already persisted to disk.
          final frameCount = image.sequenceFrameFiles?.length ?? image.sequenceFrames?.length ?? 0;
          if (frameCount == 0 && image.deviceIndex == null) continue; // never uploaded
          // For uploaded sequences that are no longer in memory/on disk, download each frame.
          final files = image.sequenceFrameFiles ?? [];
          for (int i = 0; i < frameCount; i++) {
            final hasOnDisk = i < files.length && files[i] != null && await files[i]!.exists();
            final hasInMemory = image.sequenceFrames != null && i < image.sequenceFrames!.length;
            if (!hasOnDisk && !hasInMemory) {
              final idx = image.sequenceDeviceIndices?[i];
              if (idx != null) {
                final downloaded = await _bleService.downloadImage(idx);
                // Store downloaded bytes in sequenceFrames; loadSequenceFrame checks this first.
                image.sequenceFrames ??= [];
                while (image.sequenceFrames!.length <= i) { image.sequenceFrames!.add(Uint8List(0)); }
                image.sequenceFrames![i] = downloaded;
              }
            }
          }
        } else if (await image.loadFullBytes() == null && image.deviceIndex != null) {
          // Single image: download from device and persist to disk.
          final downloaded = await _bleService.downloadImage(image.deviceIndex!);
          await image.persistFullBytes(downloaded);
        }
      }

      await _bleService.sendFormatCommand();

      setState(() {
        _sentImages.clear();
        _activeIndex = null;
        _rotationActive = false;
      });

      final List<String> failedLabels = [];
      for (final image in toKeep) {
        if (image.isSequence) {
          final frameCount = image.sequenceFrameFiles?.length ?? image.sequenceFrames?.length ?? 0;
          bool anyFailed = false;
          final newIndices = List<int?>.filled(frameCount, null);
          for (int i = 0; i < frameCount; i++) {
            try {
              final frameBytes = await image.loadSequenceFrame(i);
              if (frameBytes == null) { anyFailed = true; continue; }
              final tmp = SentImage(
                thumbnailBytes: image.sequenceThumbnails?[i],
                label: '${image.label} [${i + 1}]',
              );
              await tmp.persistFullBytes(frameBytes);
              newIndices[i] = await _bleService.uploadImageWithThumbnail(tmp);
            } catch (e) {
              _addLog('Failed to re-upload frame ${i + 1} of "${image.label}": $e');
              anyFailed = true;
            }
          }
          image.sequenceDeviceIndices = newIndices;
          setState(() => _sentImages.add(image));
          if (anyFailed) failedLabels.add(image.label);
        } else if (await image.loadFullBytes() != null) {
          try {
            image.deviceIndex = await _bleService.uploadImageWithThumbnail(image);
            setState(() => _sentImages.add(image));
          } catch (e) {
            _addLog('Failed to re-upload "${image.label}" during delete: $e');
            failedLabels.add(image.label);
          }
        }
      }

      setState(() {
        _activeIndex = neighbor != null && _sentImages.contains(neighbor) ? _sentImages.indexOf(neighbor) : null;
      });

      if (_activeIndex != null) {
        final nbr = neighbor!;
        if (nbr.isSequence) {
          final indices = nbr.uploadedSequenceIndices;
          if (indices.isNotEmpty) await _bleService.startRotation(indices, 1);
        } else if (nbr.deviceIndex != null) {
          await _bleService.showImageEntry(nbr.deviceIndex!);
        }
      }

      if (failedLabels.isNotEmpty && mounted) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Some items not restored'),
            content: Text(
              'The device was formatted successfully, but the following '
              'item(s) could not be fully re-uploaded (BLE error or disconnect):\n\n'
              '${failedLabels.join("\n")}\n\n'
              'Their bytes are still in the app — re-send them manually.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
            ],
          ),
        );
      }
    } catch (e) {
      _addLog('Delete failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendBrightness(int level) => _bleService.enqueueBleTask(() => _doSendBrightness(level), highPriority: true);
  Future<void> _doSendBrightness(int level) async {
    if (_bleService.connState != FrameConnState.connected) return;
    try {
      await _bleService.sendBrightness(level);
    } catch (e) {
      _addLog('Brightness failed: $e');
    }
  }

  String get _statusText {
    switch (_connState) {
      case FrameConnState.disconnected: return 'Disconnected';
      case FrameConnState.scanning: return 'Scanning...';
      case FrameConnState.connecting: return 'Connecting...';
      case FrameConnState.connected:
        return _syncing ? 'Connected (Syncing...)' : 'Connected';
    }
  }

  Color get _statusColor {
    switch (_connState) {
      case FrameConnState.connected: return Colors.green;
      case FrameConnState.disconnected: return Colors.red;
      default: return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connState == FrameConnState.connected;
    final active = _activeIndex != null ? _sentImages[_activeIndex!] : null;
    final anySelected = _sentImages.any((i) => i.selectedForRotation);
    final hasSelectedUnsent = _sentImages.any((i) {
      if (!i.selectedForRotation) return false;
      if (i.isSequence) return i.sequenceDeviceIndices?.any((idx) => idx == null) ?? true;
      return i.deviceIndex == null;
    });

    return Scaffold(
      backgroundColor: AppColors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.cyanGradient,
              ),
              child: const Icon(Icons.display_settings, size: 18, color: Colors.black),
            ),
            const SizedBox(width: 10),
            const Text(
              'AMOLED Frame',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: Colors.white,
                fontSize: 20,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _statusColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: _statusColor.withValues(alpha: 0.6),
                        blurRadius: 6,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _connState == FrameConnState.connected ? 'Connected' : 'Offline',
                  style: TextStyle(
                    color: _statusColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_connState == FrameConnState.disconnected) ...[
                  const SizedBox(width: 8),
                  NeumorphicIconButton(
                    icon: const Icon(Icons.refresh, size: 16, color: AppColors.cyanAccent),
                    onPressed: _connectToFrame,
                    borderRadius: 20,
                    padding: const EdgeInsets.all(6),
                    tooltip: 'Reconnect',
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Recessed Frame Canvas Area ─────────────────────────────────
              NeumorphicCard(
                isInset: true,
                borderRadius: 20,
                padding: const EdgeInsets.all(6),
                child: AspectRatio(
                  aspectRatio: panelHeight / panelWidth,
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
                    ),
                    child: (active?.thumbnailBytes == null)
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.image_outlined, size: 36, color: Colors.white.withValues(alpha: 0.2)),
                                const SizedBox(height: 6),
                                Text(
                                  'No frame image active',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.35),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: RotatedBox(
                              quarterTurns: active!.needsDisplayRotation ? 3 : 0,
                              child: Image.memory(active.thumbnailBytes!, fit: BoxFit.contain),
                            ),
                          ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Unified Add Content Button ─────────────────────────────────
              NeumorphicButton(
                onPressed: _showAddContentSheet,
                icon: const Icon(Icons.add_circle_outline, color: Colors.white, size: 20),
                label: 'Add Content',
                gradient: AppColors.primaryGradient,
                textColor: Colors.white,
              ),

              const SizedBox(height: 12),

              // ── Show on Device Button ──────────────────────────────────────
              NeumorphicButton(
                onPressed: (connected && _activeIndex != null && !_busy) ? () => _showImageEntry(_activeIndex!) : null,
                icon: const Icon(Icons.visibility, color: Colors.white, size: 20),
                label: 'Display Selected on Frame',
                gradient: (connected && _activeIndex != null && !_busy) ? AppColors.cyanGradient : null,
                textColor: Colors.white,
              ),

              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: const LinearProgressIndicator(
                      color: AppColors.cyanAccent,
                      backgroundColor: AppColors.surfaceElevated,
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              // ── Brightness Card ────────────────────────────────────────────
              NeumorphicCard(
                borderRadius: 18,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.brightness_6, color: AppColors.amberAccent, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: _brightness,
                        min: 0,
                        max: 255,
                        divisions: 51,
                        activeColor: AppColors.cyanAccent,
                        inactiveColor: AppColors.surfaceElevatedLighter,
                        onChanged: connected ? (v) => setState(() => _brightness = v) : null,
                        onChangeEnd: connected ? (v) => _sendBrightness(v.round()) : null,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceInset,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${(_brightness / 255 * 100).round()}%',
                        style: const TextStyle(
                          color: AppColors.cyanAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Playlist & Stored Images Card ──────────────────────────────
              IgnorePointer(
                ignoring: _rotationActive || _busy,
                child: Opacity(
                  opacity: (_rotationActive || _busy) ? 0.45 : 1.0,
                  child: NeumorphicCard(
                    borderRadius: 20,
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.collections_outlined, size: 18, color: AppColors.cyanAccent),
                                SizedBox(width: 8),
                                Text(
                                  'Frame Playlist',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                TextButton.icon(
                                  onPressed: !connected ? null : anySelected ? _deleteSelectedImages : _formatDevice,
                                  icon: const Icon(Icons.delete_outline, color: AppColors.pinkAccent, size: 16),
                                  label: Text(
                                    anySelected ? 'Delete' : 'Format',
                                    style: const TextStyle(color: AppColors.pinkAccent, fontSize: 13, fontWeight: FontWeight.w600),
                                  ),
                                ),
                                NeumorphicIconButton(
                                  icon: Icon(_allSelected ? Icons.deselect : Icons.select_all, size: 16, color: Colors.white70),
                                  onPressed: _sentImages.isEmpty ? null : _toggleSelectAll,
                                  borderRadius: 12,
                                  padding: const EdgeInsets.all(6),
                                  tooltip: _allSelected ? 'Deselect All' : 'Select All',
                                ),
                              ],
                            ),
                          ],
                        ),

                        const SizedBox(height: 8),

                        if (_sentImages.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(Icons.image_search, color: Colors.white24, size: 36),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'No images loaded yet.\nPick or create an image above to start.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.white38, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _sentImages.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 8),
                            itemBuilder: (context, i) {
                              final image = _sentImages[i];
                              final isActive = _activeIndex == i;

                              Widget thumbWidget;
                              if (image.isSequence &&
                                  image.sequenceThumbnails != null &&
                                  image.sequenceThumbnails!.length > 1) {
                                thumbWidget = _SequenceThumbnail(
                                  thumbnails: image.sequenceThumbnails!,
                                  needsDisplayRotation: image.needsDisplayRotation,
                                );
                              } else {
                                final thumb = image.thumbnailBytes;
                                thumbWidget = thumb == null
                                    ? Container(color: AppColors.surfaceElevated)
                                    : RotatedBox(
                                        quarterTurns: image.needsDisplayRotation ? 3 : 0,
                                        child: Image.memory(thumb, fit: BoxFit.cover),
                                      );
                              }

                              final frameCount = image.sequenceFrames?.length ?? image.sequenceFrameFiles?.length ?? 0;
                              final labelSuffix = image.isSequence ? ' ($frameCount frames)' : '';

                              return GestureDetector(
                                onTap: () => setState(() => _activeIndex = i),
                                child: NeumorphicCard(
                                  borderRadius: 14,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  color: isActive ? AppColors.surfaceElevatedLighter : AppColors.surface,
                                  border: isActive ? Border.all(color: AppColors.cyanAccent, width: 1.5) : null,
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: SizedBox(
                                          width: 60,
                                          height: 32,
                                          child: thumbWidget,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          '${image.label}$labelSuffix',
                                          style: TextStyle(
                                            color: isActive ? AppColors.cyanAccent : Colors.white,
                                            fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                                            fontSize: 13,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      NeumorphicIconButton(
                                        icon: const Icon(Icons.visibility_outlined, size: 16, color: Colors.white70),
                                        onPressed: connected ? () => _showImageEntry(i) : null,
                                        borderRadius: 10,
                                        padding: const EdgeInsets.all(6),
                                        tooltip: 'Show',
                                      ),
                                      const SizedBox(width: 6),
                                      GestureDetector(
                                        onTap: () => _toggleRotationSelected(image),
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: image.selectedForRotation ? AppColors.cyanAccent.withValues(alpha: 0.2) : AppColors.surfaceInset,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: image.selectedForRotation ? AppColors.cyanAccent : Colors.white24,
                                              width: 1.5,
                                            ),
                                          ),
                                          child: Icon(
                                            image.selectedForRotation ? Icons.check : Icons.circle_outlined,
                                            size: 14,
                                            color: image.selectedForRotation ? AppColors.cyanAccent : Colors.white38,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),

                        const SizedBox(height: 12),

                        if (hasSelectedUnsent)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: NeumorphicButton(
                              onPressed: (connected && !_busy) ? _sendSelectedToDevice : null,
                              icon: const Icon(Icons.cloud_upload_outlined, color: AppColors.cyanAccent, size: 18),
                              label: 'Send Selected to Device',
                            ),
                          ),

                        // Rotation duration slider
                        Row(
                          children: [
                            const Icon(Icons.timer_outlined, color: AppColors.cyanAccent, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Slider(
                                value: _rotationSeconds,
                                min: 2,
                                max: 30,
                                divisions: 28,
                                activeColor: AppColors.cyanAccent,
                                inactiveColor: AppColors.surfaceElevatedLighter,
                                onChanged: (v) => setState(() => _rotationSeconds = v),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceInset,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${_rotationSeconds.round()}s',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Start / Stop Rotation Button ───────────────────────────────
              NeumorphicButton(
                onPressed: (!connected || _busy) ? null : _rotationActive ? _stopRotation : (anySelected ? _startRotation : null),
                gradient: _rotationActive
                    ? const LinearGradient(colors: [Colors.redAccent, Colors.deepOrangeAccent])
                    : AppColors.primaryGradient,
                icon: Icon(_rotationActive ? Icons.stop_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 22),
                label: _rotationActive ? 'Stop Playlist Rotation' : 'Start Playlist Rotation',
                textColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
