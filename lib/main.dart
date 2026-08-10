// ============================================================================
// AMOLED FRAME APP — BUILD MARKER: v25-frame-border-autorotate-pencil
// If you don't see this comment in the file you're running, you are NOT
// running this version — replace your project's lib/main.dart with this
// exact file, then run `flutter clean && flutter pub get && flutter run`.
// ============================================================================
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'image_utils.dart';
import 'text_composer_page.dart';

void main() {
  runApp(const AmoledFrameApp());
}

class AmoledFrameApp extends StatelessWidget {
  const AmoledFrameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AMOLED Frame',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const FramePage(),
    );
  }
}

// Matches the Nordic UART Service exposed by the ESP32-P4 firmware
final Guid _nusServiceUuid = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
final Guid _rxCharUuid = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e'); // write
final Guid _txCharUuid = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e'); // notify

const int _jpegHeaderMagic = 0x4A504731;
const int _thumbnailHeaderMagic = 0x54484D42;
const int _showIndexCmdMagic = 0x53484958;
const int _brightnessCmdMagic = 0x42524954;
const int _playlistAddMagic = 0x50414444;
const int _playlistClearMagic = 0x50434C52;
const int _playlistStartMagic = 0x50535254;
const int _playlistStopMagic = 0x50535450;
const int _formatCmdMagic = 0x46524D54;
const int _listCountCmdMagic = 0x4C534354;
const int _downloadCmdMagic = 0x444E4C44;
const int _downloadThumbCmdMagic = 0x444E4C54;
const int _getBrightnessCmdMagic = 0x47425254;
const int _getPlaylistCmdMagic = 0x47504C53;
const int _downloadPlaylistCmdMagic = 0x44504C53;
const int _downloadHeaderStatus = 0x07;

const Map<int, String> _statusNames = {
  0x06: 'ACK_OK',
  0xE1: 'NACK_HEADER',
  0xE2: 'NACK_TOO_BIG',
  0xE3: 'NACK_NO_IMAGE',
  0xE4: 'NACK_BAD_INDEX',
};

int _crc16Ccitt(List<int> data) {
  int crc = 0xFFFF;
  for (final byte in data) {
    crc ^= (byte & 0xFF) << 8;
    for (int i = 0; i < 8; i++) {
      if ((crc & 0x8000) != 0) {
        crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
      } else {
        crc = (crc << 1) & 0xFFFF;
      }
    }
  }
  return crc;
}

Uint8List _buildHeader(int magic, int secondField) {
  final bytes = ByteData(10);
  bytes.setUint32(0, magic, Endian.little);
  bytes.setUint32(4, secondField, Endian.little);
  final crc = _crc16Ccitt(bytes.buffer.asUint8List(0, 8));
  bytes.setUint16(8, crc, Endian.little);
  return bytes.buffer.asUint8List();
}

enum FrameConnState { disconnected, scanning, connecting, connected }

class _SentImage {
  _SentImage({
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

  final List<_SentImage> _sentImages = [];
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
        withServices: [_nusServiceUuid],
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
      final nus = services.firstWhere((s) => s.uuid == _nusServiceUuid);
      _rxChar = nus.characteristics.firstWhere((c) => c.uuid == _rxCharUuid);
      _txChar = nus.characteristics.firstWhere((c) => c.uuid == _txCharUuid);

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
      if (value.length >= 5 && value[0] == _downloadHeaderStatus) {
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
    _addLog('Device: ${_statusNames[status] ?? 'unknown (0x${status.toRadixString(16)})'}');

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
      await _sendChunked(_buildHeader(_getBrightnessCmdMagic, 0));
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
      await _sendChunked(_buildHeader(_listCountCmdMagic, 0));
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
          _SentImage(thumbnailBytes: thumb, label: 'Device Image $index', deviceIndex: index),
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
      await _sendChunked(_buildHeader(_getPlaylistCmdMagic, 0));
      final packed = await _pendingIndexCompleter!.future.timeout(const Duration(seconds: 5));
      _pendingIndexCompleter = null;

      final active = (packed & 0x80000000) != 0;
      final interval = packed & 0x7FFFFFFF;

      final raw = await _downloadRaw(_downloadPlaylistCmdMagic, 0);
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
        _sentImages.add(_SentImage(
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
          _sentImages.add(_SentImage(fullBytes: editedBytes, thumbnailBytes: thumb, label: 'Image ${_sentImages.length + 1}'));
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
        final image = _SentImage(
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
          _sentImages.add(_SentImage(fullBytes: editedBytes, thumbnailBytes: thumb, label: 'Image ${_sentImages.length + 1}'));
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
      final payload = Uint8List.fromList(_buildHeader(_jpegHeaderMagic, jpeg.length) + jpeg);
      await _sendChunked(payload);
      return await _pendingIndexCompleter!.future.timeout(const Duration(seconds: 5));
    } finally {
      _pendingIndexCompleter = null;
    }
  }

  Future<void> _uploadThumbnail(Uint8List thumbJpeg) async {
    try {
      final payload = Uint8List.fromList(_buildHeader(_thumbnailHeaderMagic, thumbJpeg.length) + thumbJpeg);
      await _sendChunked(payload);
    } catch (e) {
      _addLog('Thumbnail upload failed: $e');
    }
  }

  Future<int> _uploadImageWithThumbnail(_SentImage image) async {
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
      await _sendChunked(_buildHeader(magic, secondField));
      return await _pendingDownloadCompleter!.future.timeout(timeout);
    } finally {
      _awaitingDownloadHeader = false;
      _pendingDownloadCompleter = null;
    }
  }

  Future<Uint8List> _downloadImage(int index) => _downloadRaw(_downloadCmdMagic, index, timeout: const Duration(seconds: 30));
  Future<Uint8List> _downloadThumbnail(int index) => _downloadRaw(_downloadThumbCmdMagic, index);

  Future<void> _sendFormatCommand() async {
    _pendingIndexCompleter = Completer<int>();
    try {
      await _sendChunked(_buildHeader(_formatCmdMagic, 0));
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
      await _sendChunked(_buildHeader(_showIndexCmdMagic, deviceIndex));
    } catch (e) {
      _addLog('Show failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleRotationSelected(_SentImage image) {
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

      await _sendChunked(_buildHeader(_playlistClearMagic, 0));
      for (final image in usable) {
        await _sendChunked(_buildHeader(_playlistAddMagic, image.deviceIndex!));
      }
      await _sendChunked(_buildHeader(_playlistStartMagic, _rotationSeconds.round()));
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
      await _sendChunked(_buildHeader(_playlistStopMagic, 0));
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

    final originalOrder = List<_SentImage>.from(_sentImages);
    final firstDeletedPos = originalOrder.indexOf(toDelete.first);
    final toKeep = _sentImages.where((i) => !i.selectedForRotation).toList();

    _SentImage? neighbor;
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
        await _sendChunked(_buildHeader(_showIndexCmdMagic, neighbor.deviceIndex!));
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
      await _sendChunked(_buildHeader(_brightnessCmdMagic, level));
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

// ---------------------------------------------------------------------------
// Flash Banner: composes a scrolling or blinking text banner as a sequence
// of panel-resolution frames, which get added to the Images list (already
// selected for rotation) for playback through the existing rotation/BLE
// pipeline — no new device protocol needed.
// ---------------------------------------------------------------------------
enum _BannerEffect { blink, scroll }

class FlashBannerPage extends StatefulWidget {
  const FlashBannerPage({super.key});

  @override
  State<FlashBannerPage> createState() => _FlashBannerPageState();
}

class _FlashBannerPageState extends State<FlashBannerPage> {
  // Native landscape canvas — matches the panel's physical 960×192 layout.
  // The firmware memcpys decoded pixels straight into the 960×192 framebuffer,
  // so the JPEG must be exactly this size.
  static const double _canvasWidth = 960;
  static const double _canvasHeight = 192;

  final TextEditingController _textController = TextEditingController(text: 'HELLO!');
  Color _textColor = Colors.white;
  Color _bgColor = Colors.black;
  _BannerEffect _effect = _BannerEffect.scroll;
  double _fontSize = 90;
  bool _generating = false;

  static const List<Color> _colorPalette = [
    Colors.white, Colors.black, Colors.red, Colors.orange, Colors.amber,
    Colors.yellow, Colors.green, Colors.teal, Colors.cyan, Colors.blue,
    Colors.indigo, Colors.purple, Colors.pink, Colors.brown, Colors.grey,
  ];

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Widget _colorSwatches(Color active, ValueChanged<Color> onPicked) {
    return SizedBox(
      height: 34,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _colorPalette.length,
        itemBuilder: (ctx, idx) {
          final c = _colorPalette[idx];
          final isSelected = c == active;
          return GestureDetector(
            onTap: () => onPicked(c),
            child: Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? Colors.cyanAccent : Colors.white24,
                  width: isSelected ? 3 : 1,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  TextPainter _makeTextPainter() {
    final tp = TextPainter(
      text: TextSpan(
        text: _textController.text,
        style: TextStyle(color: _textColor, fontSize: _fontSize, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    return tp;
  }

  Future<Uint8List> _renderFrame({required double textX, required bool showText}) async {
    final recorder = ui.PictureRecorder();
    // Draw directly on the native 960×192 landscape canvas — no rotation tricks.
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, _canvasWidth, _canvasHeight));

    canvas.drawRect(const Rect.fromLTWH(0, 0, _canvasWidth, _canvasHeight), Paint()..color = _bgColor);

    if (showText && _textController.text.isNotEmpty) {
      final tp = _makeTextPainter();
      final ty = (_canvasHeight - tp.height) / 2;
      tp.paint(canvas, Offset(textX, ty));
    }

    final picture = recorder.endRecording();
    // toImage() produces exactly 960×192 — landscape, matching the firmware framebuffer.
    final uiImg = await picture.toImage(_canvasWidth.round(), _canvasHeight.round());
    final byteData = await uiImg.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rawPixels = byteData!.buffer.asUint8List();
    final landscape = image_lib.Image.fromBytes(
      width: _canvasWidth.round(),   // 960
      height: _canvasHeight.round(), // 192
      bytes: rawPixels.buffer,
      format: image_lib.Format.uint8,
      numChannels: 4,
    );
    return Uint8List.fromList(image_lib.encodeJpg(landscape, quality: 90));
  }

  Future<List<Uint8List>> _generateFrames() async {
    final frames = <Uint8List>[];
    if (_effect == _BannerEffect.blink) {
      final tp = _makeTextPainter();
      final centeredX = (_canvasWidth - tp.width) / 2;
      frames.add(await _renderFrame(textX: centeredX, showText: true));
      frames.add(await _renderFrame(textX: centeredX, showText: false));
    } else {
      final tp = _makeTextPainter();
      final textWidth = tp.width;
      const int steps = 14; // keep the BLE upload count manageable
      final startX = _canvasWidth;
      final endX = -textWidth;
      for (int i = 0; i <= steps; i++) {
        final t = i / steps;
        final x = startX + (endX - startX) * t;
        frames.add(await _renderFrame(textX: x, showText: true));
      }
    }
    return frames;
  }

  Future<void> _confirm() async {
    if (_textController.text.trim().isEmpty) return;
    setState(() => _generating = true);
    try {
      final frames = await _generateFrames();
      if (!mounted) return;
      Navigator.of(context).pop(frames);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flash Banner'),
        actions: [
          if (_generating)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(icon: const Icon(Icons.check), onPressed: _confirm),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _textController,
              decoration: const InputDecoration(
                labelText: 'Banner text',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            const Text('Effect', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<_BannerEffect>(
              segments: const [
                ButtonSegment(value: _BannerEffect.scroll, label: Text('Scroll'), icon: Icon(Icons.swap_horiz)),
                ButtonSegment(value: _BannerEffect.blink, label: Text('Blink')),
              ],
              selected: {_effect},
              onSelectionChanged: (s) => setState(() => _effect = s.first),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.format_size),
                Expanded(
                  child: Slider(
                    value: _fontSize,
                    min: 40,
                    max: 160,
                    onChanged: (v) => setState(() => _fontSize = v),
                  ),
                ),
                SizedBox(width: 36, child: Text(_fontSize.round().toString())),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Text color', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            _colorSwatches(_textColor, (c) => setState(() => _textColor = c)),
            const SizedBox(height: 12),
            const Text('Background color', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            _colorSwatches(_bgColor, (c) => setState(() => _bgColor = c)),
            const SizedBox(height: 20),
            AspectRatio(
              aspectRatio: _canvasWidth / _canvasHeight,
              child: Container(
                decoration: BoxDecoration(
                  color: _bgColor,
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    _textController.text,
                    style: TextStyle(
                      color: _textColor,
                      fontSize: _fontSize / 4,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _effect == _BannerEffect.scroll
                  ? 'Preview (not to scale) — the real banner scrolls across the panel.'
                  : 'Preview (not to scale) — the real banner blinks on/off on the panel.',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class EditorItem {
  EditorItem({
    required this.id,
    required this.content,
    required this.isSticker,
    this.stickerIcon,
    this.offset = const Offset(50, 50),
    this.scale = 1.0,
    this.rotation = 0.0,
    Color? color,
    this.fontSize = 34,
    this.fontFamily,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.letterSpacing = 0,
  }) : color = color ?? (isSticker ? Colors.amber : Colors.white);

  final String id;
  final String content;
  final bool isSticker;
  final IconData? stickerIcon;
  Offset offset;
  double scale;
  double rotation; // radians
  // Text color (for emoji/text items) or background color (for stickers).
  Color color;
  // Text-only styling. Ignored for stickers.
  double fontSize;
  String? fontFamily; // null = default
  bool bold;
  bool italic;
  bool underline;
  bool strikethrough;
  double letterSpacing;
}

class ImageEditorPage extends StatefulWidget {
  final Uint8List imageBytes;
  const ImageEditorPage({super.key, required this.imageBytes});

  @override
  State<ImageEditorPage> createState() => _ImageEditorPageState();
}

class _ImageEditorPageState extends State<ImageEditorPage> with SingleTickerProviderStateMixin {
  // Fixed panel resolution. The editor canvas is ALWAYS this shape,
  // regardless of what size/ratio the incoming image is. Using
  // BoxFit.contain for the background image (see below) means the whole
  // photo is always visible inside this canvas — never invisibly cropped
  // away — and you can pinch-zoom in from there to focus on any part of it.
  // Native landscape canvas — 960×192 matches the panel's physical layout.
  static const double _canvasWidth = 960;
  static const double _canvasHeight = 192;
  // Actual rendered size of the canvas Stack (updated on every layout pass).
  // AspectRatio only guarantees the 192:960 ratio, not this exact absolute
  // size, so new items are centered using this rather than the constants.
  Size? _canvasSize;

  final GlobalKey _boundaryKey = GlobalKey();
  // Key on the Stack that actually holds the draggable items. Used to convert
  // global (screen) pointer coordinates into this widget's local coordinate
  // space via RenderBox.globalToLocal.
  final GlobalKey _stackKey = GlobalKey();

  final List<EditorItem> _placedItems = [];
  int? _selectedIdx;
  bool _isSaving = false;

  // State kept during an active one/two-finger gesture on a placed item.
  Offset? _dragAnchor;
  double? _itemStartScale;
  double? _itemStartRotation;

  // ----- Background photo repositioning (pan + pinch zoom + rotate) -----
  // This is the "zoom +/- to show only the part of the image you want"
  // control: drag to pan, pinch to zoom, twist with two fingers to rotate,
  // right on the canvas.
  bool _repositioningBackground = false;
  Offset _bgOffset = Offset.zero;
  double _bgScale = 1.0;
  double _bgRotation = 0.0; // radians
  double? _bgGestureStartScale;
  double? _bgGestureStartRotation;
  // Fills any letterboxed space left around the photo (e.g. when its
  // aspect ratio doesn't exactly match the 192x960 panel).
  Color _bgColor = Colors.black;

  void _toggleReposition() {
    setState(() {
      _repositioningBackground = !_repositioningBackground;
      if (_repositioningBackground) _selectedIdx = null;
    });
  }

  void _resetBackgroundTransform() {
    setState(() {
      _bgOffset = Offset.zero;
      _bgScale = 1.0;
      _bgRotation = 0.0;
    });
  }

  void _quickRotateBackground(double radians) {
    setState(() {
      _bgRotation += radians;
    });
  }

  void _stepZoomBackground(double delta) {
    setState(() {
      _bgScale = (_bgScale + delta).clamp(0.5, 6.0);
    });
  }

  void _setBackgroundColor(Color color) {
    setState(() => _bgColor = color);
  }

  // ----- Android-keyboard style emoji/sticker picker -----
  late final TabController _tabController;

  static const Map<String, List<String>> _emojiCategories = {
    'Smileys': [
      '😀', '😁', '😂', '🤣', '😊', '😍', '😘', '😜', '🤪', '😎',
      '🥳', '😇', '🙃', '🤩', '😢', '😭', '😡', '🤔', '😴', '🤗',
      '😏', '😅', '🥰', '😋', '🤤', '😱', '🥺', '😤', '🤯', '🥶',
    ],
    'Hands & Hearts': [
      '👍', '👎', '👏', '🙌', '🤝', '💪', '✌️', '🤞', '👌', '🤙',
      '👋', '🤟', '🫶', '✋', '🖐️', '🙏',
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💔', '💯',
      '💕', '💖', '💗', '💞',
    ],
    'Nature': [
      '🌸', '🌺', '🌻', '🌈', '☀️', '🌙', '⚡', '❄️', '🍀', '🌊',
      '🐶', '🐱', '🐼', '🦄', '🐝', '🦋', '🐾', '🐦', '🐟', '🦁',
      '🌵', '🌴', '🍁', '🌹', '⭐', '🌟', '💫', '☁️',
    ],
    'Food': [
      '🍕', '🍔', '🍰', '🎂', '☕', '🍦', '🍩', '🍓', '🍉', '🥑',
      '🍎', '🍇', '🍒', '🍫', '🍿', '🌮', '🍟', '🍪',
    ],
    'Objects': [
      '📷', '🎮', '🎵', '🎨', '📚', '✈️', '🚀', '⚽', '🎯', '💡',
      '🎉', '🎊', '🎈', '🎁', '🏆', '🔥', '✨', '💰', '⏰', '📱',
    ],
  };

  static const List<IconData> _stickerIcons = [
    Icons.star, Icons.favorite, Icons.brightness_5, Icons.celebration,
    Icons.pets, Icons.wb_sunny, Icons.auto_awesome, Icons.music_note,
    Icons.local_pizza, Icons.cake, Icons.videogame_asset, Icons.rocket_launch,
    Icons.emoji_emotions, Icons.mood, Icons.thumb_up, Icons.diamond,
    Icons.local_fire_department, Icons.bolt, Icons.anchor, Icons.spa,
  ];

  static const List<Color> _colorPalette = [
    Colors.white, Colors.black, Colors.grey,
    Colors.red, Color(0xFFB71C1C), Color(0xFFFF8A80),
    Colors.orange, Color(0xFFE65100), Color(0xFFFFCC80),
    Colors.amber, Color(0xFFFFA000),
    Colors.yellow, Color(0xFFF9A825),
    Colors.lime, Color(0xFF9E9D24),
    Colors.green, Color(0xFF1B5E20), Color(0xFFA5D6A7),
    Colors.teal, Color(0xFF004D40),
    Colors.cyan, Color(0xFF006064),
    Colors.lightBlue, Colors.blue, Color(0xFF0D47A1), Color(0xFF90CAF9),
    Colors.indigo, Color(0xFF1A237E),
    Colors.purple, Color(0xFF4A148C), Color(0xFFCE93D8),
    Colors.deepPurple,
    Colors.pink, Color(0xFF880E4F), Color(0xFFF8BBD0),
    Colors.brown, Color(0xFF3E2723),
    Colors.blueGrey, Color(0xFFECEFF1),
  ];

  Future<void> _showCustomColorPicker(Color initial, ValueChanged<Color> onPicked) async {
    final int argb = initial.toARGB32();
    int r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final preview = Color.fromARGB(255, r, g, b);
          Widget slider(String label, int value, ValueChanged<int> onChanged) {
            return Row(
              children: [
                SizedBox(width: 16, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12))),
                Expanded(
                  child: Slider(
                    value: value.toDouble(),
                    min: 0,
                    max: 255,
                    onChanged: (v) => setDialogState(() => onChanged(v.round())),
                  ),
                ),
                SizedBox(width: 32, child: Text('$value', style: const TextStyle(color: Colors.white70, fontSize: 12))),
              ],
            );
          }
          return AlertDialog(
            backgroundColor: Colors.grey.shade900,
            title: const Text('Custom Color', style: TextStyle(color: Colors.white)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  height: 50,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: preview,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                ),
                slider('R', r, (v) => r = v),
                slider('G', g, (v) => g = v),
                slider('B', b, (v) => b = v),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  onPicked(Color.fromARGB(255, r, g, b));
                  Navigator.pop(context);
                },
                child: const Text('Use this color'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _emojiCategories.length + 1, vsync: this);
    _autoRotateIfPortrait();
  }

  // A portrait-oriented photo (taller than wide) shown with BoxFit.contain
  // inside this landscape-shaped canvas would be constrained by the
  // canvas's short dimension, appearing as a small strip in the middle.
  // Rotating it 90° up front makes it landscape-shaped, filling the frame
  // properly. The existing rotate controls still let you undo/adjust this.
  Future<void> _autoRotateIfPortrait() async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(widget.imageBytes, completer.complete);
    final img = await completer.future;
    if (mounted && img.height > img.width) {
      setState(() => _bgRotation = math.pi / 2);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _addEmojiItem(String standardText) {
    final uniqueId = DateTime.now().microsecondsSinceEpoch.toString();
    final size = _canvasSize ?? const Size(_canvasWidth, _canvasHeight);
    setState(() {
      _placedItems.add(EditorItem(
        id: uniqueId,
        content: standardText,
        isSticker: false,
        offset: Offset(size.width / 2 - 30, size.height / 2 - 20),
      ));
      _selectedIdx = _placedItems.length - 1;
    });
  }

  void _addStickerItem(IconData icon) {
    final uniqueId = DateTime.now().microsecondsSinceEpoch.toString();
    final size = _canvasSize ?? const Size(_canvasWidth, _canvasHeight);
    setState(() {
      _placedItems.add(EditorItem(
        id: uniqueId,
        content: '',
        isSticker: true,
        stickerIcon: icon,
        offset: Offset(size.width / 2 - 25, size.height / 2 - 25),
      ));
      _selectedIdx = _placedItems.length - 1;
    });
  }

  void _removeItemAt(int idx) {
    setState(() {
      _placedItems.removeAt(idx);
      if (_selectedIdx == idx) {
        _selectedIdx = null;
      } else if (_selectedIdx != null && _selectedIdx! > idx) {
        _selectedIdx = _selectedIdx! - 1;
      }
    });
  }

  void _removeActiveItem() {
    if (_selectedIdx != null && _selectedIdx! < _placedItems.length) {
      _removeItemAt(_selectedIdx!);
    }
  }

  void _setActiveItemColor(Color color) {
    if (_selectedIdx != null && _selectedIdx! < _placedItems.length) {
      setState(() {
        _placedItems[_selectedIdx!].color = color;
      });
    }
  }

  void _openCustomTextInput() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Text'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Type your text...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                _addEmojiItem(controller.text.trim());
              }
              Navigator.pop(context);
            },
            child: const Text('Add'),
          )
        ],
      ),
    );
  }

  Future<void> _exportCanvas() async {
    try {
      setState(() {
        _selectedIdx = null;
        _repositioningBackground = false;
        _isSaving = true;
      });

      await Future.delayed(const Duration(milliseconds: 300));

      final RenderRepaintBoundary boundary =
          _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;

      // The canvas is now a true 960×192 landscape widget (no RotatedBox).
      // boundary.size.width is the on-screen logical width of the landscape strip.
      // We need pixelRatio so that: logical_width × pixelRatio == _canvasWidth (960).
      final double renderedLogicalWidth = boundary.size.width;
      final double neededPixelRatio = _canvasWidth / renderedLogicalWidth;

      // Capture at exactly 960×192 physical pixels.
      final ui.Image captured = await boundary.toImage(pixelRatio: neededPixelRatio);

      final ByteData? rawData =
          await captured.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rawData != null) {
        final imgLib = image_lib.Image.fromBytes(
          width: captured.width,   // 960
          height: captured.height, // 192
          bytes: rawData.buffer,
          format: image_lib.Format.uint8,
          numChannels: 4,
        );
        // Encode as real JPEG — the firmware memcpys directly into the
        // 960×192 framebuffer, so pixels must be in landscape order.
        final Uint8List jpegBytes =
            Uint8List.fromList(image_lib.encodeJpg(imgLib, quality: 90));
        if (mounted) Navigator.of(context).pop(jpegBytes);
      }
    } catch (e) {
      debugPrint('Export failed: $e');
      if (mounted) {
        setState(() { _isSaving = false; });
        // Show a visible error — previously this only printed to debug console
        // (invisible in release builds), leaving the editor stuck with a
        // frozen save spinner and no way to recover.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Widget _buildColorSwatches(Color activeColor) {
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _colorPalette.length,
        itemBuilder: (ctx, idx) {
          final c = _colorPalette[idx];
          final isSelected = c == activeColor;
          return GestureDetector(
            onTap: () => _setActiveItemColor(c),
            child: Container(
              width: 30,
              height: 30,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? Colors.cyanAccent : Colors.white24,
                  width: isSelected ? 3 : 1,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _styleToggleButton({required IconData icon, required bool active, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: active ? Colors.amberAccent.withOpacity(0.25) : Colors.transparent,
          border: Border.all(color: active ? Colors.amberAccent : Colors.white24),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 20, color: active ? Colors.amberAccent : Colors.white70),
      ),
    );
  }

  Widget _fontChip(String label, String? family, String? currentFamily) {
    final selected = family == currentFamily;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(fontFamily: family, fontSize: 12)),
        selected: selected,
        onSelected: (_) => setState(() {
          if (_selectedIdx != null) _placedItems[_selectedIdx!].fontFamily = family;
        }),
        selectedColor: Colors.amberAccent,
        backgroundColor: Colors.white10,
        labelStyle: TextStyle(color: selected ? Colors.black : Colors.white70),
      ),
    );
  }

  Widget _buildEmojiGrid(List<String> emojis) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: emojis.length,
      itemBuilder: (ctx, idx) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _addEmojiItem(emojis[idx]),
        child: Center(child: Text(emojis[idx], style: const TextStyle(fontSize: 24))),
      ),
    );
  }

  Widget _buildStickerGrid() {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: _stickerIcons.length,
      itemBuilder: (ctx, idx) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _addStickerItem(_stickerIcons[idx]),
        child: Center(child: Icon(_stickerIcons[idx], color: Colors.amberAccent, size: 22)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    EditorItem? activeItem = (_selectedIdx != null && _selectedIdx! < _placedItems.length)
        ? _placedItems[_selectedIdx!]
        : null;

    final categoryNames = _emojiCategories.keys.toList();
    final bgGesturesEnabled = _repositioningBackground && !_isSaving;

    return Scaffold(
      backgroundColor: Colors.black87,
      appBar: AppBar(
        title: const Text('Move & Style Elements'),
        actions: [
          if (!_isSaving) ...[
            IconButton(
              icon: Icon(_repositioningBackground ? Icons.check_circle : Icons.edit),
              tooltip: _repositioningBackground ? 'Done editing photo' : 'Edit photo (move/zoom/rotate)',
              onPressed: _toggleReposition,
            ),
            IconButton(
              icon: const Icon(Icons.text_fields),
              tooltip: 'Add text',
              onPressed: _openCustomTextInput,
            ),
            IconButton(icon: const Icon(Icons.check), onPressed: _exportCanvas),
          ]
        ],
      ),
      body: Column(
        children: [
          if (_repositioningBackground)
            Container(
              width: double.infinity,
              color: Colors.amber.shade700,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.info_outline, size: 16, color: Colors.black),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'Drag to move • Pinch to zoom • Twist to rotate',
                          style: TextStyle(color: Colors.black, fontSize: 12),
                        ),
                      ),
                      TextButton(
                        onPressed: _resetBackgroundTransform,
                        child: const Text('Reset', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.rotate_left, color: Colors.black),
                        tooltip: 'Rotate 90° left',
                        onPressed: () => _quickRotateBackground(-math.pi / 2),
                      ),
                      Expanded(
                        child: Slider(
                          value: ((_bgRotation * 180 / math.pi) % 360 + 360) % 360,
                          min: 0,
                          max: 360,
                          activeColor: Colors.black,
                          onChanged: (v) => setState(() => _bgRotation = v * math.pi / 180),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.rotate_right, color: Colors.black),
                        tooltip: 'Rotate 90° right',
                        onPressed: () => _quickRotateBackground(math.pi / 2),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '${(((_bgRotation * 180 / math.pi) % 360 + 360) % 360).round()}°',
                          style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.zoom_out, color: Colors.black),
                        tooltip: 'Zoom out',
                        onPressed: () => _stepZoomBackground(-0.1),
                      ),
                      Expanded(
                        child: Text(
                          'Zoom: ${(_bgScale * 100).round()}%',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.zoom_in, color: Colors.black),
                        tooltip: 'Zoom in',
                        onPressed: () => _stepZoomBackground(0.1),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('Background:', style: TextStyle(color: Colors.black, fontSize: 12)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SizedBox(
                          height: 30,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: _colorPalette.length,
                            itemBuilder: (ctx, idx) {
                              final c = _colorPalette[idx];
                              final isSelected = c == _bgColor;
                              return GestureDetector(
                                onTap: () => _setBackgroundColor(c),
                                child: Container(
                                  width: 26,
                                  height: 26,
                                  margin: const EdgeInsets.symmetric(horizontal: 3),
                                  decoration: BoxDecoration(
                                    color: c,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: isSelected ? Colors.cyanAccent : Colors.black26,
                                      width: isSelected ? 3 : 1,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () => _showCustomColorPicker(_bgColor, _setBackgroundColor),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black45, width: 1.5),
                            gradient: const SweepGradient(
                              colors: [Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Colors.purple, Colors.red],
                            ),
                          ),
                          child: const Icon(Icons.add, size: 16, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            flex: 3,
            child: Center(
              // The panel's raw pixel data is 960x192 (landscape).
              // The Container below just draws a visible border around the
              // canvas boundary as a visual guide.
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.amberAccent, width: 2),
                ),
                // Canvas is native 960×192 landscape — no RotatedBox needed.
                child: AspectRatio(
                  aspectRatio: _canvasWidth / _canvasHeight,
                  child: RepaintBoundary(
                    key: _boundaryKey,
                    child: LayoutBuilder(
                          builder: (context, constraints) {
                            // AspectRatio only fixes the RATIO, not the
                            // absolute size — the actual rendered box could
                            // be any size that keeps that ratio. Track it so
                            // new items can be centered correctly (using the
                            // fixed 192/960 constants directly here caused
                            // items to land outside the visible canvas
                            // whenever the real rendered size differed).
                            _canvasSize = constraints.biggest;
                            return Stack(
                              key: _stackKey,
                              clipBehavior: Clip.hardEdge,
                              children: [
                                // Background photo: draggable/zoomable/rotatable
                                // while in reposition mode. ClipRect keeps it
                                // confined to the panel bounds no matter how far
                                // it's panned. The colored Container behind it
                                // fills any letterboxed space left where the
                                // photo's aspect ratio doesn't exactly match the
                                // panel (BoxFit.contain leaves margins there).
                                Positioned.fill(
                                  child: ClipRect(
                                    child: Container(
                                      color: _bgColor,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onScaleStart: !bgGesturesEnabled ? null : (details) {
                                          _bgGestureStartScale = _bgScale;
                                          _bgGestureStartRotation = _bgRotation;
                                        },
                                        onScaleUpdate: !bgGesturesEnabled ? null : (details) {
                                          setState(() {
                                            _bgScale = (_bgGestureStartScale! * details.scale).clamp(0.5, 6.0);
                                            _bgOffset += details.focalPointDelta;
                                            if (details.pointerCount > 1) {
                                              _bgRotation = _bgGestureStartRotation! + details.rotation;
                                            }
                                          });
                                        },
                                        onTap: bgGesturesEnabled ? null : () {
                                          if (!_isSaving) setState(() => _selectedIdx = null);
                                        },
                                        child: Transform.translate(
                                          offset: _bgOffset,
                                          child: Transform.rotate(
                                            angle: _bgRotation,
                                            child: Transform.scale(
                                              scale: _bgScale,
                                              child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                ...List.generate(_placedItems.length, (index) {
                                  final item = _placedItems[index];
                                  final isFocused = _selectedIdx == index;
                                  final itemGesturesEnabled = !_isSaving && !_repositioningBackground;

                                  return Positioned(
                                    key: ValueKey('item_${item.id}'),
                                    left: item.offset.dx,
                                    top: item.offset.dy,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: !itemGesturesEnabled ? null : () {
                                        setState(() { _selectedIdx = index; });
                                      },
                                      // Single gesture recognizer handles move
                                      // (1 finger, in ANY direction: up, down,
                                      // left, right), and pinch-resize + twist-
                                      // to-rotate (2 fingers) together.
                                      onScaleStart: !itemGesturesEnabled ? null : (details) {
                                        final box = _stackKey.currentContext!.findRenderObject() as RenderBox;
                                        final localPos = box.globalToLocal(details.focalPoint);
                                        setState(() {
                                          _selectedIdx = index;
                                          _dragAnchor = localPos - item.offset;
                                          _itemStartScale = item.scale;
                                          _itemStartRotation = item.rotation;
                                        });
                                      },
                                      onScaleUpdate: !itemGesturesEnabled ? null : (details) {
                                        final box = _stackKey.currentContext!.findRenderObject() as RenderBox;
                                        final localPos = box.globalToLocal(details.focalPoint);
                                        final anchor = _dragAnchor ?? Offset.zero;
                                        setState(() {
                                          final newOffset = localPos - anchor;
                                          item.offset = Offset(
                                            newOffset.dx.clamp(-40.0, constraints.maxWidth - 20),
                                            newOffset.dy.clamp(-40.0, constraints.maxHeight - 20),
                                          );
                                          if (details.pointerCount > 1) {
                                            item.scale = (_itemStartScale! * details.scale).clamp(0.3, 4.0);
                                            item.rotation = _itemStartRotation! + details.rotation;
                                          }
                                        });
                                      },
                                      onScaleEnd: (_) => _dragAnchor = null,
                                      child: Transform.rotate(
                                        angle: item.rotation,
                                        child: Transform.scale(
                                          scale: item.scale,
                                          child: Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.all(12),
                                                constraints: BoxConstraints(
                                                  maxWidth: item.isSticker ? double.infinity : _canvasWidth - 40,
                                                ),
                                                decoration: BoxDecoration(
                                                  border: Border.all(
                                                      color: isFocused ? Colors.cyan : Colors.transparent,
                                                      width: 2
                                                  ),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: RotatedBox(
                                                  quarterTurns: 1,
                                                  child: item.isSticker
                                                      ? Container(
                                                    padding: const EdgeInsets.all(8),
                                                    decoration: BoxDecoration(
                                                      color: item.color,
                                                      shape: BoxShape.circle,
                                                    ),
                                                    child: Icon(item.stickerIcon, size: 36, color: Colors.white),
                                                  )
                                                      : Text(
                                                    item.content,
                                                    textAlign: TextAlign.center,
                                                    softWrap: true,
                                                    style: TextStyle(
                                                      fontSize: item.fontSize,
                                                      fontFamily: item.fontFamily,
                                                      color: item.color,
                                                      fontWeight: item.bold ? FontWeight.bold : FontWeight.normal,
                                                      fontStyle: item.italic ? FontStyle.italic : FontStyle.normal,
                                                      letterSpacing: item.letterSpacing,
                                                      decoration: TextDecoration.combine([
                                                        if (item.underline) TextDecoration.underline,
                                                        if (item.strikethrough) TextDecoration.lineThrough,
                                                      ]),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          // Small delete button pinned to the item's
                                          // top-right corner, visible only while
                                          // this item is selected.
                                          if (isFocused && itemGesturesEnabled)
                                            Positioned(
                                              top: -8,
                                              right: -8,
                                              child: GestureDetector(
                                                onTap: () => _removeItemAt(index),
                                                child: Container(
                                                  width: 20,
                                                  height: 20,
                                                  decoration: const BoxDecoration(
                                                    color: Colors.red,
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: const Icon(Icons.close, size: 12, color: Colors.white),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            );
                          }
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            flex: 2,
            child: Opacity(
              opacity: _isSaving ? 0.0 : 1.0,
              child: IgnorePointer(
                ignoring: _isSaving,
                child: Container(
                  color: Colors.grey.shade900,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (activeItem != null) ...[
                          Row(
                            children: [
                              const Icon(Icons.photo_size_select_large_outlined, size: 18, color: Colors.white),
                              Expanded(
                                child: Slider(
                                  value: activeItem.scale,
                                  min: 0.3,
                                  max: 4.0,
                                  onChanged: (v) => setState(() => activeItem!.scale = v),
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: Text(
                                  '${(activeItem.scale * 100).round()}%',
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.rotate_right, size: 18, color: Colors.white),
                              Expanded(
                                child: Slider(
                                  value: ((activeItem.rotation * 180 / math.pi) % 360 + 360) % 360,
                                  min: 0,
                                  max: 360,
                                  onChanged: (v) => setState(() => activeItem!.rotation = v * math.pi / 180),
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: Text(
                                  '${(((activeItem.rotation * 180 / math.pi) % 360 + 360) % 360).round()}°',
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                          if (!activeItem.isSticker) ...[
                            Row(
                              children: [
                                const Icon(Icons.format_size, size: 18, color: Colors.white),
                                Expanded(
                                  child: Slider(
                                    value: activeItem.fontSize,
                                    min: 12,
                                    max: 90,
                                    onChanged: (v) => setState(() => activeItem!.fontSize = v),
                                  ),
                                ),
                                SizedBox(
                                  width: 30,
                                  child: Text(
                                    activeItem.fontSize.round().toString(),
                                    style: const TextStyle(color: Colors.white, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                const Icon(Icons.space_bar, size: 18, color: Colors.white),
                                Expanded(
                                  child: Slider(
                                    value: activeItem.letterSpacing,
                                    min: -2,
                                    max: 20,
                                    onChanged: (v) => setState(() => activeItem!.letterSpacing = v),
                                  ),
                                ),
                                SizedBox(
                                  width: 30,
                                  child: Text(
                                    activeItem.letterSpacing.round().toString(),
                                    style: const TextStyle(color: Colors.white, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _styleToggleButton(
                                  icon: Icons.format_bold,
                                  active: activeItem.bold,
                                  onTap: () => setState(() => activeItem!.bold = !activeItem.bold),
                                ),
                                _styleToggleButton(
                                  icon: Icons.format_italic,
                                  active: activeItem.italic,
                                  onTap: () => setState(() => activeItem!.italic = !activeItem.italic),
                                ),
                                _styleToggleButton(
                                  icon: Icons.format_underline,
                                  active: activeItem.underline,
                                  onTap: () => setState(() => activeItem!.underline = !activeItem.underline),
                                ),
                                _styleToggleButton(
                                  icon: Icons.format_strikethrough,
                                  active: activeItem.strikethrough,
                                  onTap: () => setState(() => activeItem!.strikethrough = !activeItem.strikethrough),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              height: 34,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  _fontChip('Default', null, activeItem.fontFamily),
                                  _fontChip('Serif', 'serif', activeItem.fontFamily),
                                  _fontChip('Monospace', 'monospace', activeItem.fontFamily),
                                  _fontChip('Condensed', 'sans-serif-condensed', activeItem.fontFamily),
                                  _fontChip('Cursive', 'cursive', activeItem.fontFamily),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text('COLOR', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1)),
                          ),
                          const SizedBox(height: 4),
                          _buildColorSwatches(activeItem.color),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red.shade800,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _removeActiveItem,
                              icon: const Icon(Icons.delete),
                              label: const Text('Delete Selected Item'),
                            ),
                          ),
                          const Divider(color: Colors.white24),
                        ],
                        // ----- Android-keyboard style picker -----
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: [
                              TabBar(
                                controller: _tabController,
                                isScrollable: true,
                                labelColor: Colors.amberAccent,
                                unselectedLabelColor: Colors.white54,
                                indicatorColor: Colors.amberAccent,
                                tabs: [
                                  ...categoryNames.map((name) => Tab(text: name)),
                                  const Tab(icon: Icon(Icons.emoji_emotions_outlined), text: 'Stickers'),
                                ],
                              ),
                              SizedBox(
                                height: 190,
                                child: TabBarView(
                                  controller: _tabController,
                                  children: [
                                    ...categoryNames.map((name) => _buildEmojiGrid(_emojiCategories[name]!)),
                                    _buildStickerGrid(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}