import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as image_lib;

import '../models/editor_item.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/editor_style_panel.dart';
import '../widgets/emoji_sticker_picker.dart';

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



  @override
  void initState() {
    super.initState();
    _autoRotateIfPortrait();
  }

  // A portrait-oriented photo (taller than wide) shown with BoxFit.contain
  // inside this landscape-shaped canvas would be constrained by the
  // canvas's short dimension, appearing as a small strip in the middle.
  // Rotating it 90° up front makes it landscape-shaped, filling the frame
  // properly. The existing rotate controls still let you undo/adjust this.
  Future<void> _autoRotateIfPortrait() async {
    // Intentionally left empty. User requested portrait images 
    // maintain their original orientation.
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

      // Capture at approximately 960×192 physical pixels.
      // NOTE: floating-point pixelRatio and subpixel rendering mean the actual
      // captured dimensions can be off by ±1px (e.g. 191×959 or 193×961).
      final ui.Image captured = await boundary.toImage(pixelRatio: neededPixelRatio);

      final ByteData? rawData =
          await captured.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rawData != null) {
        final imgLib = image_lib.Image.fromBytes(
          width: captured.width,
          height: captured.height,
          bytes: rawData.buffer,
          format: image_lib.Format.uint8,
          numChannels: 4,
        );

        // Rotate 90° CW into native panel orientation (192×960). The firmware
        // memcpys decoded pixels directly into a 192×960 framebuffer.
        final rotated = image_lib.copyRotate(imgLib, angle: 90);

        // STRICT DIMENSION GUARD: floating-point pixelRatio rounding means
        // 'rotated' could be 191×959 or 193×961 rather than exactly 192×960.
        // The ESP32-P4 firmware does a direct memcpy into a fixed 192×960
        // framebuffer — any off-by-one causes image shearing, line corruption,
        // or out-of-bounds memory writes. Force exact dimensions here.
        final int nativeW = _canvasHeight.round(); // 192  (after 90° rotation, width == canvas height)
        final int nativeH = _canvasWidth.round();  // 960  (after 90° rotation, height == canvas width)
        final image_lib.Image finalImg = (rotated.width == nativeW && rotated.height == nativeH)
            ? rotated
            : image_lib.copyResize(
                rotated,
                width: nativeW,
                height: nativeH,
                interpolation: image_lib.Interpolation.linear,
              );

        final Uint8List jpegBytes =
            Uint8List.fromList(image_lib.encodeJpg(finalImg, quality: 90));
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



  @override
  Widget build(BuildContext context) {
    EditorItem? activeItem = (_selectedIdx != null && _selectedIdx! < _placedItems.length)
        ? _placedItems[_selectedIdx!]
        : null;

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
                            itemCount: ColorSwatchPicker.colorPalette.length,
                            itemBuilder: (ctx, idx) {
                              final c = ColorSwatchPicker.colorPalette[idx];
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
                        onTap: () => ColorSwatchPicker.showCustomColorPicker(context, _bgColor, _setBackgroundColor),
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
                          EditorStylePanel(
                            activeItem: activeItem,
                            onChanged: () => setState(() {}),
                            onDelete: _removeActiveItem,
                          ),
                        ],
                        // ----- Android-keyboard style picker -----
                        EmojiStickerPicker(
                          onEmojiPicked: _addEmojiItem,
                          onStickerPicked: _addStickerItem,
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