import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'frame_protocol.dart';
import 'frame_connection.dart';
import '../models/sent_image.dart';

class FrameBleService {
  static final FrameBleService instance = FrameBleService._internal();
  FrameBleService._internal();

  FrameConnState connState = FrameConnState.disconnected;
  BluetoothDevice? device;
  BluetoothCharacteristic? rxChar;
  BluetoothCharacteristic? txChar;
  StreamSubscription<List<ScanResult>>? scanSub;
  StreamSubscription<BluetoothConnectionState>? connSub;
  StreamSubscription<List<int>>? notifySub;
  int mtu = 23;
  Completer<int>? pendingIndexCompleter;

  bool awaitingDownloadHeader = false;
  int downloadExpectedSize = 0;
  final BytesBuilder downloadBuilder = BytesBuilder();
  Completer<Uint8List>? pendingDownloadCompleter;

  final List<Future<void> Function()> bleQueue = [];
  bool bleProcessing = false;

  void Function(String)? onLog;
  void Function(int)? onBrightnessSynced;
  void Function(List<SentImage>)? onImagesSynced;
  void Function(bool, double, List<int>)? onPlaylistSynced;

  Future<T> enqueueBleTask<T>(Future<T> Function() task, {bool highPriority = false}) {
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
      try { await task(); } catch (e) { print('BLE Task Error: $e'); }
    }
    bleProcessing = false;
  }

  void log(String message) {
    if (onLog != null) onLog!(message);
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
        pendingDownloadCompleter?.completeError('bad download response');
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

    final completer = pendingIndexCompleter;
    if (status == 0x06 && value.length >= 5 && completer != null && !completer.isCompleted) {
      final index = value[1] | (value[2] << 8) | (value[3] << 16) | (value[4] << 24);
      completer.complete(index);
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

  Future<int> uploadImageGetIndex(Uint8List jpeg) async {
    pendingIndexCompleter = Completer<int>();
    try {
      final payload = Uint8List.fromList(buildHeader(jpegHeaderMagic, jpeg.length) + jpeg);
      await sendChunked(payload);
      return await pendingIndexCompleter!.future.timeout(const Duration(seconds: 5));
    } finally {
      pendingIndexCompleter = null;
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
    final index = await uploadImageGetIndex(image.fullBytes!);
    image.thumbnailBytes ??= image.thumbnailBytes; // Would need makeThumbnail
    await uploadThumbnail(image.thumbnailBytes!);
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

  Future<void> sendFormatCommand() async {
    pendingIndexCompleter = Completer<int>();
    try {
      await sendChunked(buildHeader(formatCmdMagic, 0));
      await pendingIndexCompleter!.future.timeout(const Duration(seconds: 30));
    } finally {
      pendingIndexCompleter = null;
    }
  }
}
