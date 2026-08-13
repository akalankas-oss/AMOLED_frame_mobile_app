# AMOLED Frame — Flutter Mobile App

A Flutter companion app for a Bluetooth Low Energy (BLE) connected ESP32-P4 AMOLED photo frame. The app builds, edits, and manages images shown on the physical display — pick photos, compose multi-layer graphics (text, emojis, stickers), generate flashing/scrolling banners, and control slideshow rotation, backlight brightness, and on-device storage over BLE.

---

## 📋 Table of Contents

- [Hardware Target & Specifications](#hardware-target--specifications)
- [Features](#features)
- [Project File Structure](#project-file-structure)
- [Image Creation & Upload Pipeline](#image-creation--upload-pipeline)
- [BLE Protocol Command Summary](#ble-protocol-command-summary)
- [Known Bugs & Code Review Audit](#known-bugs--code-review-audit)
- [Requirements & Permissions](#requirements--permissions)
- [Getting Started](#getting-started)

---

## 🎯 Hardware Target & Specifications

- **Panel Resolution:** `192 × 960 px` (native, portrait orientation) — matches `PANEL_H_RES` / `PANEL_V_RES` in the ESP32-P4 firmware's `config.h`. Note that on-screen editing and composition logic works on a `960 × 192` landscape working canvas before rotating 90° CW into native panel buffer orientation.
- **Transport:** Bluetooth Low Energy (BLE), using the Nordic UART Service (NUS).
- **Delivery Format:** Baseline JPEG bytes, `memcpy`'d directly into the panel's framebuffer by the firmware — no scaling, cropping, or rotation happens on-device.
- **Client-Side Processing:** Because the firmware relies on direct framebuffer copies, all cropping, resizing, EXIF orientation baking, and canvas rotation are performed client-side before transmission (see [`image_utils.dart`](lib/utils/image_utils.dart)).

---

## ✨ Features

- **BLE Auto-Connect & Sync:** Scans for devices named `AMOLED-Frame` advertising the NUS service UUID and connects automatically. Synchronizes brightness, image count, thumbnails (`THMB`), and rotation playlist state on connection.
- **Pick Image:** Quick-pick a photo from the gallery, cover-fit and crop to the panel's 960×192 aspect ratio, and queue it for display.
- **Create Image (Canvas Editor):** Full-featured interactive editor allowing multi-layer graphic placement (text, emojis, stickers) with move, scale, rotate, font selection, and photo background repositioning controls.
- **Create Text Image:** Quick text-to-image generator with customizable font size, text color, and background color.
- **Flash Banner:** Sequence generator for scrolling text, blinking messages, or flashing colors converted into a series of panel-resolution animation frames for rotation playback.
- **Image List & Preview:** Grid showing local and on-device images with tap-to-show control and deletion options.
- **Rotation / Playlist:** Timed slideshow playback loop with configurable interval (2s – 30s) and image selection controls.
- **Brightness Control:** Real-time backlight level slider (0–255) sent over BLE.
- **On-Device Storage Management:** Delete selected images or format all hardware SPIFFS flash storage.

---

## 📁 Project File Structure

The project follows a clean, modular architecture separating UI pages, reusable widgets, BLE protocol handlers, data models, and image utilities:

```
lib/
├── main.dart                        # App entry point (main() function)
├── app.dart                         # AmoledFrameApp (MaterialApp configuration & theme)
│
├── ble/
│   ├── frame_ble_service.dart       # Centralized BLE service (task queue, MTU chunking, notification parsing)
│   ├── frame_connection.dart        # Connection state enum (disconnected, scanning, connecting, connected)
│   └── frame_protocol.dart          # NUS UUIDs, command magics, CRC16-CCITT, header builder, status map
│
├── models/
│   ├── editor_item.dart             # Canvas element model (text, emoji, sticker, coordinates, scale, rotation, font style)
│   └── sent_image.dart              # Managed image model (full JPEG bytes, thumbnail bytes, device index, selection state)
│
├── pages/
│   ├── frame_page.dart              # Main dashboard screen (BLE connection UI, image grid, playlist controls, logs)
│   ├── image_editor_page.dart       # Full-featured canvas editor (multi-layer graphics, pinch zoom, background positioning)
│   ├── flash_banner_page.dart       # Generator UI for scrolling/blinking text banner animation frame sequences
│   └── text_composer_page.dart      # Standalone simple text-to-image generator screen
│
├── utils/
│   └── image_utils.dart             # Core image processing (960x192 canvas fitting, EXIF orientation correction, 240x48 thumbnails)
│
└── widgets/
    ├── color_swatch_picker.dart     # Color swatch picker widget for text and background styling
    ├── editor_style_panel.dart      # Canvas editor bottom control bar (font size, rotation, scaling, color pickers)
    └── emoji_sticker_picker.dart    # Tabbed modal sheet for picking emojis and stickers
```

### Module Overview

- **[`ble/`](lib/ble)**: Encapsulates Bluetooth Low Energy logic. [`frame_protocol.dart`](lib/ble/frame_protocol.dart) builds 10-byte binary command headers with CRC16-CCITT checksums. [`frame_ble_service.dart`](lib/ble/frame_ble_service.dart) handles device discovery, MTU negotiation, chunked writes over the RX characteristic, notification parsing from the TX characteristic, and thread-safe BLE task queuing.
- **[`pages/`](lib/pages)**: Contains all primary application screens ([`FramePage`](lib/pages/frame_page.dart), [`ImageEditorPage`](lib/pages/image_editor_page.dart), [`FlashBannerPage`](lib/pages/flash_banner_page.dart), [`TextComposerPage`](lib/pages/text_composer_page.dart)).
- **[`widgets/`](lib/widgets)**: Isolated UI sub-components used across editor and composer pages ([`ColorSwatchPicker`](lib/widgets/color_swatch_picker.dart), [`EditorStylePanel`](lib/widgets/editor_style_panel.dart), [`EmojiStickerPicker`](lib/widgets/emoji_sticker_picker.dart)).
- **[`models/`](lib/models)**: Type definitions for graphics items ([`EditorItem`](lib/models/editor_item.dart)) and image payloads ([`SentImage`](lib/models/sent_image.dart)).
- **[`utils/`](lib/utils)**: Image manipulation functions ensuring exact resolution compatibility (960×192 JPEG output, 240×48 JPEG thumbnails).

---

## 🔄 Image Creation & Upload Pipeline

Below is the step-by-step pipeline detailing how images are created, processed, formatted, queued, and transmitted over BLE to the hardware display.

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                       1. IMAGE CREATION & EDITING                       │
 ├─────────────────┬───────────────────┬─────────────────┬─────────────────┤
 │  A. Pick Image  │  B. Canvas Editor │ C. Text Composer│ D. Flash Banner │
 │ (Gallery photo) │ (Text/Emoji/Stik) │  (Text + Color) │ (Anim sequence) │
 └────────┬────────┴─────────┬─────────┴────────┬────────┴────────┬────────┘
          │                  │                  │                 │
          ▼                  ▼                  ▼                 ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     2. CLIENT-SIDE IMAGE PROCESSING                     │
 │  • Apply EXIF orientation correction (img.bakeOrientation)              │
 │  • Cover-fit & center-crop to 960 × 192 landscape canvas                │
 │  • Render canvas layers to offscreen Picture / PNG                      │
 │  • Encode to JPEG (Quality: 90)                                         │
 │  • Downscale by 4x to produce 240 × 48 thumbnail JPEG (Quality: 80)      │
 └────────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                   3. MANAGEMENT & QUEUING (SentImage)                   │
 │  • Wrapped into SentImage object with full JPEG & thumbnail bytes       │
 │  • Added to active image list in FramePage state                        │
 └────────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     4. BLE PROTOCOL HEADER ASSEMBLY                     │
 │  • Build 10-byte binary header:                                         │
 │    - 4-byte Magic (0x4A504731 for JPG1 image, 0x54484D42 for THMB thumb)  │
 │    - 4-byte Payload Length (Little-Endian)                              │
 │    - 2-byte CRC16-CCITT Checksum over header fields                     │
 │  • Combine payload: [ 10-byte Header ] + [ Raw JPEG Bytes ]             │
 └────────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                 5. CHUNKED BLE TRANSMISSION & ACK SYNC                  │
 │  • Task enqueued into FrameBleService execution queue                   │
 │  • Split payload into MTU-sized chunks (clamped between 20 and 500 B)   │
 │  • Sequential rxChar.write() over Nordic UART Service (NUS)             │
 │  • Hardware verifies CRC & writes JPEG to SPIFFS flash storage          │
 │  • Hardware responds on txChar notify with ACK_OK (0x06) + Device Index │
 └────────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     6. DISPLAY & PLAYLIST EXECUTION                     │
 │  • Send SHIX (Show Index) command to instantly render on panel          │
 │  • Send PADD / PSRT commands to manage automated slideshow playlist     │
 └─────────────────────────────────────────────────────────────────────────┘
```

---

## 📡 BLE Protocol Command Summary

All commands transmitted over the Nordic UART Service (NUS RX Characteristic: `6e400002-b5a3-f393-e0a9-e50e24dcca9e`) use a uniform 10-byte binary header assembled via [`buildHeader(magic, secondField)`](lib/ble/frame_protocol.dart#L49-L56):

| Command | Magic Code | Header Magic (Hex) | Direction | Description |
|---|---|---|---|---|
| Upload Image | `JPG1` | `0x4A504731` | App → Device | Upload full-resolution 192×960 native JPEG image payload |
| Upload Thumbnail | `THMB` | `0x54484D42` | App → Device | Upload 48×240 JPEG thumbnail for fast list sync |
| Show Image by Index | `SHIX` | `0x53484958` | App → Device | Direct panel to render image at specified storage index |
| Set Brightness | `BRIT` | `0x42524954` | App → Device | Update display panel backlight brightness level (0–255) |
| Get Brightness | `GBRT` | `0x47425254` | App → Device | Query current backlight brightness level from device |
| Playlist Add | `PADD` | `0x50414444` | App → Device | Append image index to hardware rotation playlist |
| Playlist Clear | `PCLR` | `0x50434C52` | App → Device | Clear all entries from hardware rotation playlist |
| Playlist Start | `PSRT` | `0x50535254` | App → Device | Begin automated playlist slideshow with rotation interval (seconds) |
| Playlist Stop | `PSTP` | `0x50535450` | App → Device | Pause playlist slideshow rotation |
| Format Storage | `FRMT` | `0x46524D54` | App → Device | Erase all stored images on hardware SPIFFS flash memory |
| List Image Count | `LSCT` | `0x4C534354` | App → Device | Query total count of stored images on device |
| Download Image | `DNLD` | `0x444E4C44` | App → Device | Download full JPEG payload from specified device index |
| Download Thumbnail | `DNLT` | `0x444E4C54` | App → Device | Download 48×240 JPEG thumbnail from specified device index |
| Get Playlist | `GPLS` | `0x47504C53` | App → Device | Read active playlist configuration from device |

---

## 🔍 Known Bugs & Code Review Audit

Detailed codebase audit findings, severity ratings, and recommended refactoring steps are documented in [`Bugs&Improvements.md`](Bugs&Improvements.md). 

### Key Findings Overview
1. **Create Text Double Rotation:** Passing `TextComposerPage` outputs through `ImageEditorPage` results in double-rotated and stretched text.
2. **Canvas Export Resolution Variance:** `RepaintBoundary` captures without a strict post-resize guard can produce non-exact pixel dimensions (e.g. 193×960), causing hardware display shearing.
3. **BLE Task Interleaving & State Duplication:** `_FramePageState` duplicate-implements BLE queueing instead of delegating exclusively to `FrameBleService`, risking response mismatches under rapid user input.
4. **Widget Modularization:** Inline UI code in `ImageEditorPage` duplicates reusable components from [`lib/widgets/`](lib/widgets).

*Refer to [`Bugs&Improvements.md`](Bugs&Improvements.md) for full descriptions and step-by-step fix guides.*

---

## 🛠️ Requirements & Permissions

- **Flutter SDK:** ^3.12.2 (Dart 3.x)
- **Target Hardware:** Physical iOS or Android device with Bluetooth hardware (simulators do not support BLE).
- **Core Package Dependencies (`pubspec.yaml`):**
  - `flutter_blue_plus`: ^1.35.5 (BLE scanning, connection, and GATT operations)
  - `image_picker`: ^1.1.2 (Gallery photo selection)
  - `permission_handler`: ^11.3.1 (Runtime permission requests)
  - `image`: ^4.2.0 (Pure Dart image decoding, EXIF orientation, cropping, scaling, JPEG encoding)

### Permissions Configuration

- **Android (`android/app/src/main/AndroidManifest.xml`):**
  - `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `FINE_LOCATION` / `COARSE_LOCATION`, `READ_MEDIA_IMAGES` / `READ_EXTERNAL_STORAGE`.
- **iOS (`ios/Runner/Info.plist`):**
  - `NSBluetoothAlwaysUsageDescription`, `NSPhotoLibraryUsageDescription`.

---

## 🚀 Getting Started

```bash
# Fetch dependencies
flutter pub get

# Run on a connected physical device
flutter run
```

On launch, the app automatically scans for BLE peripherals advertising the Nordic UART Service under the name `AMOLED-Frame` and establishes connection setup.