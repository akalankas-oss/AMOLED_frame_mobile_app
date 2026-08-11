import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/frame_connection.dart';
import '../ble/frame_protocol.dart';
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
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar;
  BluetoothCharacteristic? _txChar;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  int _mtu = 23;
  Completer<int>? _pendingIndexCompleter;

  bool _awaitingDownloadHeader = false;
  int _downloadExpectedSize = 0;
  final BytesBuilder _downloadBuilder = BytesBuilder();
  Completer<Uint8List>? _pendingDownloadCompleter;

  bool _busy = false;

  final List<Future<void> Function()> _bleQueue = [];
  bool _bleProcessing = false;

  Future<T> _enqueueBleTask<T>(Future<T> Function() task, {bool highPriority = false}) {
    final completer = Completer<T>();
    final taskWrapper = () async {
      try {
        final result = await task();
        if (!completer.isCompleted) completer.complete(result);
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      }
    };
    if (highPriority) {
      _bleQueue.insert(0, taskWrapper);
    } else {
      _bleQueue.add(taskWrapper);
    }
    _processBleQueue();
    return completer.future;
  }

  Future<void> _processBleQueue() async {
    if (_bleProcessing) return;
    _bleProcessing = true;
    while (_bleQueue.isNotEmpty) {
      final task = _bleQueue.removeAt(0);
      try { await task(); } catch (e) { print('BLE Task Error: $e'); }
    }
    _bleProcessing = false;
  }

  bool _syncing = false;
  bool _syncedOnce = false;
  double _brightness = 255;
  final List<String> _log = [];

  final List<SentImage> _sentImages = [];
  int? _activeIndex;
  double _rotationSeconds = 5;
  bool _rotationActive = false;

  @override
  void initState() {
    super.initState();
    _connectToFrame();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
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
    if (_connState == FrameConnState.scanning || _connState == FrameConnState.connecting) {
      return;
    }
    if (!await _ensurePermissions()) {
      _addLog('Bluetooth/location permissions denied');
      return;
    }

    setState(() => _connState = FrameConnState.scanning);
    _addLog('Scanning for AMOLED-Frame...');

    try {
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.onScanResults.listen((results) async {
        for (final r in results) {
          if (r.device.platformName == 'AMOLED-Frame') {
            await FlutterBluePlus.stopScan();
            await _scanSub?.cancel();
            await _connectDevice(r.device);
            return;
          }
        }
      });
      await FlutterBluePlus.startScan(
        withServices: [nusServiceUuid],
        timeout: const Duration(seconds: 10),
      );
      
      // Wait for the scan to finish
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
      
      if (mounted && _connState == FrameConnState.scanning) {
        _addLog('Scan timed out. Device not found.');
        setState(() => _connState = FrameConnState.disconnected);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Scan timed out. Device not found.')),
          );
        }
      }
    } catch (e) {
      _addLog('Scan failed: $e');
      if (mounted) {
        setState(() => _connState = FrameConnState.disconnected);
      }
    }
  }

  Future<void> _connectDevice(BluetoothDevice device) async {
    setState(() => _connState = FrameConnState.connecting);
    _addLog('Found device, connecting...');
    _device = device;

    _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _addLog('Disconnected');
        _notifySub?.cancel();
        setState(() {
          _connState = FrameConnState.disconnected;
          _rxChar = null;
          _txChar = null;
          _syncedOnce = false;
        });
      }
    });

    try {
      await device.connect(timeout: const Duration(seconds: 10));
      try {
        _mtu = await device.requestMtu(517);
      } catch (_) {
        _mtu = 23;
      }

      final services = await device.discoverServices();
      final nus = services.firstWhere((s) => s.uuid == nusServiceUuid);
      _rxChar = nus.characteristics.firstWhere((c) => c.uuid == rxCharUuid);
      _txChar = nus.characteristics.firstWhere((c) => c.uuid == txCharUuid);

      await _txChar!.setNotifyValue(true);
      _notifySub = _txChar!.lastValueStream.listen(_onNotify);

      _addLog('Connected to ${device.platformName}');
      setState(() => _connState = FrameConnState.connected);
      await _syncFromDevice();
    } catch (e) {
      _addLog('Connect failed: $e');
      setState(() => _connState = FrameConnState.disconnected);
    }
  }

  void _onNotify(List<int> value) {
    if (value.isEmpty) return;

    if (_awaitingDownloadHeader) {
      if (value.length >= 5 && value[0] == downloadHeaderStatus) {
        _downloadExpectedSize = value[1] | (value[2] << 8) | (value[3] << 16) | (value[4] << 24);
        _awaitingDownloadHeader = false;
        _downloadBuilder.clear();
        if (_downloadExpectedSize == 0) {
          _pendingDownloadCompleter?.complete(Uint8List(0));
        }
      } else {
        _pendingDownloadCompleter?.completeError('bad download response (0x${value[0].toRadixString(16)})');
        _awaitingDownloadHeader = false;
      }
      return;
    }

    if (_downloadExpectedSize > 0 && _downloadBuilder.length < _downloadExpectedSize) {
      _downloadBuilder.add(value);
      if (_downloadBuilder.length >= _downloadExpectedSize) {
        final bytes = _downloadBuilder.toBytes();
        _downloadExpectedSize = 0;
        _pendingDownloadCompleter?.complete(bytes);
      }
      return;
    }

    final status = value[0];
    _addLog('Device: ${statusNames[status] ?? 'unknown (0x${status.toRadixString(16)})'}');

    final completer = _pendingIndexCompleter;
    if (status == 0x06 && value.length >= 5 && completer != null && !completer.isCompleted) {
      final index = value[1] | (value[2] << 8) | (value[3] << 16) | (value[4] << 24);
      completer.complete(index);
    }
  }

  Future<void> _syncFromDevice() async {
    if (_rxChar == null) return;
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
          _syncedOnce = true;
        });
      }
    }
  }

  Future<void> _syncBrightnessFromDevice() async {
    try {
      _pendingIndexCompleter = Completer<int>();
      await _sendChunked(buildHeader(getBrightnessCmdMagic, 0));
      final level = await _pendingIndexCompleter!.future.timeout(const Duration(seconds: 5));
      setState(() => _brightness = level.toDouble().clamp(0, 255));
      _addLog('Synced brightness: ${(_brightness / 255 * 100).round()}%');
    } catch (e) {
      _addLog('Could not sync brightness: $e');
    } finally {
      _pendingIndexCompleter = null;
    }
  }

  Future<void> _syncImageListFromDevice() async {
    try {
      _pendingIndexCompleter = Completer<int>();
      await _sendChunked(buildHeader(listCountCmdMagic, 0));
      final count = await _pendingIndexCompleter!.future.timeout(const Duration(seconds: 5));
      _pendingIndexCompleter = null;

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
          thumb = await _downloadThumbnail(index);
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
    } finally {
      _pendingIndexCompleter = null;
    }
  }

  Future<void> _syncPlaylistFromDevice() async {
    try {
      _pendingIndexCompleter = Completer<int>();
      await _sendChunked(buildHeader(getPlaylistCmdMagic, 0));
      final packed = await _pendingIndexCompleter!.future.timeout(const Duration(seconds: 5));
      _pendingIndexCompleter = null;

      final active = (packed & 0x80000000) != 0;
      final interval = packed & 0x7FFFFFFF;

      final raw = await _downloadRaw(downloadPlaylistCmdMagic, 0);
      final playlistIndices = <int>{};
      for (int i = 0; i + 4 <= raw.length; i += 4) {
        playlistIndices.add(raw[i] | (raw[i + 1] << 8) | (raw[i + 2] << 16) | (raw[i + 3] << 24));
      }

      setState(() {
        for (final image in _sentImages) {
          image.selectedForRotation = image.deviceIndex != null && playlistIndices.contains(image.deviceIndex);
        }
        if (interval >= 2 && interval <= 30) {
          _rotationSeconds = interval.toDouble();
        }
        _rotationActive = active;
      });
    } catch (e) {
      _addLog('Could not sync rotation state: $e');
    } finally {
      _pendingIndexCompleter = null;
    }
  }

  // Simple, original behavior: the picked photo is added directly, with no
  // text/emoji/sticker editor. Still runs through fitImageToPanel() so the
  // stored bytes are in the panel's expected format — makeThumbnail() (and
  // the BLE upload pipeline) need that; without it, raw multi-megapixel
  // gallery photos produced garbled/corrupted thumbnails.
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

  // Large gallery photos (many megapixels) being redrawn on every touch-move
  // frame during item dragging can cause enough jank to make emoji/sticker
  // dragging feel broken or laggy. The panel only needs 192x960 worth of
  // detail, so downscaling before editing keeps things smooth without any
  // visible quality loss on the final panel.
  Future<Uint8List> _downscaleForEditing(Uint8List bytes, {int maxDimension = 1000}) async {
    // Use image_lib (not the Flutter codec) so we can call bakeOrientation()
    // reliably regardless of platform. Without this, portrait gallery photos
    // open sideways in the editor because the Flutter codec may or may not
    // auto-apply the EXIF orientation depending on the OS version.
    final rawDecoded = image_lib.decodeImage(bytes);
    if (rawDecoded == null) return bytes; // Fallback: pass original bytes unchanged
    final oriented = image_lib.bakeOrientation(rawDecoded);

    if (oriented.width <= maxDimension && oriented.height <= maxDimension) {
      // No resize needed — just re-encode with orientation baked in.
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

  // Full editing flow: pick a photo from the gallery, then open the
  // text/emoji/sticker editor on it before adding it to the list.
  Future<void> _createImageWithEditing() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final rawBytes = await file.readAsBytes();
    try {
      // Pass a downscaled copy of the picked photo to the editor — do NOT
      // pre-process it with fitImageToPanel() here, since that function
      // center-crops to the panel's aspect ratio, cutting off the edges
      // before the editor even gets a chance to show the whole photo.
      // The editor's own canvas (fixed at 192x960, BoxFit.contain) shrinks
      // the entire photo to fit with nothing cut off. From there, the
      // "Move/zoom photo" button lets you pinch-zoom (or use the +/-
      // buttons) to zoom in on any specific part if you don't want the
      // whole photo.
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

  // Opens the banner composer, then queues every generated frame as an
  // image, already selected for rotation. Frames play back through the
  // existing rotation/BLE pipeline — press "Send Selected to Device" then
  // "Start Rotation" to actually show the banner on the panel.
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
    }
  }

  Future<void> _sendChunked(Uint8List payload) async {
    final chunkSize = (_mtu - 3).clamp(20, 500);
    for (int offset = 0; offset < payload.length; offset += chunkSize) {
      // Re-check connection on every chunk: a disconnect mid-upload would
      // otherwise throw a null-dereference instead of a clear message.
      if (_rxChar == null) throw Exception('Disconnected during transfer');
      final end = (offset + chunkSize < payload.length) ? offset + chunkSize : payload.length;
      await _rxChar!.write(payload.sublist(offset, end), withoutResponse: false);
    }
  }

  Future<int> _uploadImageGetIndex(Uint8List jpeg) async {
    _pendingIndexCompleter = Completer<int>();
    try {
      final payload = Uint8List.fromList(buildHeader(jpegHeaderMagic, jpeg.length) + jpeg);
      await _sendChunked(payload);
      return await _pendingIndexCompleter!.future.timeout(const Duration(seconds: 5));
    } finally {
      _pendingIndexCompleter = null;
    }
  }

  Future<void> _uploadThumbnail(Uint8List thumbJpeg) async {
    try {
      final payload = Uint8List.fromList(buildHeader(thumbnailHeaderMagic, thumbJpeg.length) + thumbJpeg);
      await _sendChunked(payload);
    } catch (e) {
      _addLog('Thumbnail upload failed: $e');
    }
  }

  Future<int> _uploadImageWithThumbnail(SentImage image) async {
    final index = await _uploadImageGetIndex(image.fullBytes!);
    image.thumbnailBytes ??= makeThumbnail(image.fullBytes!);
    await _uploadThumbnail(image.thumbnailBytes!);
    return index;
  }

  Future<Uint8List> _downloadRaw(int magic, int secondField, {Duration timeout = const Duration(seconds: 10)}) async {
    if (_rxChar == null) throw Exception('Not connected');
    _awaitingDownloadHeader = true;
    _downloadBuilder.clear();
    _downloadExpectedSize = 0;
    _pendingDownloadCompleter = Completer<Uint8List>();
    try {
      await _sendChunked(buildHeader(magic, secondField));
      return await _pendingDownloadCompleter!.future.timeout(timeout);
    } finally {
      _awaitingDownloadHeader = false;
      _pendingDownloadCompleter = null;
    }
  }

  Future<Uint8List> _downloadImage(int index) => _downloadRaw(downloadCmdMagic, index, timeout: const Duration(seconds: 30));
  Future<Uint8List> _downloadThumbnail(int index) => _downloadRaw(downloadThumbCmdMagic, index);

  Future<void> _sendFormatCommand() async {
    _pendingIndexCompleter = Completer<int>();
    try {
      await _sendChunked(buildHeader(formatCmdMagic, 0));
      await _pendingIndexCompleter!.future.timeout(const Duration(seconds: 30));
    } finally {
      _pendingIndexCompleter = null;
    }
  }

  Future<void> _showImageEntry(int index) async {
    if (_rxChar == null || _busy) return;
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
        deviceIndex = await _uploadImageWithThumbnail(image);
        setState(() => image.deviceIndex = deviceIndex);
      } else {
        throw Exception('No data available');
      }
      await _sendChunked(buildHeader(showIndexCmdMagic, deviceIndex));
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

  Future<void> _sendSelectedToDevice() => _enqueueBleTask(_doSendSelectedToDevice);
  Future<void> _doSendSelectedToDevice() async {
    if (_rxChar == null || _busy) return;
    final toSend = _sentImages.where((i) => i.selectedForRotation && i.deviceIndex == null && i.fullBytes != null).toList();
    if (toSend.isEmpty) return;

    setState(() => _busy = true);
    try {
      for (final image in toSend) {
        final index = await _uploadImageWithThumbnail(image);
        setState(() => image.deviceIndex = index);
      }
      _addLog('Sent ${toSend.length} image(s) to device');
    } catch (e) {
      _addLog('Send failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startRotation() => _enqueueBleTask(_doStartRotation);
  Future<void> _doStartRotation() async {
    final selected = _sentImages.where((i) => i.selectedForRotation).toList();
    if (selected.isEmpty || _rxChar == null) return;

    setState(() => _busy = true);
    try {
      for (final image in selected) {
        if (image.deviceIndex == null && image.fullBytes != null) {
          final index = await _uploadImageWithThumbnail(image);
          setState(() => image.deviceIndex = index);
        }
      }

      final usable = selected.where((i) => i.deviceIndex != null).toList();
      if (usable.isEmpty) return;

      await _sendChunked(buildHeader(playlistClearMagic, 0));
      for (final image in usable) {
        await _sendChunked(buildHeader(playlistAddMagic, image.deviceIndex!));
      }
      await _sendChunked(buildHeader(playlistStartMagic, _rotationSeconds.round()));
      setState(() => _rotationActive = true);
    } catch (e) {
      _addLog('Start rotation failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopRotation() => _enqueueBleTask(_doStopRotation, highPriority: true);
  Future<void> _doStopRotation() async {
    if (_rxChar == null) return;
    setState(() => _busy = true);
    try {
      await _sendChunked(buildHeader(playlistStopMagic, 0));
      setState(() => _rotationActive = false);
    } catch (e) {
      _addLog('Stop rotation failed: $e');
    } finally {
      _pendingIndexCompleter = null;
      // Fix: _busy was never reset here, causing permanent UI deadlock after
      // pressing Stop Rotation (all buttons frozen, spinner stuck forever).
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _formatDevice() => _enqueueBleTask(_doFormatDevice, highPriority: true);
  Future<void> _doFormatDevice() async {
    if (_rxChar == null || _busy) return;
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
      await _sendFormatCommand();
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

  Future<void> _deleteSelectedImages() => _enqueueBleTask(_doDeleteSelectedImages);
  Future<void> _doDeleteSelectedImages() async {
    final toDelete = _sentImages.where((i) => i.selectedForRotation).toList();
    if (toDelete.isEmpty || _rxChar == null || _busy) return;

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
      // Phase 1: Download any on-device images we intend to keep so we
      // have local copies before the irreversible format step.
      _addLog('Downloading ${toKeep.length} image(s) before format...');
      for (final image in toKeep) {
        if (image.fullBytes == null && image.deviceIndex != null) {
          image.fullBytes = await _downloadImage(image.deviceIndex!);
        }
      }

      // Phase 2: Irreversible — wipe the device storage.
      await _sendFormatCommand();

      setState(() {
        _sentImages.clear();
        _activeIndex = null;
        _rotationActive = false;
      });

      // Phase 3: Re-upload the images we kept. Track failures so we can
      // inform the user exactly which images were not recovered.
      final List<String> failedLabels = [];
      for (final image in toKeep) {
        if (image.fullBytes != null) {
          try {
            image.deviceIndex = await _uploadImageWithThumbnail(image);
            setState(() {
              _sentImages.add(image);
            });
          } catch (e) {
            _addLog('Failed to re-upload "${image.label}" during delete: $e');
            failedLabels.add(image.label);
            // Don't break — try to re-upload the remaining images.
          }
        }
      }

      setState(() {
        _activeIndex = neighbor != null && _sentImages.contains(neighbor) ? _sentImages.indexOf(neighbor) : null;
      });

      if (_activeIndex != null && neighbor!.deviceIndex != null) {
        await _sendChunked(buildHeader(showIndexCmdMagic, neighbor.deviceIndex!));
      }

      // Inform the user if any images could not be recovered after the format.
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

  Future<void> _sendBrightness(int level) => _enqueueBleTask(() => _doSendBrightness(level), highPriority: true);
  Future<void> _doSendBrightness(int level) async {
    if (_rxChar == null) return;
    try {
      await _sendChunked(buildHeader(brightnessCmdMagic, level));
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
                aspectRatio: panelWidth / panelHeight,
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
