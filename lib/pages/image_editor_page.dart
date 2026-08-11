import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as image_lib;

import '../models/editor_item.dart';
import '../utils/image_utils.dart';
import 'text_composer_page.dart';

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

  // ----- Android-keyboard style emoji/sticker picker -----
  late final TabController _tabController;

  static const Map<String, List<String>> _emojiCategories = {
    'Smileys': [
      '😀', '😁', '😂', '🤣', '😊', '😍', '😘', '😜', '🤪', '😎',
      '🥳', '😇', '🙃', '🤩', '😢', '😭', '😡', '🤔', '😴', '🤗',
      '😏', '😅', '🥰', '😋', '🤤', '😱', '🥺', '😤', '🤯', '🥶',
    ],
    'Hands & Hearts': [
      '👍', '👎', '👏', '🙌', '🤝', '💪', '✌️', '🤞', '👌', '🤙',
      '👋', '🤟', '🫶', '✋', '🖐️', '🙏',
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💔', '💯',
      '💕', '💖', '💗', '💞',
    ],
    'Nature': [
      '🌸', '🌺', '🌻', '🌈', '☀️', '🌙', '⚡', '❄️', '🍀', '🌊',
      '🐶', '🐱', '🐼', '🦄', '🐝', '🦋', '🐾', '🐦', '🐟', '🦁',
      '🌵', '🌴', '🍁', '🌹', '⭐', '🌟', '💫', '☁️',
    ],
    'Food': [
      '🍕', '🍔', '🍰', '🎂', '☕', '🍦', '🍩', '🍓', '🍉', '🥑',
      '🍎', '🍇', '🍒', '🍫', '🍿', '🌮', '🍟', '🍪',
    ],
    'Objects': [
      '📷', '🎮', '🎵', '🎨', '📚', '✈️', '🚀', '⚽', '🎯', '💡',
      '🎉', '🎊', '🎈', '🎁', '🏆', '🔥', '✨', '💰', '⏰', '📱',
    ],
  };

  static const List<IconData> _stickerIcons = [
    Icons.star, Icons.favorite, Icons.brightness_5, Icons.celebration,
    Icons.pets, Icons.wb_sunny, Icons.auto_awesome, Icons.music_note,
    Icons.local_pizza, Icons.cake, Icons.videogame_asset, Icons.rocket_launch,
    Icons.emoji_emotions, Icons.mood, Icons.thumb_up, Icons.diamond,
    Icons.local_fire_department, Icons.bolt, Icons.anchor, Icons.spa,
  ];

  static const List<Color> _colorPalette = [
    Colors.white, Colors.black, Colors.grey,
    Colors.red, Color(0xFFB71C1C), Color(0xFFFF8A80),
    Colors.orange, Color(0xFFE65100), Color(0xFFFFCC80),
    Colors.amber, Color(0xFFFFA000),
    Colors.yellow, Color(0xFFF9A825),
    Colors.lime, Color(0xFF9E9D24),
    Colors.green, Color(0xFF1B5E20), Color(0xFFA5D6A7),
    Colors.teal, Color(0xFF004D40),
    Colors.cyan, Color(0xFF006064),
    Colors.lightBlue, Colors.blue, Color(0xFF0D47A1), Color(0xFF90CAF9),
    Colors.indigo, Color(0xFF1A237E),
    Colors.purple, Color(0xFF4A148C), Color(0xFFCE93D8),
    Colors.deepPurple,
    Colors.pink, Color(0xFF880E4F), Color(0xFFF8BBD0),
    Colors.brown, Color(0xFF3E2723),
    Colors.blueGrey, Color(0xFFECEFF1),
  ];

  Future<void> _showCustomColorPicker(Color initial, ValueChanged<Color> onPicked) async {
    final int argb = initial.toARGB32();
    int r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final preview = Color.fromARGB(255, r, g, b);
          Widget slider(String label, int value, ValueChanged<int> onChanged) {
            return Row(
              children: [
                SizedBox(width: 16, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12))),
                Expanded(
                  child: Slider(
                    value: value.toDouble(),
                    min: 0,
                    max: 255,
                    onChanged: (v) => setDialogState(() => onChanged(v.round())),
                  ),
                ),
                SizedBox(width: 32, child: Text('$value', style: const TextStyle(color: Colors.white70, fontSize: 12))),
              ],
            );
          }
          return AlertDialog(
            backgroundColor: Colors.grey.shade900,
            title: const Text('Custom Color', style: TextStyle(color: Colors.white)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  height: 50,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: preview,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                ),
                slider('R', r, (v) => r = v),
                slider('G', g, (v) => g = v),
                slider('B', b, (v) => b = v),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  onPicked(Color.fromARGB(255, r, g, b));
                  Navigator.pop(context);
                },
                child: const Text('Use this color'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _emojiCategories.length + 1, vsync: this);
    _autoRotateIfPortrait();
  }

  // A portrait-oriented photo (taller than wide) shown with BoxFit.contain
  // inside this landscape-shaped canvas would be constrained by the
  // canvas's short dimension, appearing as a small strip in the middle.
  // Rotating it 90° up front makes it landscape-shaped, filling the frame
  // properly. The existing rotate controls still let you undo/adjust this.
  Future<void> _autoRotateIfPortrait() async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(widget.imageBytes, completer.complete);
    final img = await completer.future;
    if (mounted && img.height > img.width) {
      setState(() => _bgRotation = math.pi / 2);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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

  void _setActiveItemColor(Color color) {
    if (_selectedIdx != null && _selectedIdx! < _placedItems.length) {
      setState(() {
        _placedItems[_selectedIdx!].color = color;
      });
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

      // Capture at exactly 960×192 physical pixels.
      final ui.Image captured = await boundary.toImage(pixelRatio: neededPixelRatio);

      final ByteData? rawData =
          await captured.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rawData != null) {
        final imgLib = image_lib.Image.fromBytes(
          width: captured.width,   // 960
          height: captured.height, // 192
          bytes: rawData.buffer,
          format: image_lib.Format.uint8,
          numChannels: 4,
        );
        // Encode as real JPEG — the firmware memcpys directly into the
        // 960×192 framebuffer, so pixels must be in landscape order.
        final Uint8List jpegBytes =
            Uint8List.fromList(image_lib.encodeJpg(imgLib, quality: 90));
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

  Widget _buildColorSwatches(Color activeColor) {
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _colorPalette.length,
        itemBuilder: (ctx, idx) {
          final c = _colorPalette[idx];
          final isSelected = c == activeColor;
          return GestureDetector(
            onTap: () => _setActiveItemColor(c),
            child: Container(
              width: 30,
              height: 30,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? Colors.cyanAccent : Colors.white24,
                  width: isSelected ? 3 : 1,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _styleToggleButton({required IconData icon, required bool active, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: active ? Colors.amberAccent.withOpacity(0.25) : Colors.transparent,
          border: Border.all(color: active ? Colors.amberAccent : Colors.white24),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 20, color: active ? Colors.amberAccent : Colors.white70),
      ),
    );
  }

  Widget _fontChip(String label, String? family, String? currentFamily) {
    final selected = family == currentFamily;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(fontFamily: family, fontSize: 12)),
        selected: selected,
        onSelected: (_) => setState(() {
          if (_selectedIdx != null) _placedItems[_selectedIdx!].fontFamily = family;
        }),
        selectedColor: Colors.amberAccent,
        backgroundColor: Colors.white10,
        labelStyle: TextStyle(color: selected ? Colors.black : Colors.white70),
      ),
    );
  }

  Widget _buildEmojiGrid(List<String> emojis) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: emojis.length,
      itemBuilder: (ctx, idx) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _addEmojiItem(emojis[idx]),
        child: Center(child: Text(emojis[idx], style: const TextStyle(fontSize: 24))),
      ),
    );
  }

  Widget _buildStickerGrid() {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: _stickerIcons.length,
      itemBuilder: (ctx, idx) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _addStickerItem(_stickerIcons[idx]),
        child: Center(child: Icon(_stickerIcons[idx], color: Colors.amberAccent, size: 22)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    EditorItem? activeItem = (_selectedIdx != null && _selectedIdx! < _placedItems.length)
        ? _placedItems[_selectedIdx!]
        : null;

    final categoryNames = _emojiCategories.keys.toList();
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
                            itemCount: _colorPalette.length,
                            itemBuilder: (ctx, idx) {
                              final c = _colorPalette[idx];
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
                        onTap: () => _showCustomColorPicker(_bgColor, _setBackgroundColor),
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
                                                child: RotatedBox(
                                                  quarterTurns: 1,
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
                                              ),
                                          // Small delete button pinned to the item's
                                          // top-right corner, visible only while
                                          // this item is selected.
                                          if (isFocused && itemGesturesEnabled)
                                            Positioned(
                                              top: -8,
                                              right: -8,
                                              child: GestureDetector(
                                                onTap: () => _removeItemAt(index),
                                                child: Container(
                                                  width: 20,
                                                  height: 20,
                                                  decoration: const BoxDecoration(
                                                    color: Colors.red,
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: const Icon(Icons.close, size: 12, color: Colors.white),
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
                          Row(
                            children: [
                              const Icon(Icons.photo_size_select_large_outlined, size: 18, color: Colors.white),
                              Expanded(
                                child: Slider(
                                  value: activeItem.scale,
                                  min: 0.3,
                                  max: 4.0,
                                  onChanged: (v) => setState(() => activeItem!.scale = v),
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: Text(
                                  '${(activeItem.scale * 100).round()}%',
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.rotate_right, size: 18, color: Colors.white),
                              Expanded(
                                child: Slider(
                                  value: ((activeItem.rotation * 180 / math.pi) % 360 + 360) % 360,
                                  min: 0,
                                  max: 360,
                                  onChanged: (v) => setState(() => activeItem!.rotation = v * math.pi / 180),
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: Text(
                                  '${(((activeItem.rotation * 180 / math.pi) % 360 + 360) % 360).round()}°',
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                          if (!activeItem.isSticker) ...[
                            Row(
                              children: [
                                const Icon(Icons.format_size, size: 18, color: Colors.white),
                                Expanded(
                                  child: Slider(
                                    value: activeItem.fontSize,
                                    min: 12,
                                    max: 90,
                                    onChanged: (v) => setState(() => activeItem!.fontSize = v),
                                  ),
                                ),
                                SizedBox(
                                  width: 30,
                                  child: Text(
                                    activeItem.fontSize.round().toString(),
                                    style: const TextStyle(color: Colors.white, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                const Icon(Icons.space_bar, size: 18, color: Colors.white),
                                Expanded(
                                  child: Slider(
                                    value: activeItem.letterSpacing,
                                    min: -2,
                                    max: 20,
                                    onChanged: (v) => setState(() => activeItem!.letterSpacing = v),
                                  ),
                                ),
                                SizedBox(
                                  width: 30,
                                  child: Text(
                                    activeItem.letterSpacing.round().toString(),
                                    style: const TextStyle(color: Colors.white, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _styleToggleButton(
                                  icon: Icons.format_bold,
                                  active: activeItem.bold,
                                  onTap: () => setState(() => activeItem!.bold = !activeItem.bold),
                                ),
                                _styleToggleButton(
                                  icon: Icons.format_italic,
                                  active: activeItem.italic,
                                  onTap: () => setState(() => activeItem!.italic = !activeItem.italic),
                                ),
                                _styleToggleButton(
                                  icon: Icons.format_underline,
                                  active: activeItem.underline,
                                  onTap: () => setState(() => activeItem!.underline = !activeItem.underline),
                                ),
                                _styleToggleButton(
                                  icon: Icons.format_strikethrough,
                                  active: activeItem.strikethrough,
                                  onTap: () => setState(() => activeItem!.strikethrough = !activeItem.strikethrough),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              height: 34,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  _fontChip('Default', null, activeItem.fontFamily),
                                  _fontChip('Serif', 'serif', activeItem.fontFamily),
                                  _fontChip('Monospace', 'monospace', activeItem.fontFamily),
                                  _fontChip('Condensed', 'sans-serif-condensed', activeItem.fontFamily),
                                  _fontChip('Cursive', 'cursive', activeItem.fontFamily),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text('COLOR', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1)),
                          ),
                          const SizedBox(height: 4),
                          _buildColorSwatches(activeItem.color),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red.shade800,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _removeActiveItem,
                              icon: const Icon(Icons.delete),
                              label: const Text('Delete Selected Item'),
                            ),
                          ),
                          const Divider(color: Colors.white24),
                        ],
                        // ----- Android-keyboard style picker -----
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: [
                              TabBar(
                                controller: _tabController,
                                isScrollable: true,
                                labelColor: Colors.amberAccent,
                                unselectedLabelColor: Colors.white54,
                                indicatorColor: Colors.amberAccent,
                                tabs: [
                                  ...categoryNames.map((name) => Tab(text: name)),
                                  const Tab(icon: Icon(Icons.emoji_emotions_outlined), text: 'Stickers'),
                                ],
                              ),
                              SizedBox(
                                height: 190,
                                child: TabBarView(
                                  controller: _tabController,
                                  children: [
                                    ...categoryNames.map((name) => _buildEmojiGrid(_emojiCategories[name]!)),
                                    _buildStickerGrid(),
                                  ],
                                ),
                              ),
                            ],
                          ),
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