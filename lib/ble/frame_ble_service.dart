import 'dart:async';
import 'dart:math' show min;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/sent_image.dart';
import '../utils/image_utils.dart';
import 'frame_connection.dart';
import 'frame_protocol.dart';

class FrameBleService {
  static final FrameBleService instance = FrameBleService._internal();
  FrameBleService._internal();

  final ValueNotifier<FrameConnState> connStateNotifier = ValueNotifier<FrameConnState>(FrameConnState.disconnected);
  FrameConnState get connState => connStateNotifier.value;
  set connState(FrameConnState state) => connStateNotifier.value = state;

  BluetoothDevice? device;
  BluetoothCharacteristic? rxChar;
  BluetoothCharacteristic? txChar;
  StreamSubscription<List<ScanResult>>? scanSub;
  StreamSubscription<BluetoothConnectionState>? connSub;
  StreamSubscription<List<int>>? notifySub;
  int mtu = 23;

  int _bleSeqToken = 0;
  final Map<int, Completer<int>> _pendingCompleters = {};

  bool awaitingDownloadHeader = false;
  int downloadExpectedSize = 0;
  final BytesBuilder downloadBuilder = BytesBuilder();
  Completer<Uint8List>? pendingDownloadCompleter;

  final List<Future<void> Function()> bleQueue = [];
  bool bleProcessing = false;

  void Function(String)? onLog;

  void log(String message) {
    onLog?.call(message);
  }

  void _clearQueueAndRejectPending(String reason) {
    bleQueue.clear();
    bleProcessing = false;
    for (final c in _pendingCompleters.values) {
      if (!c.isCompleted) c.completeError(Exception(reason));
    }
    _pendingCompleters.clear();
    if (awaitingDownloadHeader || pendingDownloadCompleter != null) {
      pendingDownloadCompleter?.completeError(Exception(reason));
      pendingDownloadCompleter = null;
      awaitingDownloadHeader = false;
    }
  }

  Future<T> enqueueBleTask<T>(Future<T> Function() task, {bool highPriority = false}) {
    final completer = Completer<T>();
    Future<void> taskWrapper() async {
      try {
        final result = await task();
        if (!completer.isCompleted) completer.complete(result);
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      }
    }
    if (highPriority) {
      bleQueue.insert(0, taskWrapper);
    } else {
      bleQueue.add(taskWrapper);
    }
    processBleQueue();
    return completer.future;
  }

  Future<void> processBleQueue() async {
    if (bleProcessing) return;
    bleProcessing = true;
    while (bleQueue.isNotEmpty) {
      final task = bleQueue.removeAt(0);
      try {
        await task();
      } catch (e) {
        log('BLE Task Error: $e');
      }
    }
    bleProcessing = false;
  }

  Future<void> connectToFrame({
    required Future<bool> Function() ensurePermissions,
  }) async {
    if (connState == FrameConnState.scanning || connState == FrameConnState.connecting) {
      return;
    }
    if (!await ensurePermissions()) {
      log('Bluetooth/location permissions denied');
      return;
    }

    connState = FrameConnState.scanning;
    log('Scanning for AMOLED-Frame...');

    try {
      await scanSub?.cancel();
      scanSub = FlutterBluePlus.onScanResults.listen((results) async {
        for (final r in results) {
          if (r.device.platformName == 'AMOLED-Frame') {
            await FlutterBluePlus.stopScan();
            await scanSub?.cancel();
            await connectDevice(r.device);
            return;
          }
        }
      });
      await FlutterBluePlus.startScan(
        withServices: [nusServiceUuid],
        timeout: const Duration(seconds: 10),
      );

      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;

      if (connState == FrameConnState.scanning) {
        log('Scan timed out. Device not found.');
        connState = FrameConnState.disconnected;
      }
    } catch (e) {
      log('Scan failed: $e');
      connState = FrameConnState.disconnected;
    }
  }

  Future<void> connectDevice(BluetoothDevice targetDevice) async {
    connState = FrameConnState.connecting;
    log('Found device, connecting...');
    device = targetDevice;

    connSub?.cancel();
    connSub = targetDevice.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        log('Disconnected');
        notifySub?.cancel();
        _clearQueueAndRejectPending('BLE disconnected');
        rxChar = null;
        txChar = null;
        connState = FrameConnState.disconnected;
      }
    });

    try {
      await targetDevice.connect(timeout: const Duration(seconds: 10));
      try {
        mtu = await targetDevice.requestMtu(517);
      } catch (_) {
        mtu = 23;
      }

      final services = await targetDevice.discoverServices();
      final nus = services.firstWhere((s) => s.uuid == nusServiceUuid);
      rxChar = nus.characteristics.firstWhere((c) => c.uuid == rxCharUuid);
      txChar = nus.characteristics.firstWhere((c) => c.uuid == txCharUuid);

      await txChar!.setNotifyValue(true);
      notifySub = txChar!.lastValueStream.listen(onNotify);

      log('Connected to ${targetDevice.platformName}');
      connState = FrameConnState.connected;
    } catch (e) {
      log('Connect failed: $e');
      connState = FrameConnState.disconnected;
    }
  }

  (int, Completer<int>) acquireCompleter() {
    final token = ++_bleSeqToken;
    final completer = Completer<int>();
    _pendingCompleters[token] = completer;
    return (token, completer);
  }

  void onNotify(List<int> value) {
    if (value.isEmpty) return;

    if (awaitingDownloadHeader) {
      if (value.length >= 5 && value[0] == downloadHeaderStatus) {
        downloadExpectedSize = value[1] | (value[2] << 8) | (value[3] << 16) | (value[4] << 24);
        awaitingDownloadHeader = false;
        downloadBuilder.clear();
        if (downloadExpectedSize == 0) {
          pendingDownloadCompleter?.complete(Uint8List(0));
        }
      } else {
        pendingDownloadCompleter?.completeError('bad download response (0x${value[0].toRadixString(16)})');
        awaitingDownloadHeader = false;
      }
      return;
    }

    if (downloadExpectedSize > 0 && downloadBuilder.length < downloadExpectedSize) {
      downloadBuilder.add(value);
      if (downloadBuilder.length >= downloadExpectedSize) {
        final bytes = downloadBuilder.toBytes();
        downloadExpectedSize = 0;
        pendingDownloadCompleter?.complete(bytes);
      }
      return;
    }

    final status = value[0];
    log('Device: ${statusNames[status] ?? 'unknown (0x${status.toRadixString(16)})'}');

    if (status == 0x06 && value.length >= 5 && _pendingCompleters.isNotEmpty) {
      final token = _pendingCompleters.keys.reduce(min);
      final completer = _pendingCompleters.remove(token)!;
      if (!completer.isCompleted) {
        final index = value[1] | (value[2] << 8) | (value[3] << 16) | (value[4] << 24);
        completer.complete(index);
      }
    }
  }

  Future<void> sendChunked(Uint8List payload) async {
    final chunkSize = (mtu - 3).clamp(20, 500);
    for (int offset = 0; offset < payload.length; offset += chunkSize) {
      if (rxChar == null) throw Exception('Disconnected during transfer');
      final end = (offset + chunkSize < payload.length) ? offset + chunkSize : payload.length;
      await rxChar!.write(payload.sublist(offset, end), withoutResponse: false);
    }
  }

  Future<double> syncBrightnessFromDevice() async {
    final (token, completer) = acquireCompleter();
    try {
      await sendChunked(buildHeader(getBrightnessCmdMagic, 0));
      final level = await completer.future.timeout(const Duration(seconds: 5));
      return level.toDouble().clamp(0, 255);
    } finally {
      _pendingCompleters.remove(token);
    }
  }

  Future<int> syncImageListCountFromDevice() async {
    final (token, completer) = acquireCompleter();
    try {
      await sendChunked(buildHeader(listCountCmdMagic, 0));
      return await completer.future.timeout(const Duration(seconds: 5));
    } finally {
      _pendingCompleters.remove(token);
    }
  }

  Future<({bool active, int interval, Set<int> playlistIndices})> syncPlaylistFromDevice() async {
    final (token, completer) = acquireCompleter();
    try {
      await sendChunked(buildHeader(getPlaylistCmdMagic, 0));
      final packed = await completer.future.timeout(const Duration(seconds: 5));
      _pendingCompleters.remove(token);

      final active = (packed & 0x80000000) != 0;
      final interval = packed & 0x7FFFFFFF;

      final raw = await downloadRaw(downloadPlaylistCmdMagic, 0);
      final playlistIndices = <int>{};
      for (int i = 0; i + 4 <= raw.length; i += 4) {
        playlistIndices.add(raw[i] | (raw[i + 1] << 8) | (raw[i + 2] << 16) | (raw[i + 3] << 24));
      }

      return (active: active, interval: interval, playlistIndices: playlistIndices);
    } finally {
      _pendingCompleters.remove(token);
    }
  }

  Future<int> uploadImageGetIndex(Uint8List jpeg) async {
    final (token, completer) = acquireCompleter();
    try {
      final payload = Uint8List.fromList(buildHeader(jpegHeaderMagic, jpeg.length) + jpeg);
      await sendChunked(payload);
      return await completer.future.timeout(const Duration(seconds: 5));
    } finally {
      _pendingCompleters.remove(token);
    }
  }

  Future<void> uploadThumbnail(Uint8List thumbJpeg) async {
    try {
      final payload = Uint8List.fromList(buildHeader(thumbnailHeaderMagic, thumbJpeg.length) + thumbJpeg);
      await sendChunked(payload);
    } catch (e) {
      log('Thumbnail upload failed: $e');
    }
  }

  Future<int> uploadImageWithThumbnail(SentImage image) async {
    final bytes = await image.loadFullBytes();
    if (bytes == null) throw Exception('No image data available for upload');
    final index = await uploadImageGetIndex(bytes);
    image.thumbnailBytes ??= makeThumbnail(bytes);
    await uploadThumbnail(image.thumbnailBytes!);
    // Free the in-memory reference; bytes remain on disk if needed for re-upload.
    image.evictFullBytes();
    return index;
  }

  Future<Uint8List> downloadRaw(int magic, int secondField, {Duration timeout = const Duration(seconds: 10)}) async {
    if (rxChar == null) throw Exception('Not connected');
    awaitingDownloadHeader = true;
    downloadBuilder.clear();
    downloadExpectedSize = 0;
    pendingDownloadCompleter = Completer<Uint8List>();
    try {
      await sendChunked(buildHeader(magic, secondField));
      return await pendingDownloadCompleter!.future.timeout(timeout);
    } finally {
      awaitingDownloadHeader = false;
      pendingDownloadCompleter = null;
    }
  }

  Future<Uint8List> downloadImage(int index) => downloadRaw(downloadCmdMagic, index, timeout: const Duration(seconds: 30));
  Future<Uint8List> downloadThumbnail(int index) => downloadRaw(downloadThumbCmdMagic, index);

  Future<void> showImageEntry(int deviceIndex) async {
    await sendChunked(buildHeader(showIndexCmdMagic, deviceIndex));
  }

  Future<void> sendBrightness(int level) async {
    await sendChunked(buildHeader(brightnessCmdMagic, level));
  }

  Future<void> startRotation(List<int> deviceIndices, int intervalSeconds) async {
    await sendChunked(buildHeader(playlistClearMagic, 0));
    for (final index in deviceIndices) {
      await sendChunked(buildHeader(playlistAddMagic, index));
    }
    await sendChunked(buildHeader(playlistStartMagic, intervalSeconds));
  }

  Future<void> stopRotation() async {
    await sendChunked(buildHeader(playlistStopMagic, 0));
  }

  Future<void> sendFormatCommand() async {
    final (token, completer) = acquireCompleter();
    try {
      await sendChunked(buildHeader(formatCmdMagic, 0));
      await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      _pendingCompleters.remove(token);
    }
  }

  void dispose() {
    scanSub?.cancel();
    connSub?.cancel();
    notifySub?.cancel();
    FlutterBluePlus.stopScan();
  }
}
