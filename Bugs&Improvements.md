# AMOLED Frame — Code Review Findings

Findings from reviewing `main.dart`, `image_utils.dart`, and `text_composer_page.dart`.

## Bugs

### 1. Editor/Banner images are uploaded as PNG mislabeled as JPEG (most serious)

`ImageEditorPage._exportCanvas()` and `FlashBannerPage._renderFrame()` both encode their output with `ui.ImageByteFormat.png` and never pass it through `img.encodeJpg()`. But `_uploadImageGetIndex()` always tags the payload with the `JPG1` header magic, and the firmware is documented to run a JPEG decoder directly on the bytes.

So every image created via **Create Image**, **Create Text**, or **Flash Banner** — arguably the app's main features — actually uploads raw PNG bytes under a JPEG header. Only the plain **Pick Image** flow (via `fitImageToPanel`) and the *intermediate* text-composer render actually produce real JPEG. This will very likely fail to decode or render garbage on real hardware.

`makeThumbnail()` happens to still work because `img.decodeImage()` auto-detects PNG, which is probably why this has gone unnoticed — the thumbnails look right even though the full image is broken.

### 2. `ImageEditorPage._exportCanvas()` doesn't guarantee exact 192×960 output

The `RepaintBoundary` only fixes the *aspect ratio* (via `AspectRatio`), not the absolute pixel size — actual size is whatever `LayoutBuilder`'s constraints resolve to on screen. `boundary.toImage(pixelRatio: 1.0)` then captures that arbitrary size, with no resize step down to `panelWidth x panelHeight` afterward.

Combined with bug #1, edited images can be both the wrong format and the wrong resolution — exactly the "corrupted/sheared" failure mode the comments at the top of `image_utils.dart` warn about.

### 3. Scan timeout leaves the app stuck in "Scanning..." forever

In `_connectToFrame()`, if the 10-second scan (`FlutterBluePlus.startScan(timeout: ...)`) expires without finding a device named `AMOLED-Frame`, nothing ever transitions `_connState` back to `disconnected`. The UI only shows a "Reconnect" button when `_connState == disconnected`, and `_connectToFrame()` early-returns while state is `scanning`.

Net effect: if the frame isn't powered on/in range the first time, the user is stuck with no way to retry short of restarting the app.

### 4. Start/Stop Rotation button isn't gated by `_busy`

Every other BLE-triggering control (Show, Send Selected, the whole "Images" panel) is disabled while `_busy` is true — but the "Start Rotation"/"Stop Rotation" button at the bottom only checks `connected`. Since BLE state (`_pendingIndexCompleter`, chunked writes over `_rxChar`) is not designed for concurrent commands, tapping this while another operation is in flight can interleave writes on the wire or clobber the shared completer, causing hangs (mitigated only by a 5s timeout) or a response being routed to the wrong caller.

### 5. No mutex/queue around BLE commands in general

`_pendingIndexCompleter` and `_downloadBuilder`/`_pendingDownloadCompleter` are single, shared instance fields. Nothing prevents two logical commands (e.g. a brightness change via slider `onChangeEnd`, which has no busy-gate, firing while an image upload is mid-chunk-stream) from interleaving their `_sendChunked` writes. The protocol has no sequence numbers, so interleaved chunks from two commands would corrupt both.

### 6. `_deleteSelectedImages` has no rollback on partial failure

It downloads the images to keep, calls `_sendFormatCommand()` (wiping the device), then re-uploads the kept images one by one. If any re-upload fails partway through (BLE drop, timeout), the device has already been wiped, the app's `_sentImages`/`deviceIndex` state hasn't been updated yet (still points at pre-format indices), and there's no retry — leaving the app and device in an inconsistent, hard-to-recover state.

### 7. Deprecated/inconsistent `Color` API usage

`text_composer_page.dart` already uses the newer `c.toARGB32()`, but `main.dart` still compares colors with `c.value == active.value` (in both `FlashBannerPage` and `ImageEditorPage`'s swatch pickers) and reads `.red`/`.green`/`.blue` in `_showCustomColorPicker`. These are deprecated in current Flutter and inconsistent with the rest of the codebase — worth unifying.

### 8. Item delete ("×") button doesn't track scale/rotation

In `ImageEditorPage`, the small delete button is a sibling of `Transform.rotate`/`Transform.scale` inside the item's `Stack`, positioned at a fixed `(-8, -8)` offset from the *untransformed* layout bounds. For a scaled-up or rotated text/sticker item, the visible close button ends up detached from the item's actual on-screen corner.

## Potential improvements

- **Fix the format pipeline consistently** — route `ImageEditorPage` and `FlashBannerPage` output through the same `fitImageToPanel`/`encodeJpg` treatment `image_utils.dart` already provides for the "Pick Image" path, so every code path guarantees real, exactly-sized JPEG.
- **Add a simple command queue** for BLE writes (single in-flight request, FIFO) instead of relying on ad-hoc `_busy` flags scattered across individual buttons — this would fix bugs #4/#5 structurally rather than one button at a time.
- **Handle scan timeout explicitly** — listen for `FlutterBluePlus.isScanning` (or use the scan `timeout` completion) and reset to `disconnected` with a log message if nothing was found, so "Reconnect" reliably reappears.
- **Add per-item upload progress** for multi-image operations (`_sendSelectedToDevice`, `_deleteSelectedImages`, `_startRotation`) — right now it's just a single indeterminate `LinearProgressIndicator` with no indication of "3 of 12 sent."
- **Avoid full-storage reupload on delete** — the current delete flow is O(n) full re-upload for removing even one image because the firmware only exposes format-everything. If firmware could add a per-index delete/compact command, this whole flow (and its failure mode above) goes away.
- **Add basic write verification** — the BLE header includes a CRC16, but the JPEG/thumbnail payload itself is unverified; a payload CRC or length check on the device side (and a retry path on the app side) would make transfers more robust over flaky BLE links.
- **Surface disconnects more actively during long operations** — `_deleteSelectedImages`/`_startRotation` don't check `_rxChar == null` mid-loop after the first check, so a disconnect partway through a multi-image loop will throw from deep inside rather than failing gracefully with a clear message.
- **Gate photo-picker-dependent buttons by permission state** — `_ensurePermissions()` only requests Bluetooth/location; on newer Android, gallery access needs `READ_MEDIA_IMAGES`, which is left entirely to `image_picker`'s own prompt. Worth confirming/handling denial explicitly rather than silently failing.
- **Tests** — there's no test coverage at all for the BLE framing (`_crc16Ccitt`, `_buildHeader`, chunking) or the image geometry math (`fitImageToPanel`'s crop/rotate math), both of which are exactly the kind of "off-by-one and it renders sheared on hardware" code that benefits most from unit tests.