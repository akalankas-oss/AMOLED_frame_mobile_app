import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_picker/image_picker.dart';

import '../models/editor_item.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/editor_style_panel.dart';
import '../widgets/emoji_sticker_picker.dart';
import '../widgets/neumorphic_components.dart';

/// Unified "Create Image" design studio.
///
/// [initialImageBytes] is optional. When null the editor starts with a pure
/// solid-colour canvas. The user can add a photo later via the background panel.
class ImageEditorPage extends StatefulWidget {
  final Uint8List? initialImageBytes;
  const ImageEditorPage({super.key, this.initialImageBytes});

  @override
  State<ImageEditorPage> createState() => _ImageEditorPageState();
}

class _ImageEditorPageState extends State<ImageEditorPage>
    with SingleTickerProviderStateMixin {
  static const double _canvasWidth = 960;
  static const double _canvasHeight = 192;
  Size? _canvasSize;

  final GlobalKey _boundaryKey = GlobalKey();
  final GlobalKey _stackKey = GlobalKey();

  final List<EditorItem> _placedItems = [];
  int? _selectedIdx;
  bool _isSaving = false;

  Offset? _dragAnchor;
  double? _itemStartScale;
  double? _itemStartRotation;

  bool _repositioningBackground = false;
  Offset _bgOffset = Offset.zero;
  double _bgScale = 1.0;
  double _bgRotation = 0.0;
  double? _bgGestureStartScale;
  double? _bgGestureStartRotation;

  // Solid-colour background (always present; shown when no photo is loaded).
  Color _bgColor = Colors.black;

  // Optional photo layer on top of the solid colour.
  Uint8List? _bgImageBytes;

  // ── Background photo management ─────────────────────────────────────────

  Future<void> _pickBackgroundPhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final rawBytes = await file.readAsBytes();
    final bytes = await _downscaleForEditing(rawBytes);
    if (!mounted) return;
    setState(() {
      _bgImageBytes = bytes;
      _bgOffset = Offset.zero;
      _bgScale = 1.0;
      _bgRotation = 0.0;
    });
  }

  void _removeBackgroundPhoto() {
    setState(() {
      _bgImageBytes = null;
      _bgOffset = Offset.zero;
      _bgScale = 1.0;
      _bgRotation = 0.0;
    });
  }

  Future<Uint8List> _downscaleForEditing(Uint8List bytes,
      {int maxDimension = 1000}) async {
    final rawDecoded = image_lib.decodeImage(bytes);
    if (rawDecoded == null) return bytes;
    final oriented = image_lib.bakeOrientation(rawDecoded);
    if (oriented.width <= maxDimension && oriented.height <= maxDimension) {
      return Uint8List.fromList(image_lib.encodeJpg(oriented, quality: 92));
    }
    final scale = maxDimension /
        (oriented.width > oriented.height ? oriented.width : oriented.height);
    final resized = image_lib.copyResize(
      oriented,
      width: (oriented.width * scale).round(),
      height: (oriented.height * scale).round(),
    );
    return Uint8List.fromList(image_lib.encodeJpg(resized, quality: 92));
  }

  // ── Background reposition controls ──────────────────────────────────────

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
    setState(() => _bgRotation += radians);
  }

  void _stepZoomBackground(double delta) {
    setState(() => _bgScale = (_bgScale + delta).clamp(0.5, 6.0));
  }

  void _setBackgroundColor(Color color) {
    setState(() => _bgColor = color);
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    if (widget.initialImageBytes != null) {
      _bgImageBytes = widget.initialImageBytes;
    }
  }

  // ── Item management ──────────────────────────────────────────────────────

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
        backgroundColor: AppColors.surfaceElevated,
        title: const Text('Add Text',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Type your text...',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white30)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.cyanAccent)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.cyanAccent),
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                _addEmojiItem(controller.text.trim());
              }
              Navigator.pop(context);
            },
            child: const Text('Add',
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── Export ───────────────────────────────────────────────────────────────

  Future<void> _exportCanvas() async {
    try {
      setState(() {
        _selectedIdx = null;
        _repositioningBackground = false;
        _isSaving = true;
      });

      await Future.delayed(const Duration(milliseconds: 300));

      final RenderRepaintBoundary boundary =
          _boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;

      final double renderedLogicalWidth = boundary.size.width;
      final double neededPixelRatio = _canvasWidth / renderedLogicalWidth;

      final ui.Image captured =
          await boundary.toImage(pixelRatio: neededPixelRatio);

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

        final rotated = image_lib.copyRotate(imgLib, angle: 90);

        final int nativeW = _canvasHeight.round();
        final int nativeH = _canvasWidth.round();
        final image_lib.Image finalImg =
            (rotated.width == nativeW && rotated.height == nativeH)
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
        setState(() => _isSaving = false);
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

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final EditorItem? activeItem =
        (_selectedIdx != null && _selectedIdx! < _placedItems.length)
            ? _placedItems[_selectedIdx!]
            : null;

    final bool bgGesturesEnabled = _repositioningBackground && !_isSaving;
    final bool hasPhoto = _bgImageBytes != null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Create Image',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: NeumorphicIconButton(
            icon: const Icon(Icons.close, size: 20, color: Colors.white),
            onPressed: () => Navigator.maybePop(context),
            borderRadius: 24,
            padding: EdgeInsets.zero,
          ),
        ),
        actions: [
          if (!_isSaving) ...[
            // Reposition toggle (only visible when a photo is loaded)
            if (hasPhoto)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                child: NeumorphicIconButton(
                  icon: Icon(
                    _repositioningBackground
                        ? Icons.check_circle
                        : Icons.crop_rotate,
                    color: _repositioningBackground
                        ? Colors.greenAccent
                        : Colors.cyanAccent,
                    size: 20,
                  ),
                  isActive: _repositioningBackground,
                  onPressed: _toggleReposition,
                  borderRadius: 24,
                  padding: const EdgeInsets.all(8.0),
                ),
              ),
            // Add Photo
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
              child: NeumorphicIconButton(
                icon: Icon(
                  hasPhoto ? Icons.image : Icons.add_photo_alternate_outlined,
                  color: AppColors.cyanAccent,
                  size: 20,
                ),
                onPressed: _pickBackgroundPhoto,
                borderRadius: 24,
                padding: const EdgeInsets.all(8.0),
              ),
            ),
            if (hasPhoto)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                child: NeumorphicIconButton(
                  icon: const Icon(Icons.hide_image_outlined,
                      color: AppColors.pinkAccent, size: 20),
                  onPressed: _removeBackgroundPhoto,
                  borderRadius: 24,
                  padding: const EdgeInsets.all(8.0),
                ),
              ),
            // Add Text
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
              child: NeumorphicIconButton(
                icon: const Icon(Icons.text_fields,
                    color: Colors.amberAccent, size: 20),
                onPressed: _openCustomTextInput,
                borderRadius: 24,
                padding: const EdgeInsets.all(8.0),
              ),
            ),
            // Save
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
              child: NeumorphicButton(
                borderRadius: 24,
                gradient: AppColors.primaryGradient,
                icon: const Icon(Icons.check, size: 18, color: Colors.white),
                label: 'Save',
                textColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                onPressed: _exportCanvas,
              ),
            ),
          ]
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // ── Canvas Area ──────────────────────────────────────────────
              Expanded(
                flex: 4,
                child: Center(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: Colors.white10, width: 1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: AspectRatio(
                      aspectRatio: _canvasWidth / _canvasHeight,
                      child: RepaintBoundary(
                        key: _boundaryKey,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            _canvasSize = constraints.biggest;
                            return Stack(
                              key: _stackKey,
                              clipBehavior: Clip.hardEdge,
                              children: [
                                // Solid colour fill (always present)
                                Positioned.fill(
                                  child: Container(color: _bgColor),
                                ),

                                // Optional photo layer
                                if (hasPhoto)
                                  Positioned.fill(
                                    child: ClipRect(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onScaleStart: !bgGesturesEnabled
                                            ? null
                                            : (details) {
                                                _bgGestureStartScale = _bgScale;
                                                _bgGestureStartRotation =
                                                    _bgRotation;
                                              },
                                        onScaleUpdate: !bgGesturesEnabled
                                            ? null
                                            : (details) {
                                                setState(() {
                                                  _bgScale =
                                                      (_bgGestureStartScale! *
                                                              details.scale)
                                                          .clamp(0.5, 6.0);
                                                  _bgOffset +=
                                                      details.focalPointDelta;
                                                  if (details.pointerCount >
                                                      1) {
                                                    _bgRotation =
                                                        _bgGestureStartRotation! +
                                                            details.rotation;
                                                  }
                                                });
                                              },
                                        onTap: bgGesturesEnabled
                                            ? null
                                            : () {
                                                if (!_isSaving) {
                                                  setState(
                                                      () => _selectedIdx = null);
                                                }
                                              },
                                        child: Transform.translate(
                                          offset: _bgOffset,
                                          child: Transform.rotate(
                                            angle: _bgRotation,
                                            child: Transform.scale(
                                              scale: _bgScale,
                                              child: Image.memory(
                                                _bgImageBytes!,
                                                fit: BoxFit.contain,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                // Tap-to-deselect on solid-colour canvas
                                if (!hasPhoto)
                                  Positioned.fill(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        if (!_isSaving) {
                                          setState(() => _selectedIdx = null);
                                        }
                                      },
                                    ),
                                  ),

                                // Placed items (text, stickers, emojis)
                                ...List.generate(_placedItems.length, (index) {
                                  final item = _placedItems[index];
                                  final isFocused = _selectedIdx == index;
                                  final itemGesturesEnabled =
                                      !_isSaving && !_repositioningBackground;

                                  return Positioned(
                                    key: ValueKey('item_${item.id}'),
                                    left: item.offset.dx,
                                    top: item.offset.dy,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: !itemGesturesEnabled
                                          ? null
                                          : () {
                                              setState(
                                                  () => _selectedIdx = index);
                                            },
                                      onScaleStart: !itemGesturesEnabled
                                          ? null
                                          : (details) {
                                              final box = _stackKey
                                                      .currentContext!
                                                      .findRenderObject()
                                                  as RenderBox;
                                              final localPos = box
                                                  .globalToLocal(
                                                      details.focalPoint);
                                              setState(() {
                                                _selectedIdx = index;
                                                _dragAnchor =
                                                    localPos - item.offset;
                                                _itemStartScale = item.scale;
                                                _itemStartRotation =
                                                    item.rotation;
                                              });
                                            },
                                      onScaleUpdate: !itemGesturesEnabled
                                          ? null
                                          : (details) {
                                              final box = _stackKey
                                                      .currentContext!
                                                      .findRenderObject()
                                                  as RenderBox;
                                              final localPos = box
                                                  .globalToLocal(
                                                      details.focalPoint);
                                              final anchor =
                                                  _dragAnchor ?? Offset.zero;
                                              setState(() {
                                                final newOffset =
                                                    localPos - anchor;
                                                item.offset = Offset(
                                                  newOffset.dx.clamp(-40.0,
                                                      constraints.maxWidth - 20),
                                                  newOffset.dy.clamp(-40.0,
                                                      constraints.maxHeight - 20),
                                                );
                                                if (details.pointerCount > 1) {
                                                  item.scale =
                                                      (_itemStartScale! *
                                                              details.scale)
                                                          .clamp(0.3, 4.0);
                                                  item.rotation =
                                                      _itemStartRotation! +
                                                          details.rotation;
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
                                                padding:
                                                    const EdgeInsets.all(12),
                                                constraints: BoxConstraints(
                                                  maxWidth: item.isSticker
                                                      ? double.infinity
                                                      : _canvasWidth - 40,
                                                ),
                                                decoration: BoxDecoration(
                                                  border: Border.all(
                                                    color: isFocused
                                                        ? Colors.cyanAccent
                                                        : Colors.transparent,
                                                    width: 2,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: item.isSticker
                                                    ? Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .all(8),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: item.color,
                                                          shape:
                                                              BoxShape.circle,
                                                        ),
                                                        child: Icon(
                                                            item.stickerIcon,
                                                            size: 36,
                                                            color:
                                                                Colors.white),
                                                      )
                                                    : Text(
                                                        item.content,
                                                        textAlign:
                                                            TextAlign.center,
                                                        softWrap: true,
                                                        style: TextStyle(
                                                          fontSize: item
                                                              .fontSize,
                                                          fontFamily: item
                                                              .fontFamily,
                                                          color: item.color,
                                                          fontWeight: item.bold
                                                              ? FontWeight.bold
                                                              : FontWeight
                                                                  .normal,
                                                          fontStyle: item.italic
                                                              ? FontStyle.italic
                                                              : FontStyle
                                                                  .normal,
                                                          letterSpacing: item
                                                              .letterSpacing,
                                                          decoration:
                                                              TextDecoration
                                                                  .combine([
                                                            if (item.underline)
                                                              TextDecoration
                                                                  .underline,
                                                            if (item
                                                                .strikethrough)
                                                              TextDecoration
                                                                  .lineThrough,
                                                          ]),
                                                        ),
                                                      ),
                                              ),
                                              if (isFocused && !_isSaving)
                                                Positioned(
                                                  right: 0,
                                                  top: 0,
                                                  child: GestureDetector(
                                                    onTap: _removeActiveItem,
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              4),
                                                      decoration:
                                                          const BoxDecoration(
                                                        color:
                                                            Colors.pinkAccent,
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: const Icon(
                                                          Icons.close,
                                                          size: 16,
                                                          color: Colors.white),
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
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ── Bottom Panel ─────────────────────────────────────────────
              Expanded(
                flex: 3,
                child: Opacity(
                  opacity: _isSaving ? 0.0 : 1.0,
                  child: IgnorePointer(
                    ignoring: _isSaving,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16.0, vertical: 8.0),
                      child: NeumorphicCard(
                        borderRadius: 24,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Item style panel (visible when an item is selected)
                              if (activeItem != null) ...[
                                EditorStylePanel(
                                  activeItem: activeItem,
                                  onChanged: () => setState(() {}),
                                  onDelete: _removeActiveItem,
                                ),
                              ],

                              // Background colour row
                              Row(
                                children: [
                                  const Text('Background:',
                                      style: TextStyle(
                                          color: Colors.white70, fontSize: 12)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SizedBox(
                                      height: 30,
                                      child: ListView.builder(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: ColorSwatchPicker
                                            .colorPalette.length,
                                        itemBuilder: (ctx, idx) {
                                          final c = ColorSwatchPicker
                                              .colorPalette[idx];
                                          final isSelected = c == _bgColor;
                                          return GestureDetector(
                                            onTap: () =>
                                                _setBackgroundColor(c),
                                            child: Container(
                                              width: 26,
                                              height: 26,
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 3),
                                              decoration: BoxDecoration(
                                                color: c,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: isSelected
                                                      ? Colors.cyanAccent
                                                      : Colors.white24,
                                                  width: isSelected ? 2 : 1,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  // Custom colour picker
                                  GestureDetector(
                                    onTap: () =>
                                        ColorSwatchPicker.showCustomColorPicker(
                                            context,
                                            _bgColor,
                                            _setBackgroundColor),
                                    child: Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                            color: Colors.white24, width: 1.5),
                                        gradient: const SweepGradient(
                                          colors: [
                                            Colors.red,
                                            Colors.yellow,
                                            Colors.green,
                                            Colors.cyan,
                                            Colors.blue,
                                            Colors.purple,
                                            Colors.red
                                          ],
                                        ),
                                      ),
                                      child: const Icon(Icons.add,
                                          size: 16, color: Colors.white),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),

                              // Sticker / emoji picker
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
              ),
            ],
          ),

          // ── Floating Reposition Panel ────────────────────────────────────
          if (_repositioningBackground)
            Positioned(
              bottom: MediaQuery.of(context).size.height * 0.4,
              left: 16,
              right: 16,
              child: RepaintBoundary(
                child: NeumorphicCard(
                  borderRadius: 24,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Background Tools',
                            style: TextStyle(
                                color: Colors.cyanAccent,
                                fontWeight: FontWeight.bold),
                          ),
                          TextButton.icon(
                            onPressed: _resetBackgroundTransform,
                            icon: const Icon(Icons.restore,
                                color: Colors.pinkAccent, size: 16),
                            label: const Text('Reset',
                                style: TextStyle(color: Colors.pinkAccent)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          NeumorphicIconButton(
                            icon: const Icon(Icons.rotate_left,
                                color: Colors.white),
                            onPressed: () =>
                                _quickRotateBackground(-math.pi / 2),
                            borderRadius: 24,
                            padding: const EdgeInsets.all(8),
                          ),
                          NeumorphicIconButton(
                            icon:
                                const Icon(Icons.zoom_out, color: Colors.white),
                            onPressed: () => _stepZoomBackground(-0.1),
                            borderRadius: 24,
                            padding: const EdgeInsets.all(8),
                          ),
                          NeumorphicIconButton(
                            icon:
                                const Icon(Icons.zoom_in, color: Colors.white),
                            onPressed: () => _stepZoomBackground(0.1),
                            borderRadius: 24,
                            padding: const EdgeInsets.all(8),
                          ),
                          NeumorphicIconButton(
                            icon: const Icon(Icons.rotate_right,
                                color: Colors.white),
                            onPressed: () =>
                                _quickRotateBackground(math.pi / 2),
                            borderRadius: 24,
                            padding: const EdgeInsets.all(8),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ),

          // ── Saving overlay ───────────────────────────────────────────────
          if (_isSaving)
            Container(
              color: Colors.black54,
              child: const Center(
                child:
                    CircularProgressIndicator(color: AppColors.cyanAccent),
              ),
            ),
        ],
      ),
    );
  }
}
