import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// Matches the Nordic UART Service exposed by the ESP32-P4 firmware
final Guid nusServiceUuid = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
final Guid rxCharUuid = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e'); // write
final Guid txCharUuid = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e'); // notify

const int jpegHeaderMagic = 0x4A504731;
const int thumbnailHeaderMagic = 0x54484D42;
const int showIndexCmdMagic = 0x53484958;
const int brightnessCmdMagic = 0x42524954;
const int playlistAddMagic = 0x50414444;
const int playlistClearMagic = 0x50434C52;
const int playlistStartMagic = 0x50535254;
const int playlistStopMagic = 0x50535450;
const int formatCmdMagic = 0x46524D54;
const int listCountCmdMagic = 0x4C534354;
const int downloadCmdMagic = 0x444E4C44;
const int downloadThumbCmdMagic = 0x444E4C54;
const int getBrightnessCmdMagic = 0x47425254;
const int getPlaylistCmdMagic = 0x47504C53;
const int downloadPlaylistCmdMagic = 0x44504C53;
const int downloadHeaderStatus = 0x07;

const Map<int, String> statusNames = {
  0x06: 'ACK_OK',
  0xE1: 'NACK_HEADER',
  0xE2: 'NACK_TOO_BIG',
  0xE3: 'NACK_NO_IMAGE',
  0xE4: 'NACK_BAD_INDEX',
};

int crc16Ccitt(List<int> data) {
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

Uint8List buildHeader(int magic, int secondField) {
  final bytes = ByteData(10);
  bytes.setUint32(0, magic, Endian.little);
  bytes.setUint32(4, secondField, Endian.little);
  final crc = crc16Ccitt(bytes.buffer.asUint8List(0, 8));
  bytes.setUint16(8, crc, Endian.little);
  return bytes.buffer.asUint8List();
}
