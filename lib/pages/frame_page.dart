import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/frame_ble_service.dart';
import '../ble/frame_connection.dart';
import '../models/sent_image.dart';
import '../utils/image_utils.dart';
import 'flash_banner_page.dart';
import 'image_editor_page.dart';
import 'text_composer_page.dart';

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
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
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
        if (res.interval >= 2 && res.interval <= 30) {
          _rotationSeconds = res.interval.toDouble();
        }
        _rotationActive = res.active;
      });
    } catch (e) {
      _addLog('Could not sync rotation state: $e');
    }
  }

  Future<void> _pickImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    try {
      final fitted = fitImageToPanel(bytes);
      final thumb = makeThumbnail(fitted);
      setState(() {
        _sentImages.add(SentImage(
          fullBytes: fitted,
          thumbnailBytes: thumb,
          label: 'Image ${_sentImages.length + 1}',
        ));
        _activeIndex = _sentImages.length - 1;
      });
    } catch (e) {
      _addLog('Image processing failed: $e');
    }
  }

  Future<Uint8List> _downscaleForEditing(Uint8List bytes, {int maxDimension = 1000}) async {
    final rawDecoded = image_lib.decodeImage(bytes);
    if (rawDecoded == null) return bytes;
    final oriented = image_lib.bakeOrientation(rawDecoded);

    if (oriented.width <= maxDimension && oriented.height <= maxDimension) {
      return Uint8List.fromList(image_lib.encodeJpg(oriented, quality: 92));
    }
    final scale = maxDimension / (oriented.width > oriented.height ? oriented.width : oriented.height);
    final resized = image_lib.copyResize(
      oriented,
      width: (oriented.width * scale).round(),
      height: (oriented.height * scale).round(),
    );
    return Uint8List.fromList(image_lib.encodeJpg(resized, quality: 92));
  }

  Future<void> _createImageWithEditing() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final rawBytes = await file.readAsBytes();
    try {
      final bytes = await _downscaleForEditing(rawBytes);
      if (!mounted) return;
      final editedBytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(builder: (_) => ImageEditorPage(imageBytes: bytes)),
      );

      if (editedBytes != null) {
        final thumb = makeThumbnail(editedBytes);
        setState(() {
          _sentImages.add(SentImage(fullBytes: editedBytes, thumbnailBytes: thumb, label: 'Image ${_sentImages.length + 1}'));
          _activeIndex = _sentImages.length - 1;
        });
      }
    } catch (e) {
      _addLog('Image processing failed: $e');
    }
  }

  Future<void> _openFlashBanner() async {
    final frames = await Navigator.of(context).push<List<Uint8List>>(
      MaterialPageRoute(builder: (_) => const FlashBannerPage()),
    );
    if (frames == null || frames.isEmpty) return;
    if (!mounted) return;
    setState(() {
      final baseIndex = _sentImages.length;
      for (int i = 0; i < frames.length; i++) {
        final thumb = makeThumbnail(frames[i]);
        final image = SentImage(
          fullBytes: frames[i],
          thumbnailBytes: thumb,
          label: 'Banner ${baseIndex + i + 1}',
        );
        image.selectedForRotation = true;
        _sentImages.add(image);
      }
      _activeIndex = _sentImages.length - 1;
    });
    _addLog('Added ${frames.length} banner frame(s) — press "Send Selected to Device" then "Start Rotation".');
  }

  Future<void> _createTextImage() async {
    final bytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const TextComposerPage()),
    );
    if (bytes != null) {
      if (!mounted) return;
      final thumb = makeThumbnail(bytes);
      setState(() {
        _sentImages.add(SentImage(fullBytes: bytes, thumbnailBytes: thumb, label: 'Text ${_sentImages.length + 1}'));
        _activeIndex = _sentImages.length - 1;
      });
    }
  }

  Future<void> _showImageEntry(int index) async {
    if (_bleService.connState != FrameConnState.connected || _busy) return;
    final image = _sentImages[index];
    setState(() {
      _activeIndex = index;
      _busy = true;
    });
    try {
      int deviceIndex;
      if (image.deviceIndex != null) {
        deviceIndex = image.deviceIndex!;
      } else if (image.fullBytes != null) {
        deviceIndex = await _bleService.uploadImageWithThumbnail(image);
        setState(() => image.deviceIndex = deviceIndex);
      } else {
        throw Exception('No data available');
      }
      await _bleService.showImageEntry(deviceIndex);
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
    final toSend = _sentImages.where((i) => i.selectedForRotation && i.deviceIndex == null && i.fullBytes != null).toList();
    if (toSend.isEmpty) return;

    setState(() => _busy = true);
    try {
      for (final image in toSend) {
        final index = await _bleService.uploadImageWithThumbnail(image);
        setState(() => image.deviceIndex = index);
      }
      _addLog('Sent ${toSend.length} image(s) to device');
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
      for (final image in selected) {
        if (image.deviceIndex == null && image.fullBytes != null) {
          final index = await _bleService.uploadImageWithThumbnail(image);
          setState(() => image.deviceIndex = index);
        }
      }

      final usable = selected.where((i) => i.deviceIndex != null).map((i) => i.deviceIndex!).toList();
      if (usable.isEmpty) return;

      await _bleService.startRotation(usable, _rotationSeconds.round());
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
        title: Text('Delete ${toDelete.length} image(s)?'),
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
      if (toKeep.contains(originalOrder[i])) {
        neighbor = originalOrder[i];
        break;
      }
    }
    if (neighbor == null) {
      for (int i = firstDeletedPos - 1; i >= 0; i--) {
        if (toKeep.contains(originalOrder[i])) {
          neighbor = originalOrder[i];
          break;
        }
      }
    }

    setState(() => _busy = true);
    try {
      _addLog('Downloading ${toKeep.length} image(s) before format...');
      for (final image in toKeep) {
        if (image.fullBytes == null && image.deviceIndex != null) {
          image.fullBytes = await _bleService.downloadImage(image.deviceIndex!);
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
        if (image.fullBytes != null) {
          try {
            image.deviceIndex = await _bleService.uploadImageWithThumbnail(image);
            setState(() {
              _sentImages.add(image);
            });
          } catch (e) {
            _addLog('Failed to re-upload "${image.label}" during delete: $e');
            failedLabels.add(image.label);
          }
        }
      }

      setState(() {
        _activeIndex = neighbor != null && _sentImages.contains(neighbor) ? _sentImages.indexOf(neighbor) : null;
      });

      if (_activeIndex != null && neighbor!.deviceIndex != null) {
        await _bleService.showImageEntry(neighbor.deviceIndex!);
      }

      if (failedLabels.isNotEmpty && mounted) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Some images not restored'),
            content: Text(
              'The device was formatted successfully, but the following '
              'image(s) could not be re-uploaded (BLE error or disconnect) '
              'and are no longer on the device:\n\n'
              '${failedLabels.join('\n')}\n\n'
              'Their bytes are still in the app — re-send them manually.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      _addLog('Delete failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
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
    final hasSelectedUnsent = _sentImages.any((i) => i.selectedForRotation && i.deviceIndex == null && i.fullBytes != null);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('AMOLED Frame'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(Icons.circle, size: 12, color: _statusColor),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_statusText, style: Theme.of(context).textTheme.titleMedium)),
                  if (_connState == FrameConnState.disconnected)
                    TextButton(onPressed: _connectToFrame, child: const Text('Reconnect')),
                ],
              ),
              const SizedBox(height: 16),
              AspectRatio(
                aspectRatio: panelHeight / panelWidth,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: active?.fullBytes == null
                      ? const Center(child: Text('No image selected', style: TextStyle(color: Colors.grey)))
                      : ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: RotatedBox(
                      quarterTurns: active!.needsDisplayRotation ? 3 : 0,
                      child: Image.memory(active.fullBytes!, fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickImage,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Pick Image'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _createImageWithEditing,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('Create Image'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _createTextImage,
                      icon: const Icon(Icons.text_fields),
                      label: const Text('Create Text'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _openFlashBanner,
                      icon: const Icon(Icons.bolt),
                      label: const Text('Flash Banner'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: (connected && _activeIndex != null && !_busy) ? () => _showImageEntry(_activeIndex!) : null,
                      icon: const Icon(Icons.visibility),
                      label: const Text('Show'),
                    ),
                  ),
                ],
              ),
              if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.brightness_6),
                  Expanded(
                    child: Slider(
                      value: _brightness,
                      min: 0,
                      max: 255,
                      divisions: 51,
                      onChanged: connected ? (v) => setState(() => _brightness = v) : null,
                      onChangeEnd: connected ? (v) => _sendBrightness(v.round()) : null,
                    ),
                  ),
                  SizedBox(width: 40, child: Text('${(_brightness / 255 * 100).round()}%')),
                ],
              ),
              const SizedBox(height: 12),
              IgnorePointer(
                ignoring: _rotationActive || _busy,
                child: Opacity(
                  opacity: (_rotationActive || _busy) ? 0.4 : 1.0,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Images', style: Theme.of(context).textTheme.labelLarge),
                            TextButton.icon(
                              onPressed: !connected ? null : anySelected ? _deleteSelectedImages : _formatDevice,
                              icon: const Icon(Icons.delete_forever_outlined, color: Colors.red),
                              label: Text(anySelected ? 'Delete Selected' : 'Format Device', style: const TextStyle(color: Colors.red)),
                            ),
                            IconButton(
                              icon: Icon(_allSelected ? Icons.deselect : Icons.select_all),
                              onPressed: _sentImages.isEmpty ? null : _toggleSelectAll,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (_sentImages.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text('Pick or create an image to get started.', style: TextStyle(color: Colors.grey)),
                          )
                        else
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _sentImages.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 4),
                            itemBuilder: (context, i) {
                              final image = _sentImages[i];
                              final isActive = _activeIndex == i;
                              final thumb = image.thumbnailBytes ?? image.fullBytes;
                              return InkWell(
                                onTap: () => setState(() => _activeIndex = i),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(4),
                                    border: isActive ? Border.all(color: Theme.of(context).colorScheme.primary) : null,
                                  ),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: SizedBox(
                                          width: 60,
                                          height: 30,
                                          child: thumb == null
                                              ? Container(color: Colors.grey.shade300)
                                              : RotatedBox(quarterTurns: image.needsDisplayRotation ? 3 : 0, child: Image.memory(thumb, fit: BoxFit.cover)),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(image.label)),
                                      IconButton(
                                        icon: const Icon(Icons.visibility_outlined),
                                        onPressed: connected ? () => _showImageEntry(i) : null,
                                      ),
                                      IconButton(
                                        icon: Icon(image.selectedForRotation ? Icons.check_box : Icons.check_box_outline_blank),
                                        onPressed: () => _toggleRotationSelected(image),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: (connected && hasSelectedUnsent && !_busy) ? _sendSelectedToDevice : null,
                            icon: const Icon(Icons.cloud_upload_outlined),
                            label: const Text('Send Selected to Device'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Icon(Icons.timer_outlined),
                            Expanded(
                              child: Slider(
                                value: _rotationSeconds,
                                min: 2,
                                max: 30,
                                divisions: 28,
                                onChanged: (v) => setState(() => _rotationSeconds = v),
                              ),
                            ),
                            SizedBox(width: 40, child: Text('${_rotationSeconds.round()}s')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: (!connected || _busy) ? null : _rotationActive ? _stopRotation : (anySelected ? _startRotation : null),
                icon: Icon(_rotationActive ? Icons.stop : Icons.play_arrow),
                label: Text(_rotationActive ? 'Stop Rotation' : 'Start Rotation'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
