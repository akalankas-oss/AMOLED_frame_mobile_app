# AMOLED Frame

A Flutter companion app for a Bluetooth-connected ESP32-P4 AMOLED photo frame. The app builds and manages the images shown on the frame's display — pick photos, compose text/emoji/sticker graphics, generate flashing/scrolling banners, and control playback, brightness, and on-device storage over BLE.

## Hardware Target

- **Panel Resolution:** 192 × 960 px (native, portrait) — matches `PANEL_H_RES` / `PANEL_V_RES` in the ESP32-P4 firmware's `config.h`. Note that image composition logic works on a 960 × 192 landscape canvas.
- **Transport:** Bluetooth Low Energy (BLE), using the Nordic UART Service (NUS).
- **Delivery Format:** JPEG, memcpy'd straight into the panel's framebuffer by the firmware — no scaling or rotation happens on-device, so every image the app sends must already be formatted to exact panel dimensions.

Because the firmware does no image processing, all cropping, resizing, and orientation handling is performed client-side before upload (see [`image_utils.dart`](AMOLED_frame_mobile_app/lib/utils/image_utils.dart)).

## Features

- **BLE Auto-Connect** — Scans for a device named `AMOLED-Frame` advertising NUS service UUID and connects automatically on launch.
- **Pick Image** — Select a photo from the gallery, auto cover-fit/cropped to the panel's 960×192 aspect ratio, and queue it for upload.
- **Create Image (Canvas Editor)** — Pick a photo and open it in a full-screen canvas editor to add text, emoji, and stickers with move/scale/rotate controls before sending.
- **Create Text Image** — Type a message, pick font size, text color, and background color to render a panel-ready graphic.
- **Flash Banner** — Compose scrolling, blinking, or color-flashing text banners generated as a sequence of panel-resolution frames for rotation playback.
- **Image List & Preview** — High-performance thumbnail grid for local and on-device images with tap-to-show control.
- **Rotation / Playlist** — Select multiple images, push them to the device, and control a timed slideshow playback loop.
- **Brightness Control** — Real-time backlight level adjustment via BLE.
- **Delete / Format Storage** — Remove selected images (re-uploading kept images) or format all on-device storage.
- **Device Sync** — On connection, automatically syncs brightness, image count, thumbnails (`THMB`), and playlist state between app and hardware.

## Project File Structure

The project follows a clean, modular architecture separating UI pages, reusable widgets, BLE protocol handlers, data models, and image utilities:

```
lib/
├── main.dart                        # App entry point (main() function)
├── app.dart                         # AmoledFrameApp (MaterialApp configuration & dark theme)
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

- **[`ble/`](AMOLED_frame_mobile_app/lib/ble)**: Encapsulates all Bluetooth Low Energy logic. [`frame_protocol.dart`](AMOLED_frame_mobile_app/lib/ble/frame_protocol.dart) builds 10-byte binary command headers with CRC16-CCITT checksums. [`frame_ble_service.dart`](AMOLED_frame_mobile_app/lib/ble/frame_ble_service.dart) handles device discovery, MTU negotiation, chunked writes over the RX characteristic, notification parsing from the TX characteristic, and thread-safe BLE task queuing.
- **[`pages/`](AMOLED_frame_mobile_app/lib/pages)**: Contains all primary application screens ([`FramePage`](AMOLED_frame_mobile_app/lib/pages/frame_page.dart), [`ImageEditorPage`](AMOLED_frame_mobile_app/lib/pages/image_editor_page.dart), [`FlashBannerPage`](AMOLED_frame_mobile_app/lib/pages/flash_banner_page.dart), [`TextComposerPage`](AMOLED_frame_mobile_app/lib/pages/text_composer_page.dart)).
- **[`widgets/`](AMOLED_frame_mobile_app/lib/widgets)**: Isolated UI sub-components used across editor and composer pages ([`ColorSwatchPicker`](AMOLED_frame_mobile_app/lib/widgets/color_swatch_picker.dart), [`EditorStylePanel`](AMOLED_frame_mobile_app/lib/widgets/editor_style_panel.dart), [`EmojiStickerPicker`](AMOLED_frame_mobile_app/lib/widgets/emoji_sticker_picker.dart)).
- **[`models/`](AMOLED_frame_mobile_app/lib/models)**: Strong type definitions for graphics items ([`EditorItem`](AMOLED_frame_mobile_app/lib/models/editor_item.dart)) and image payloads ([`SentImage`](AMOLED_frame_mobile_app/lib/models/sent_image.dart)).
- **[`utils/`](AMOLED_frame_mobile_app/lib/utils)**: Image manipulation functions ensuring exact resolution compatibility (960×192 JPEG output, 240×48 JPEG thumbnails).

## Entire Flow: From Image Creation to Sending to Device

Below is the step-by-step pipeline detailing how images are created/processed, formatted, queued, and transmitted over BLE to the hardware display.

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
 │  • Split payload into MTU-sized chunks (e.g. 20-500 bytes)              │
 │  • Sequential rxChar.write() over Nordic UART Service (NUS)             │
 │  • Hardware verifies CRC & writes JPEG to flash storage                 │
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

### Detailed Flow Breakdown

#### Step 1: Image Creation & Input Sources
Images originate from four user creation pathways:
1. **Gallery Quick Pick (`_pickImage`)**: User picks a photo from device gallery via `ImagePicker`.
2. **Interactive Canvas Editor (`_createImageWithEditing` / [`ImageEditorPage`](AMOLED_frame_mobile_app/lib/pages/image_editor_page.dart))**: Photo is downscaled to max 1000px dimension with EXIF orientation baked, then opened in an interactive 960×192 canvas. Users can add multi-layer text labels, emojis, stickers, and adjust scale/rotation/positioning.
3. **Text Composer (`_createTextImage` / [`TextComposerPage`](AMOLED_frame_mobile_app/lib/pages/text_composer_page.dart))**: User types message text, selects font size, text color, and background color. `renderTextToPanelImage` paints the text onto an offscreen canvas and outputs JPEG bytes.
4. **Flash Banner (`_openFlashBanner` / [`FlashBannerPage`](AMOLED_frame_mobile_app/lib/pages/flash_banner_page.dart))**: User configures scrolling text, blinking messages, or flashing colors. Generates a list of frame-by-frame 960×192 JPEG images pre-selected for rotation playback.

#### Step 2: Pre-Processing & Canvas Fitting ([`image_utils.dart`](AMOLED_frame_mobile_app/lib/utils/image_utils.dart))
To prevent visual distortion or corruption on the physical display:
- **EXIF Baking**: `img.bakeOrientation()` transforms raw pixels to match EXIF metadata, resolving orientation mismatches on camera photos.
- **Canvas Cover-Fitting (`fitImageToPanel`)**: Source images are scaled to cover 960×192 dimensions and center-cropped.
- **JPEG Re-Encoding**: Formatted canvas is encoded to JPEG at 90% quality.
- **Thumbnail Generation (`makeThumbnail`)**: Downscales 960×192 JPEG by 4x to 240×48 JPEG (80% quality) for low-latency local UI rendering and on-device thumbnail sync.

#### Step 3: Local Queuing & Model Wrapping
Processed bytes are stored in a [`SentImage`](AMOLED_frame_mobile_app/lib/models/sent_image.dart) model (containing full JPEG bytes, thumbnail bytes, display label, and selection state) and appended to `_sentImages` list in `FramePage`.

#### Step 4: BLE Binary Command Framing ([`frame_protocol.dart`](AMOLED_frame_mobile_app/lib/ble/frame_protocol.dart))
When an image is pushed to the device:
1. **Header Construction**: `buildHeader(magic, length)` creates a 10-byte packet:
   - Bytes `[0..3]`: Magic number (`0x4A504731` for `JPG1` image, `0x54484D42` for `THMB` thumbnail).
   - Bytes `[4..7]`: Payload size in bytes (32-bit unsigned, little-endian).
   - Bytes `[8..9]`: CRC16-CCITT checksum over the first 8 header bytes.
2. **Payload Assembly**: The header is prepended to the raw JPEG byte array.

#### Step 5: Chunked BLE Transmission & Sync ([`frame_ble_service.dart`](AMOLED_frame_mobile_app/lib/ble/frame_ble_service.dart))
1. **Task Queueing**: Tasks are enqueued via `enqueueBleTask()` to prevent overlapping BLE writes.
2. **MTU Chunking**: Combined payload (`10-byte header + JPEG bytes`) is chunked according to negotiated MTU `(mtu - 3)` bytes (clamped between 20 and 500 bytes).
3. **NUS Write**: Chunks are sequentially written to Nordic UART RX characteristic (`6e400002-b5a3-f393-e0a9-e50e24dcca9e`).
4. **Device Response**: ESP32-P4 firmware validates CRC, writes JPEG payload to SPIFFS flash memory, and returns an `ACK_OK` (`0x06`) notification containing the assigned storage index over the TX characteristic (`6e400003-b5a3-f393-e0a9-e50e24dcca9e`).
5. **Thumbnail Sync**: App immediately follows up by transmitting the 240×48 thumbnail (`THMB` magic) to enable fast on-device list sync without downloading full images.

#### Step 6: On-Device Display & Playlist Controls
- **Instant Display (`SHIX`)**: Sending `buildHeader(showIndexCmdMagic, deviceIndex)` instructs the device to copy the specified JPEG straight into the AMOLED panel framebuffer.
- **Playlist Slideshow (`PADD`, `PSRT`)**: `PADD` registers image indices to the hardware playlist, and `PSRT` starts automated timed slideshow rotation on the device.

## Requirements

- Flutter SDK (stable channel)
- Physical iOS or Android device with Bluetooth hardware (simulators do not support BLE)
- Core Dependencies (`pubspec.yaml`):
  - `flutter_blue_plus`: BLE communication
  - `image_picker`: Photo library selection
  - `permission_handler`: Runtime Bluetooth & Location permission requests
  - `image`: Image decoding, EXIF orientation, cropping, and JPEG encoding

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_blue_plus: ^1.35.0
  image_picker: ^1.1.2
  permission_handler: ^11.3.1
  image: ^4.3.0
```

### Permissions Configuration

- **Android (`android/app/src/main/AndroidManifest.xml`):**
  - `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `FINE_LOCATION` / `COARSE_LOCATION`.
- **iOS (`ios/Runner/Info.plist`):**
  - `NSBluetoothAlwaysUsageDescription`, `NSPhotoLibraryUsageDescription`.

## Getting Started

```bash
flutter pub get
flutter run
```

On launch, the app automatically scans for BLE peripherals advertising the Nordic UART Service under the name `AMOLED-Frame` and completes connection setup.

## BLE Protocol Command Summary

| Command | Magic Code | Header Magic (Hex) | Direction | Description |
|---|---|---|---|---|
| Upload Image | `JPG1` | `0x4A504731` | App → Device | Upload full-resolution 960×192 JPEG image payload |
| Upload Thumbnail | `THMB` | `0x54484D42` | App → Device | Upload 240×48 JPEG thumbnail for fast sync |
| Show Image by Index | `SHIX` | `0x53484958` | App → Device | Direct panel to render image at specified storage index |
| Set Brightness | `BRIT` | `0x42524954` | App → Device | Update display panel backlight brightness level (0-255) |
| Get Brightness | `GBRT` | `0x47425254` | App → Device | Query current backlight brightness level |
| Playlist Add | `PADD` | `0x50414444` | App → Device | Append image index to hardware rotation playlist |
| Playlist Clear | `PCLR` | `0x50434C52` | App → Device | Clear all entries from hardware rotation playlist |
| Playlist Start | `PSRT` | `0x50535254` | App → Device | Begin automated playlist slideshow with rotation interval |
| Playlist Stop | `PSTP` | `0x50535450` | App → Device | Pause playlist slideshow rotation |
| Format Storage | `FRMT` | `0x46524D54` | App → Device | Erase all stored images on hardware flash memory |
| List Image Count | `LSCT` | `0x4C534354` | App → Device | Query total count of stored images on device |
| Download Image | `DNLD` | `0x444E4C44` | App → Device | Download full JPEG payload from specified device index |
| Download Thumbnail | `DNLT` | `0x444E4C54` | App → Device | Download 240×48 JPEG thumbnail from specified index |
| Get Playlist | `GPLS` | `0x47504C53` | App → Device | Read active playlist configuration |