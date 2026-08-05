# AMOLED Frame

A Flutter companion app for a Bluetooth-connected ESP32-P4 AMOLED photo frame. The app builds and manages the images shown on the frame's display — pick photos, compose text/emoji/sticker graphics, generate flashing/scrolling banners, and control playback, brightness, and on-device storage over BLE.

## Hardware target

- **Panel resolution:** 192 × 960 px (native, portrait) — matches `PANEL_H_RES` / `PANEL_V_RES` in the ESP32-P4 firmware's `config.h`.
- **Transport:** Bluetooth Low Energy, using the Nordic UART Service (NUS).
- **Delivery format:** JPEG, memcpy'd straight into the panel's framebuffer by the firmware — no scaling or rotation happens on-device, so every image the app sends must already be exactly 192×960.

Because the firmware does no image processing, all cropping, resizing, and rotation is handled client-side before upload (see `image_utils.dart`).

## Features

- **BLE auto-connect** — scans for a device named `AMOLED-Frame` advertising the NUS service and connects automatically on launch.
- **Pick Image** — select a photo from the gallery, auto cover-fit/cropped to the panel's aspect ratio, and queue it for upload.
- **Create Image** — pick a photo and open it in a full-screen editor to add text, emoji, and stickers before sending.
- **Create Text Image** (`text_composer_page.dart`) — type a short message, pick font size and text/background colors, and render it straight into a panel-ready image.
- **Flash Banner** — compose a scrolling or blinking text banner; it's rendered as a sequence of panel-resolution frames that are queued into the image list (pre-selected for rotation) and played back through the normal playlist pipeline.
- **Image list & preview** — thumbnails for every local and on-device image, with tap-to-show on the panel.
- **Rotation / playlist** — select multiple images, push them to the device, and start/stop a timed slideshow (configurable interval).
- **Brightness control** — read and set the panel's backlight level.
- **Delete / Format** — remove selected images (re-uploading the ones you keep, since the device only supports a full-storage format) or wipe all on-device storage.
- **Device sync** — on connect, the app reads back brightness, the on-device image count (downloading thumbnails for anything it doesn't already know about), and the current playlist state, so app and device stay consistent across sessions.

## Project structure

```
lib/
├── main.dart               # App entry point, BLE protocol, FramePage (main UI),
│                            # FlashBannerPage, ImageEditorPage
├── image_utils.dart        # Image fitting/rotation/thumbnail helpers shared by
│                            # every image-producing flow
└── text_composer_page.dart # Simple text -> image composer UI
```

### `image_utils.dart`

All image-producing code paths funnel through here so every image sent to the panel is treated identically:

- `fitImageToPanel(bytes)` — cover-fits an arbitrary source image into a 960×192 landscape working canvas (crop to aspect, then center-crop), then rotates 90° clockwise into the panel's native 192×960 buffer.
- `renderTextToPanelImage(...)` — draws text onto the same 960×192 landscape canvas, then rotates it the same way, so text and photo composition share one coordinate system.
- `makeThumbnail(nativeJpeg)` — downscales an already panel-native JPEG to a small 48×240 thumbnail, used for both the on-screen image list and the device's fast thumbnail sync (`THMB`) command.

### `main.dart`

- **BLE protocol** — a small binary command protocol over NUS: each command is a 10-byte header (4-byte magic, 4-byte parameter, 2-byte CRC16/CCITT) optionally followed by a JPEG payload, chunked to fit the negotiated MTU. Commands cover: upload image/thumbnail, show-by-index, get/set brightness, playlist add/clear/start/stop, format storage, list count, and download image/thumbnail/playlist.
- **`FramePage`** — the main screen: connection status, image grid, rotation controls, brightness slider, and an activity log.
- **`FlashBannerPage`** — composes scrolling or blinking text banners as a sequence of frames.
- **`ImageEditorPage`** — a canvas editor for layering text, emoji, and stickers (with move/scale/rotate, font, color, and style controls) onto a background photo before export.

### `text_composer_page.dart`

`TextComposerPage` — a lightweight standalone screen (message, font size, text/background color swatches) that renders straight to a panel-ready image via `renderTextToPanelImage`, then returns the bytes to the caller (typically chained into `ImageEditorPage` for further editing).

## Suggested file structure

`main.dart` currently holds ~2,350 lines and five distinct responsibilities (app shell, BLE protocol, three separate full-screen pages, and a data model), which makes it hard to navigate and to test the BLE layer in isolation. A structure that splits along those seams:

```
lib/
├── main.dart                        # runApp() only
├── app.dart                         # AmoledFrameApp (MaterialApp/theme)
│
├── ble/
│   ├── frame_protocol.dart          # command magics, _buildHeader, _crc16Ccitt, status codes
│   ├── frame_connection.dart        # FrameConnState enum + scan/connect/disconnect
│   └── frame_ble_service.dart       # single BLE gateway: chunked write/read, command
│                                     # queue (fixes the shared-completer race condition),
│                                     # upload/download/playlist/brightness calls
│
├── models/
│   ├── sent_image.dart              # SentImage (currently _SentImage)
│   └── editor_item.dart             # EditorItem
│
├── pages/
│   ├── frame_page.dart              # FramePage — main screen
│   ├── flash_banner_page.dart       # FlashBannerPage
│   ├── image_editor_page.dart       # ImageEditorPage
│   └── text_composer_page.dart      # TextComposerPage (already isolated)
│
├── widgets/
│   ├── color_swatch_picker.dart     # shared swatch row — currently reimplemented
│   │                                 # separately in FramePage, FlashBannerPage, and
│   │                                 # ImageEditorPage with inconsistent Color APIs
│   ├── emoji_sticker_picker.dart    # emoji/sticker tab bar + grids
│   └── editor_style_panel.dart      # bottom scale/rotation/font/style controls
│
└── utils/
    └── image_utils.dart             # existing fit/render/thumbnail helpers
```

Rationale:

- **`ble/`** isolates the wire protocol and connection state from any UI code, so the chunking/CRC/command-queue logic can be unit tested without a widget tree, and so a single service object can own the shared `_pendingIndexCompleter`-style state safely (see the concurrency issues noted in `BUGS_AND_IMPROVEMENTS.md`) instead of it living on `_FramePageState`.
- **`models/`** separates plain data classes from the widgets that display them.
- **`pages/`** gives each full-screen flow (`FramePage`, `FlashBannerPage`, `ImageEditorPage`, `TextComposerPage`) its own file, matching the pattern `text_composer_page.dart` already follows — this alone would cut `main.dart` from ~2,350 lines to a handful.
- **`widgets/`** pulls out the color-swatch picker, emoji/sticker grid, and editor style panel, each of which is currently duplicated or embedded inline inside `ImageEditorPage`'s `build()`. Consolidating the swatch picker also naturally fixes the `Color.value` vs `toARGB32()` inconsistency by giving it one implementation.
- **`utils/`** stays as-is; it's already appropriately scoped and reused everywhere.

## Requirements

- Flutter SDK (stable channel)
- A physical device with Bluetooth (BLE is not available on most simulators/emulators)
- Packages used: `flutter_blue_plus`, `image_picker`, `permission_handler`, `image`

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_blue_plus: ^latest
  image_picker: ^latest
  permission_handler: ^latest
  image: ^latest
```

### Permissions

The app requests Bluetooth scan/connect and location-when-in-use permissions at runtime (required by Android for BLE scanning). Make sure your platform manifests are configured accordingly:

- **Android:** `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, and location permissions in `AndroidManifest.xml`.
- **iOS:** `NSBluetoothAlwaysUsageDescription` (and photo library usage description for `image_picker`) in `Info.plist`.

## Getting started

```bash
flutter pub get
flutter run
```

On launch, the app scans for a BLE device advertising the Nordic UART Service under the name `AMOLED-Frame` and connects automatically.

## BLE protocol summary

| Command | Magic | Direction |
|---|---|---|
| Upload image | `JPG1` | App → device |
| Upload thumbnail | `THMB` | App → device |
| Show image by index | `SHIX` | App → device |
| Set brightness | `BRIT` | App → device |
| Get brightness | `GBRT` | App → device |
| Playlist add | `PADD` | App → device |
| Playlist clear | `PCLR` | App → device |
| Playlist start | `PSRT` | App → device |
| Playlist stop | `PSTP` | App → device |
| Format storage | `FRMT` | App → device |
| List image count | `LSCT` | App → device |
| Download image | `DNLD` | App → device |
| Download thumbnail | `DNLT` | App → device |
| Get playlist | `GPLS` | App → device |
| Download playlist | `DPLS` | App → device |

Each header is 10 bytes (magic + parameter, little-endian, plus a CRC16/CCITT checksum), sent chunked to the negotiated MTU. Device responses use a 1-byte status code (`ACK_OK`, or a `NACK_*` error) optionally followed by a 4-byte index/value.

## Notes

- All device-bound images are cropped/rotated to exactly 192×960 before upload — anything else will render corrupted on the physical panel, since the firmware performs no scaling or rotation.
- Deleting a subset of images requires re-uploading everything you keep, because the device firmware only supports a full-storage format, not per-index delete.