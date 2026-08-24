# AMOLED Frame — Code Review, Bugs & Improvements

Comprehensive audit and analysis of the Flutter mobile application (`AMOLED_frame_mobile_app`).

---

## 1. Critical & High Severity Bugs

### 1. Double Rotation & Image Distortion in "Create Text" Flow
- **Status:** **Fixed** (Bypassed `ImageEditorPage` for text composition)
- **Location:** [`lib/pages/frame_page.dart` (lines 461–479)](AMOLED_frame_mobile_app/lib/pages/frame_page.dart#L461-L479)
- **Problem:** Tapping **Create Text** opens `TextComposerPage`, which calls `renderTextToPanelImage()` ([`lib/utils/image_utils.dart`](AMOLED_frame_mobile_app/lib/utils/image_utils.dart#L64-L100)) to produce an already-rotated 192×960 native JPEG. Then `_createTextImage()` immediately pushes this output into `ImageEditorPage(imageBytes: bytes)`. Inside `ImageEditorPage`, `imageBytes` is treated as a background photo on a 960×192 working canvas, forcing the 192×960 image to squeeze horizontally, distorting text. Upon export, `_exportCanvas()` rotates it *again* by 90°, resulting in double-rotated, upside-down, and severely distorted text on the physical frame.
- **Fix:** Bypassed `ImageEditorPage` when creating text directly from `TextComposerPage`. The natively rotated output of `TextComposerPage` is now used directly, preventing distortion.

---

### 2. Canvas Export Does Not Guarantee Exact 192×960 Pixel Dimensions
- **Status:** **Fixed** (Strict `copyResize` guard added after rotation)
- **Location:** [`lib/pages/image_editor_page.dart` (lines 321–376)](file:///c:/Users/anupa/Desktop/Techlabs/AMOLED_frame_app/AMOLED_frame_mobile_app/lib/pages/image_editor_page.dart#L321-L376)
- **Problem:** `_exportCanvas()` calculates `neededPixelRatio = 960 / renderedLogicalWidth` and captures the `RepaintBoundary` via `boundary.toImage(pixelRatio: neededPixelRatio)`. Because screen rendering and subpixel bounds vary across devices, `captured.height` can resolve to values like 191px or 193px instead of exactly 192px. When rotated 90° CW, the resulting image is 193×960 or 191×960. The ESP32-P4 firmware directly `memcpy`s decoded JPEG pixels into a fixed 192×960 framebuffer; any mismatched resolution causes image shearing, line corruption, or out-of-bounds memory crashes.
- **Fix:** Added a strict dimension guard after `copyRotate()`. If the rotated image dimensions are not exactly 192×960, a `copyResize(..., interpolation: Interpolation.linear)` pass forces the output to the correct size before JPEG encoding.

---

### 3. BLE Response Mismatch Risk & Response Interleaving
- **Status:** **Fixed** (Sequence-token map replaces single shared completer; disconnect handler cancels all pending completers)
- **Location:** [`lib/pages/frame_page.dart`](AMOLED_frame_mobile_app/lib/pages/frame_page.dart) & [`lib/ble/frame_ble_service.dart`](AMOLED_frame_mobile_app/lib/ble/frame_ble_service.dart)
- **Problem:** `_pendingIndexCompleter` was a single shared instance variable. `_onNotify` completed it whenever *any* `ACK_OK` (0x06) notification arrived — regardless of which command sent it. `_doStopRotation` also explicitly nulled `_pendingIndexCompleter` in its `finally` block, silently cancelling any unrelated in-flight upload completer. A disconnect left all pending completers hanging until their timeouts fired.
- **Fix:** Replaced the single `_pendingIndexCompleter` field with a sequence-token map (`Map<int, Completer<int>> _pendingCompleters`). Each operation that awaits an ACK calls `_acquireCompleter()` to mint a unique token and register its own `Completer`. `_onNotify` delivers `ACK_OK` to the lowest-token (oldest) pending completer — correct and safe because `_bleQueue` enforces strictly sequential execution. The spurious `_pendingIndexCompleter = null` in `_doStopRotation` is removed. The disconnect handler now immediately cancels all pending completers with an error instead of leaving them to time out.

---

### 4. Code Duplication & Bypassed `FrameBleService` Singleton
- **Status:** **Fixed** (`FrameBleService` singleton expanded to encapsulate all BLE operations and state; `_FramePageState` refactored to delegate exclusively to `FrameBleService.instance`)
- **Location:** [`lib/pages/frame_page.dart`](AMOLED_frame_mobile_app/lib/pages/frame_page.dart) & [`lib/ble/frame_ble_service.dart`](AMOLED_frame_mobile_app/lib/ble/frame_ble_service.dart)
- **Problem:** `_FramePageState` duplicate-implemented almost all BLE logic (`_bleQueue`, `_enqueueBleTask`, `_sendChunked`, `_uploadImageGetIndex`, `_downloadRaw`, `_onNotify`) locally inside the widget state, completely bypassing the `FrameBleService` class created in `lib/ble/frame_ble_service.dart`. This caused duplicated bugs, state fragmentation, and made testing or reusing BLE operations across pages impossible.
- **Fix:** Expanded `FrameBleService` into a full-featured, single-source-of-truth service singleton handling device connection, GATT notifications, task queueing, chunked transfers, and high-level protocol methods. Refactored `_FramePageState` to delegate all BLE commands, state management, and notifications exclusively to `FrameBleService.instance`.

---

### 5. Stale Queued Tasks Persist Across BLE Disconnections
- **Status:** **Fixed** (Centralized `_clearQueueAndRejectPending` in `FrameBleService` clears task queue and fails pending completers immediately on disconnect)
- **Location:** [`lib/ble/frame_ble_service.dart`](AMOLED_frame_mobile_app/lib/ble/frame_ble_service.dart)
- **Problem:** When `BluetoothConnectionState.disconnected` fired, pending queued tasks remained in `_bleQueue` and would attempt execution either upon reconnect or throw unhandled disconnect exceptions mid-loop.
- **Fix:** `FrameBleService`'s disconnect listener now calls `_clearQueueAndRejectPending()`, which empties `bleQueue`, resets `bleProcessing` state, and immediately fails all pending response completers with an exception.

---

## 2. Medium & Low Severity Bugs

### 6. Unconstrained Text Layout in Flash Banner Page
- **Status:** **Fixed** (Constrained layout width for blink/vertical scroll and clipped canvas in `_renderFrame()`)
- **Location:** [`lib/pages/flash_banner_page.dart` (lines 71–81, 90–94)](AMOLED_frame_mobile_app/lib/pages/flash_banner_page.dart#L71-L81)
- **Problem:** `_makeTextPainter()` calls `tp.layout()` without supplying a `maxWidth` constraint. If a user enters long banner text or uses a large font size, `_renderFrame()` paints unclipped text exceeding canvas bounds, causing cut-off characters or rendering artifacts on generated frames.
- **Fix:** Constrain text painting in `_makeTextPainter()` or calculate appropriate scaling based on canvas width.

---

### 7. Widget Modularization Ignored in Image Editor Page
- **Status:** **Fixed** (Replaced inline UI code with imports of reusable widgets)
- **Location:** [`lib/pages/image_editor_page.dart`](AMOLED_frame_mobile_app/lib/pages/image_editor_page.dart) vs [`lib/widgets/`](AMOLED_frame_mobile_app/lib/widgets/)
- **Problem:** Helper widgets `ColorSwatchPicker` ([`lib/widgets/color_swatch_picker.dart`](AMOLED_frame_mobile_app/lib/widgets/color_swatch_picker.dart)), `EditorStylePanel` ([`lib/widgets/editor_style_panel.dart`](AMOLED_frame_mobile_app/lib/widgets/editor_style_panel.dart)), and `EmojiStickerPicker` ([`lib/widgets/emoji_sticker_picker.dart`](AMOLED_frame_mobile_app/lib/widgets/emoji_sticker_picker.dart)) exist in `lib/widgets/`, but `ImageEditorPage` duplicate-defines all swatch pickers, font chips, style panels, and emoji grids inline (over 400 lines of duplicated code).
- **Fix:** Replace inline UI code in `ImageEditorPage` with imports and usages of the reusable widgets in `lib/widgets/`.

---

### 8. Item Delete Button Touch Target & Clipping Issues
- **Status:** **Fixed** (Removed the clipped inline button in favor of the full-width "Delete Selected Item" button in the EditorStylePanel)
- **Location:** [`lib/pages/image_editor_page.dart` (lines 804–820)](AMOLED_frame_mobile_app/lib/pages/image_editor_page.dart#L804-L820)
- **Problem:** The item delete ("×") button is positioned at `Positioned(top: -8, right: -8)` inside a transformed container (`Transform.scale`). When an item is scaled down or placed near the canvas border, `Clip.hardEdge` on line 662 clips the close button, making it unclickable or invisible. Additionally, parent gesture recognizers steal touch events on small items.
- **Fix:** Render selection controls/delete handles in an unclipped overlay layer relative to the active item's bounding box.

---

### 9. Rotation Interval Sync Ignores Out-of-Range Firmware Values
- **Status:** **Fixed** (Clamped incoming intervals to valid bounds [2.0, 30.0] and added a warning log)
- **Location:** [`lib/pages/frame_page.dart` (lines 336–338)](AMOLED_frame_mobile_app/lib/pages/frame_page.dart#L336-L338)
- **Problem:** During playlist sync (`_syncPlaylistFromDevice`), the app checks `if (interval >= 2 && interval <= 30)`. If the device was configured with a different interval (e.g. 1s or 60s), the app silently ignores the value, leaving `_rotationSeconds` out of sync with actual hardware behavior without notifying the user.
- **Fix:** Clamp incoming intervals to valid slider bounds `interval.toDouble().clamp(2.0, 30.0)` and log a warning if out-of-range values are normalized.

---

### 10. Unmanaged In-Memory Image Byte Cache
- **Status:** **Fixed** (Spilled full JPEG byte arrays to temporary disk files with on-demand lazy loading via `loadFullBytes()` and cache eviction on upload)
- **Location:** [`lib/models/sent_image.dart`](AMOLED_frame_mobile_app/lib/models/sent_image.dart#L12-L13) & [`lib/pages/frame_page.dart`](AMOLED_frame_mobile_app/lib/pages/frame_page.dart)
- **Problem:** `SentImage` holds full resolution `Uint8List` image byte arrays in memory indefinitely. Picking or generating dozens of images retains megabytes of uncompressed image buffers in RAM, leading to memory pressure on low-end devices.
- **Fix:** Stored full image bytes to temporary disk files via `persistFullBytes()` / `persistSequenceFrames()`, kept only small thumbnails in memory for UI previews, and loaded full bytes on-demand during BLE upload.

---

### 11. Android 13+ Media Permission Support Gap
- **Status:** **Fixed** (Added `Permission.photos` and `Permission.storage` requests to permission checks)
- **Location:** [`lib/pages/frame_page.dart` (lines 107–114)](AMOLED_frame_mobile_app/lib/pages/frame_page.dart#L107-L114)
- **Problem:** `_ensurePermissions()` checks `Permission.bluetoothScan`, `Permission.bluetoothConnect`, and `Permission.locationWhenInUse`, but omitted checking photo/media permissions (`Permission.photos` / `Permission.storage`). On Android 13+ (API 33+), granular media permissions are required when picking images on specific custom Android builds.
- **Fix:** Updated permission handling to check `Permission.photos` (API 33+) and `Permission.storage` (API <= 32) gracefully without blocking BLE connection if photo access is declined.

---

## 3. Improvements & Enhancements Status

### Architectural & Code Quality Improvements

#### 1. Unify Protocol & BLE Layer
- **Status:** **Completed** (Resolved alongside Bug #4)
- **Location:** [`lib/ble/frame_ble_service.dart`](AMOLED_frame_mobile_app/lib/ble/frame_ble_service.dart) & [`lib/pages/frame_page.dart`](AMOLED_frame_mobile_app/lib/pages/frame_page.dart)
- **Details:** Consolidated BLE operations, connection lifecycle, task queueing, notifications, and GATT transfers into the `FrameBleService` singleton. `_FramePageState` now delegates exclusively to `FrameBleService.instance`.

---

#### 2. Add Command Identification / CRC Verification
- **Status:** **Completed** (CRC-16 CCITT Header Packing) / **Pending** (Incoming Stream Verification)
- **Location:** [`lib/ble/frame_protocol.dart` (lines 34–56)](AMOLED_frame_mobile_app/lib/ble/frame_protocol.dart#L34-L56)
- **Details:** 
  - ✅ Implemented `crc16Ccitt()` and header CRC packing inside `buildHeader()`.
  - ⏳ Inbound download chunk CRC validation from firmware stream can be added when firmware protocol supports download stream checksums.

---

#### 3. Refactor State Management
- **Status:** **Pending**
- **Location:** [`lib/pages/frame_page.dart`](AMOLED_frame_mobile_app/lib/pages/frame_page.dart)
- **Details:** `_FramePageState` manages presentation, multi-step image pipelines, and page state locally using `setState`. Moving business logic to `ChangeNotifier` / `ValueNotifier` or a state management library (e.g., `flutter_bloc` / `riverpod`) will decouple UI from device communications and improve testability.

---

### UI / UX Enhancements

#### 4. Multi-Item Upload Progress Indicator
- **Status:** **Pending**
- **Location:** [`lib/pages/frame_page.dart` (lines 1018–1022)](AMOLED_frame_mobile_app/lib/pages/frame_page.dart#L1018-L1022)
- **Details:** Currently uses an indeterminate `LinearProgressIndicator`. Needs a determinate multi-stage progress component displaying "Uploading image X of Y (Z%)" during bulk uploads (`_sendSelectedToDevice`), playlist sync, and delete/re-upload routines.

---

#### 5. In-App Device Log & Console Viewer
- **Status:** **Pending** (Backend logging ready, UI widget pending)
- **Location:** [`lib/pages/frame_page.dart` (lines 101–106)](AMOLED_frame_mobile_app/lib/pages/frame_page.dart#L101-L106)
- **Details:** `_addLog()` already collects logs into an in-memory `List<String> _log`, but there is no UI component rendering it. An expandable bottom sheet or collapsible debug log viewer should be added so users and testers can view real-time BLE transaction logs directly in the app.

---

#### 6. Auto-Reconnect & Persistent Offline Banner
- **Status:** **Pending**
- **Location:** [`lib/ble/frame_ble_service.dart`](AMOLED_frame_mobile_app/lib/ble/frame_ble_service.dart) & [`lib/pages/frame_page.dart`](AMOLED_frame_mobile_app/lib/pages/frame_page.dart)
- **Details:** Currently displays an "Offline" badge and a manual "Reconnect" button. Needs automated exponential backoff reconnection upon unexpected disconnection and a non-intrusive persistent status banner.

---

#### 7. Per-Image Deletion Firmware Protocol Support
- **Status:** **Pending** (Firmware + App Protocol Extension)
- **Location:** [`lib/ble/frame_protocol.dart`](AMOLED_frame_mobile_app/lib/ble/frame_protocol.dart) & [`lib/pages/frame_page.dart` (lines 700–800)](AMOLED_frame_mobile_app/lib/pages/frame_page.dart#L700-L800)
- **Details:** App currently executes a costly workaround to delete images (downloads all items to disk, formats flash via `formatCmdMagic`, then re-uploads kept items). Introducing a dedicated `CMD_DELETE` (by index/slot) in the ESP32-P4 firmware and app protocol will make image deletion instantaneous.

---

### Testing & QA Strategy

#### 8. Unit Tests for Protocol Framing & Math
- **Status:** **Pending**
- **Location:** `test/` (`test/ble_protocol_test.dart`, `test/image_math_test.dart`)
- **Details:** Add automated unit tests for:
  - `crc16Ccitt` checksum against known vector standards.
  - `buildHeader` byte alignment and endianness.
  - `fitImageToPanel` cropping, aspect ratios, and 90° CW rotation dimensions (192×960).
  - `renderTextToPanelImage` text layout constraints and output image bounds.

---

#### 9. Widget & Integration Tests
- **Status:** **Pending**
- **Location:** [`test/widget_test.dart`](AMOLED_frame_mobile_app/test/widget_test.dart)
- **Details:** Replace starter widget test template with UI smoke tests for navigation, editor canvas interactions, sticker/color pickers, and disconnected/connected state toggles.