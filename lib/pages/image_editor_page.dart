import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_picker/image_picker.dart';

import '../models/editor_item.dart';
import '../pages/camera_capture_page.dart';
import '../widgets/color_swatch_picker.dart';
import '../widgets/editor_style_panel.dart';
import '../widgets/neumorphic_components.dart';

// ── Enums ─────────────────────────────────────────────────────────────────────

enum ActiveSubSection { none, icon, stickers, border, bgReposition }

// ── Border Options ─────────────────────────────────────────────────────────────

enum BorderType { none, single, double, triple }



// ── Preset Icons & Stickers ───────────────────────────────────────────────────

const List<String> _emojiPresets = [
  '⭐', '❤️', '🔥', '😊', '👍', '⚡',
  '🎵', '🔔', '🚀', '🏆', '💡', '🛡️',
  '😎', '🎉', '💎', '🌟', '🦋', '🌈',
  '🍀', '🎯', '⚽', '🎮', '🌙', '☀️',
];

const List<String> _stickerPresets = [
  '★ STAR ★', '❯❯ HOT', 'NEW ✦', '◈ VIP ◈',
  '» LIVE «', '✦ COOL ✦', '◉ PRO', '⊛ EPIC',
  '▶ GO', '✔ WIN', '✗ FAIL', '⌘ CMD',
  '⚑ FLAG', '♛ KING', '⌂ HOME', '☎ CALL',
];

// ── Main Widget ───────────────────────────────────────────────────────────────

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

  // Solid-colour background (always present; shown when no photo is loaded)
  Color _bgColor = Colors.black;

  // Optional photo layer on top of the solid colour
  Uint8List? _bgImageBytes;

  // Active sub-section in the dynamic area
  ActiveSubSection _activeSubSection = ActiveSubSection.none;

  // Selected border style
  BorderType _selectedBorderType = BorderType.none;
  Color _selectedBorderColor = Colors.white;

  // Panel collapse state
  bool _editPanelCollapsed = false;

  // ── Undo Stack ────────────────────────────────────────────────────────────

  static const int _maxUndoSteps = 30;
  final List<_EditorSnapshot> _undoStack = [];

  void _pushUndo() {
    _undoStack.add(_EditorSnapshot(
      items: _placedItems.map((e) => e.clone()).toList(),
      bgColor: _bgColor,
      bgImageBytes: _bgImageBytes,
      bgOffset: _bgOffset,
      bgScale: _bgScale,
      bgRotation: _bgRotation,
      borderType: _selectedBorderType,
      borderColor: _selectedBorderColor,
    ));
    if (_undoStack.length > _maxUndoSteps) _undoStack.removeAt(0);
  }

  void _applyUndo() {
    if (_undoStack.isEmpty) return;
    final snap = _undoStack.removeLast();
    setState(() {
      _placedItems
        ..clear()
        ..addAll(snap.items);
      _bgColor = snap.bgColor;
      _bgImageBytes = snap.bgImageBytes;
      _bgOffset = snap.bgOffset;
      _bgScale = snap.bgScale;
      _bgRotation = snap.bgRotation;
      _selectedBorderType = snap.borderType;
      _selectedBorderColor = snap.borderColor;
      _selectedIdx = null;
      _repositioningBackground = false;
      _activeSubSection = ActiveSubSection.none;
    });
  }

  // ── Background photo management ─────────────────────────────────────────

  Future<void> _pickBackgroundPhoto() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final rawBytes = await file.readAsBytes();
    final bytes = await _downscaleForEditing(rawBytes);
    if (!mounted) return;
    _pushUndo();
    setState(() {
      _bgImageBytes = bytes;
      _bgOffset = Offset.zero;
      _bgScale = 1.0;
      _bgRotation = 0.0;
      _activeSubSection = ActiveSubSection.none;
    });
  }

  void _removeBackgroundPhoto() {
    _pushUndo();
    setState(() {
      _bgImageBytes = null;
      _bgOffset = Offset.zero;
      _bgScale = 1.0;
      _bgRotation = 0.0;
      _repositioningBackground = false;
      if (_activeSubSection == ActiveSubSection.bgReposition) {
        _activeSubSection = ActiveSubSection.none;
      }
    });
  }

  /// Opens the dedicated [CameraCapturePage] and sets the returned 5:1 image
  /// as the editor background.
  Future<void> _openCamera() async {
    final result = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const CameraCapturePage()),
    );
    if (result == null || !mounted) return;
    _pushUndo();
    setState(() {
      _bgImageBytes = result;
      _bgOffset = Offset.zero;
      _bgScale = 1.0;
      _bgRotation = 0.0;
      _activeSubSection = ActiveSubSection.none;
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
      if (_repositioningBackground) {
        _selectedIdx = null;
        _activeSubSection = ActiveSubSection.bgReposition;
      } else {
        _activeSubSection = ActiveSubSection.none;
      }
    });
  }

  void _resetBackgroundTransform() {
    _pushUndo();
    setState(() {
      _bgOffset = Offset.zero;
      _bgScale = 1.0;
      _bgRotation = 0.0;
    });
  }

  void _quickRotateBackground(double radians) {
    _pushUndo();
    setState(() => _bgRotation += radians);
  }

  void _stepZoomBackground(double delta) {
    _pushUndo();
    setState(() => _bgScale = (_bgScale + delta).clamp(0.5, 6.0));
  }

  void _setBackgroundColor(Color color) {
    _pushUndo();
    setState(() => _bgColor = color);
  }

  // ── Canvas border ─────────────────────────────────────────────────────────

  void _setCanvasBorderType(BorderType type) {
    if (_selectedBorderType == type) return;
    _pushUndo();
    setState(() => _selectedBorderType = type);
  }

  void _setCanvasBorderColor(Color color) {
    if (_selectedBorderColor == color) return;
    _pushUndo();
    setState(() => _selectedBorderColor = color);
  }

  // ── Sub-section toggle ────────────────────────────────────────────────────

  void _toggleSubSection(ActiveSubSection section) {
    setState(() {
      if (_activeSubSection == section) {
        _activeSubSection = ActiveSubSection.none;
        if (section == ActiveSubSection.bgReposition) {
          _repositioningBackground = false;
        }
      } else {
        _activeSubSection = section;
        _selectedIdx = null;
        _editPanelCollapsed = false;
        if (section != ActiveSubSection.bgReposition) {
          _repositioningBackground = false;
        }
      }
    });
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    if (widget.initialImageBytes != null) {
      _bgImageBytes = widget.initialImageBytes;
    }
  }

  // ── Item management ───────────────────────────────────────────────────────

  void _addTextItem(String text) {
    final uniqueId = DateTime.now().microsecondsSinceEpoch.toString();
    final size = _canvasSize ?? const Size(_canvasWidth, _canvasHeight);
    _pushUndo();
    setState(() {
      _placedItems.add(EditorItem(
        id: uniqueId,
        content: text,
        offset: Offset(size.width / 2 - 30, size.height / 2 - 20),
      ));
      _selectedIdx = _placedItems.length - 1;
      _activeSubSection = ActiveSubSection.none;
      _editPanelCollapsed = false;
    });
  }

  void _addIconItem(String emoji) {
    final uniqueId = DateTime.now().microsecondsSinceEpoch.toString();
    final size = _canvasSize ?? const Size(_canvasWidth, _canvasHeight);
    _pushUndo();
    setState(() {
      _placedItems.add(EditorItem(
        id: uniqueId,
        content: emoji,
        offset: Offset(size.width / 2 - 20, size.height / 2 - 20),
        fontSize: 40,
      ));
      _selectedIdx = _placedItems.length - 1;
      _activeSubSection = ActiveSubSection.none;
      _editPanelCollapsed = false;
    });
  }

  void _addStickerItem(String sticker) {
    final uniqueId = DateTime.now().microsecondsSinceEpoch.toString();
    final size = _canvasSize ?? const Size(_canvasWidth, _canvasHeight);
    _pushUndo();
    setState(() {
      _placedItems.add(EditorItem(
        id: uniqueId,
        content: sticker,
        offset: Offset(size.width / 2 - 40, size.height / 2 - 20),
        fontSize: 28,
        color: AppColors.cyanAccent,
        bold: true,
      ));
      _selectedIdx = _placedItems.length - 1;
      _activeSubSection = ActiveSubSection.none;
      _editPanelCollapsed = false;
    });
  }

  void _removeItemAt(int idx) {
    _pushUndo();
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
                _addTextItem(controller.text.trim());
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

  // ── Export ────────────────────────────────────────────────────────────────

  Future<void> _exportCanvas() async {
    try {
      setState(() {
        _selectedIdx = null;
        _repositioningBackground = false;
        _activeSubSection = ActiveSubSection.none;
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

  // ── Sub-section Widgets ───────────────────────────────────────────────────

  /// Builds the icon/emoji picker section
  Widget _buildIconSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Icons & Emojis',
                style: TextStyle(
                    color: AppColors.cyanAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            GestureDetector(
              onTap: () => setState(() => _activeSubSection = ActiveSubSection.none),
              child: const Icon(Icons.close, color: Colors.white38, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 52,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _emojiPresets.length,
            itemBuilder: (ctx, idx) {
              return GestureDetector(
                onTap: () => _addIconItem(_emojiPresets[idx]),
                child: Container(
                  width: 48,
                  height: 48,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevatedLighter,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white12, width: 1),
                  ),
                  child: Center(
                    child: Text(
                      _emojiPresets[idx],
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Builds the sticker picker section
  Widget _buildStickersSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Stickers',
                style: TextStyle(
                    color: AppColors.amberAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            GestureDetector(
              onTap: () => setState(() => _activeSubSection = ActiveSubSection.none),
              child: const Icon(Icons.close, color: Colors.white38, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 52,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _stickerPresets.length,
            itemBuilder: (ctx, idx) {
              return GestureDetector(
                onTap: () => _addStickerItem(_stickerPresets[idx]),
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevatedLighter,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.amberAccent.withValues(alpha: 0.4), width: 1),
                  ),
                  child: Center(
                    child: Text(
                      _stickerPresets[idx],
                      style: const TextStyle(
                          color: AppColors.amberAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Builds the actual border overlay widget for the canvas
  Widget _buildBorderOverlay() {
    if (_selectedBorderType == BorderType.single) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: _selectedBorderColor, width: 3.0),
          borderRadius: BorderRadius.circular(16),
        ),
      );
    } else if (_selectedBorderType == BorderType.double) {
      const double w = 2.0;
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: _selectedBorderColor, width: w),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(w + 2),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: _selectedBorderColor, width: w),
            borderRadius: BorderRadius.circular(16 - w - 2),
          ),
        ),
      );
    } else if (_selectedBorderType == BorderType.triple) {
      const double w = 1.5;
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: _selectedBorderColor, width: w),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(w + 1.5),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: _selectedBorderColor, width: w),
            borderRadius: BorderRadius.circular(16 - w - 1.5),
          ),
          padding: const EdgeInsets.all(w + 1.5),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: _selectedBorderColor, width: w),
              borderRadius: BorderRadius.circular(16 - (w + 1.5) * 2),
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  /// Builds the border picker section
  Widget _buildBorderSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Canvas Border',
                style: TextStyle(
                    color: AppColors.purpleAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            GestureDetector(
              onTap: () => setState(() => _activeSubSection = ActiveSubSection.none),
              child: const Icon(Icons.close, color: Colors.white38, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _borderTypeButton(BorderType.none, 'None', Icons.border_clear),
            _borderTypeButton(BorderType.single, 'Single', Icons.crop_din),
            _borderTypeButton(BorderType.double, 'Double', Icons.filter_none),
            _borderTypeButton(BorderType.triple, 'Triple', Icons.layers_outlined),
          ],
        ),
        if (_selectedBorderType != BorderType.none) ...[
          const SizedBox(height: 12),
          const Text('Border Color', style: TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: ColorSwatchPicker.colorPalette.length,
                    itemBuilder: (ctx, idx) {
                      final c = ColorSwatchPicker.colorPalette[idx];
                      final isSelected = c == _selectedBorderColor;
                      return GestureDetector(
                        onTap: () => _setCanvasBorderColor(c),
                        child: Container(
                          width: 24,
                          height: 24,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected ? Colors.white : Colors.white24,
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
              GestureDetector(
                onTap: () => ColorSwatchPicker.showCustomColorPicker(
                    context, _selectedBorderColor, _setCanvasBorderColor),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24, width: 1.5),
                    gradient: const SweepGradient(
                      colors: [Colors.red, Colors.yellow, Colors.green, Colors.cyan, Colors.blue, Colors.purple, Colors.red],
                    ),
                  ),
                  child: const Icon(Icons.add, size: 14, color: Colors.white),
                ),
              ),
            ],
          ),
        ]
      ],
    );
  }

  Widget _borderTypeButton(BorderType type, String label, IconData icon) {
    final isSelected = _selectedBorderType == type;
    final color = isSelected ? AppColors.purpleAccent : Colors.white70;
    return GestureDetector(
      onTap: () => _setCanvasBorderType(type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.purpleAccent.withValues(alpha: 0.15) : AppColors.surfaceElevatedLighter,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColors.purpleAccent : Colors.white12,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  /// Builds the background reposition controls section
  Widget _buildBgRepositionSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Reposition Photo',
              style: TextStyle(
                  color: AppColors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 13),
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _resetBackgroundTransform,
                  icon: const Icon(Icons.restore, color: AppColors.pinkAccent, size: 14),
                  label: const Text('Reset', style: TextStyle(color: AppColors.pinkAccent, fontSize: 12)),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _toggleReposition,
                  child: const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _repoButton(Icons.rotate_left, 'Rotate L', () => _quickRotateBackground(-math.pi / 2)),
            _repoButton(Icons.zoom_out, 'Zoom -', () => _stepZoomBackground(-0.1)),
            _repoButton(Icons.zoom_in, 'Zoom +', () => _stepZoomBackground(0.1)),
            _repoButton(Icons.rotate_right, 'Rotate R', () => _quickRotateBackground(math.pi / 2)),
            _repoButton(Icons.hide_image_outlined, 'Remove', _removeBackgroundPhoto,
                iconColor: AppColors.pinkAccent),
          ],
        ),
      ],
    );
  }

  Widget _repoButton(IconData icon, String tooltip, VoidCallback onTap,
      {Color iconColor = Colors.white70}) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevatedLighter,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12, width: 1),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
      ),
    );
  }

  // ── Dynamic Section Dispatcher ────────────────────────────────────────────

  Widget? _buildDynamicSection(EditorItem? activeItem, bool hasPhoto) {
    // Priority: item style panel > sub-sections
    if (activeItem != null) {
      return EditorStylePanel(
        activeItem: activeItem,
        onChanged: () => setState(() {}),
        onEditStart: _pushUndo,
        onDelete: _removeActiveItem,
      );
    }

    switch (_activeSubSection) {
      case ActiveSubSection.icon:
        return _buildIconSection();
      case ActiveSubSection.stickers:
        return _buildStickersSection();
      case ActiveSubSection.border:
        return _buildBorderSection();
      case ActiveSubSection.bgReposition:
        if (hasPhoto) return _buildBgRepositionSection();
        return null;
      case ActiveSubSection.none:
        return null;
    }
  }

  // ── 6-Button Grid ─────────────────────────────────────────────────────────

  Widget _buildButtonGrid(bool hasPhoto) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 2.0,
      children: [
        _gridButton(
          icon: Icons.photo_library_outlined,
          label: 'Picture',
          color: AppColors.cyanAccent,
          onTap: _pickBackgroundPhoto,
        ),
        _gridButton(
          icon: Icons.camera_alt_outlined,
          label: 'Camera',
          color: AppColors.greenAccent,
          onTap: _openCamera,
        ),
        _gridButton(
          icon: Icons.text_fields,
          label: 'Text',
          color: AppColors.amberAccent,
          onTap: _openCustomTextInput,
        ),
        _gridButton(
          icon: Icons.emoji_emotions_outlined,
          label: 'Icon',
          color: AppColors.cyanAccent,
          isActive: _activeSubSection == ActiveSubSection.icon,
          onTap: () => _toggleSubSection(ActiveSubSection.icon),
        ),
        _gridButton(
          icon: Icons.auto_awesome_outlined,
          label: 'Stickers',
          color: AppColors.amberAccent,
          isActive: _activeSubSection == ActiveSubSection.stickers,
          onTap: () => _toggleSubSection(ActiveSubSection.stickers),
        ),
        _gridButton(
          icon: Icons.border_style_outlined,
          label: 'Border',
          color: AppColors.purpleAccent,
          isActive: _activeSubSection == ActiveSubSection.border,
          onTap: () => _toggleSubSection(ActiveSubSection.border),
        ),
      ],
    );
  }

  Widget _gridButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool isActive = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: isActive
              ? color.withValues(alpha: 0.15)
              : AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive ? color : Colors.white.withValues(alpha: 0.08),
            width: isActive ? 1.5 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              offset: const Offset(2, 2),
              blurRadius: 6,
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.03),
              offset: const Offset(-1, -1),
              blurRadius: 4,
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isActive ? color : color.withValues(alpha: 0.7), size: 18),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: isActive ? color : Colors.white70,
                fontSize: 12,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final EditorItem? activeItem =
        (_selectedIdx != null && _selectedIdx! < _placedItems.length)
            ? _placedItems[_selectedIdx!]
            : null;

    final bool bgGesturesEnabled = _repositioningBackground && !_isSaving;
    final bool hasPhoto = _bgImageBytes != null;

    final dynamicSectionWidget = _buildDynamicSection(activeItem, hasPhoto);
    final bool showDynamic = dynamicSectionWidget != null;

    return Scaffold(
      backgroundColor: AppColors.surface,
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
            if (_undoStack.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                child: NeumorphicIconButton(
                  icon: const Icon(Icons.undo, color: Colors.white70, size: 20),
                  onPressed: _applyUndo,
                  borderRadius: 24,
                  padding: const EdgeInsets.all(8.0),
                ),
              ),
            // Reposition button (only when photo loaded)
            if (hasPhoto)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                child: NeumorphicIconButton(
                  icon: Icon(
                    Icons.crop_rotate,
                    color: _repositioningBackground
                        ? Colors.greenAccent
                        : Colors.white54,
                    size: 20,
                  ),
                  isActive: _repositioningBackground,
                  onPressed: _toggleReposition,
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
              // ── Canvas / Display Panel ─────────────────────────────────────
              Expanded(
                flex: 5,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).size.height * 0.08,
                    left: 12,
                    right: 12,
                  ),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: _selectedBorderType == BorderType.none
                            ? null
                            : [
                                BoxShadow(
                                  color: _selectedBorderColor.withValues(alpha: 0.35),
                                  blurRadius: 12,
                                  spreadRadius: 1,
                                ),
                              ],
                      ),
                      child: RepaintBoundary(
                        key: _boundaryKey,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: AspectRatio(
                            aspectRatio: _canvasWidth / _canvasHeight,
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
                                                    _pushUndo();
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

                                    // Placed items (text, emojis, stickers)
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
                                                  setState(() {
                                                    _selectedIdx = index;
                                                    _activeSubSection =
                                                        ActiveSubSection.none;
                                                    _editPanelCollapsed = false;
                                                  });
                                                },
                                          onScaleStart: !itemGesturesEnabled
                                              ? null
                                              : (details) {
                                                  _pushUndo();
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
                                                    _editPanelCollapsed = false;
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
                                                    constraints: const BoxConstraints(
                                                      maxWidth: _canvasWidth - 40,
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
                                                    child: Text(
                                                      item.content,
                                                      textAlign: TextAlign.center,
                                                      softWrap: true,
                                                      style: TextStyle(
                                                        fontSize: item.fontSize,
                                                        fontFamily: item.fontFamily,
                                                        color: item.color,
                                                        fontWeight: item.bold
                                                            ? FontWeight.bold
                                                            : FontWeight.normal,
                                                        fontStyle: item.italic
                                                            ? FontStyle.italic
                                                            : FontStyle.normal,
                                                        letterSpacing:
                                                            item.letterSpacing,
                                                        decoration:
                                                            TextDecoration.combine([
                                                          if (item.underline)
                                                            TextDecoration.underline,
                                                          if (item.strikethrough)
                                                            TextDecoration.lineThrough,
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
                                                              const EdgeInsets.all(4),
                                                          decoration:
                                                              const BoxDecoration(
                                                            color: Colors.pinkAccent,
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
                                    // BORDER OVERLAY (drawn on top)
                                    if (_selectedBorderType != BorderType.none)
                                      Positioned.fill(
                                        child: IgnorePointer(
                                          child: _buildBorderOverlay(),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ── Background Color Selector (always directly below canvas) ───
              Opacity(
                opacity: _isSaving ? 0.0 : 1.0,
                child: IgnorePointer(
                  ignoring: _isSaving,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                    child: NeumorphicCard(
                      borderRadius: 16,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      child: Row(
                        children: [
                          const Text('BG:',
                              style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SizedBox(
                              height: 36,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: ColorSwatchPicker.colorPalette.length,
                                itemBuilder: (ctx, idx) {
                                  final c = ColorSwatchPicker.colorPalette[idx];
                                  final isSelected = c == _bgColor;
                                  return GestureDetector(
                                    onTap: () => _setBackgroundColor(c),
                                    child: Container(
                                      width: 32,
                                      height: 32,
                                      margin: const EdgeInsets.symmetric(horizontal: 3),
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
                            onTap: () => ColorSwatchPicker.showCustomColorPicker(
                                context, _bgColor, _setBackgroundColor),
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white24, width: 1.5),
                                gradient: const SweepGradient(
                                  colors: [
                                    Colors.red,
                                    Colors.yellow,
                                    Colors.green,
                                    Colors.cyan,
                                    Colors.blue,
                                    Colors.purple,
                                    Colors.red,
                                  ],
                                ),
                              ),
                              child: const Icon(Icons.add, size: 16, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (showDynamic)
                            GestureDetector(
                              onTap: () => setState(() => _editPanelCollapsed = !_editPanelCollapsed),
                              child: AnimatedRotation(
                                turns: _editPanelCollapsed ? 0.5 : 0.0,
                                duration: const Duration(milliseconds: 200),
                                child: const Icon(Icons.expand_less, color: Colors.white38, size: 24),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ── Dynamic Section (item edit / icon / sticker / border / bg repos) ─
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: Opacity(
                  opacity: _isSaving ? 0.0 : 1.0,
                  child: IgnorePointer(
                    ignoring: _isSaving,
                    child: (showDynamic && !_editPanelCollapsed)
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                            child: NeumorphicCard(
                              borderRadius: 16,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 150),
                                child: SingleChildScrollView(
                                  child: dynamicSectionWidget,
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ),

              // ── 6-Button Section (3 cols × 2 rows) ────────────────────────
              Opacity(
                opacity: _isSaving ? 0.0 : 1.0,
                child: IgnorePointer(
                  ignoring: _isSaving,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    child: _buildButtonGrid(hasPhoto),
                  ),
                ),
              ),
            ],
          ),

          // ── Saving overlay ─────────────────────────────────────────────────
          if (_isSaving)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(color: AppColors.cyanAccent),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Snapshot ──────────────────────────────────────────────────────────────────

class _EditorSnapshot {
  final List<EditorItem> items;
  final Color bgColor;
  final Uint8List? bgImageBytes;
  final Offset bgOffset;
  final double bgScale;
  final double bgRotation;
  final BorderType borderType;
  final Color borderColor;

  const _EditorSnapshot({
    required this.items,
    required this.bgColor,
    this.bgImageBytes,
    required this.bgOffset,
    required this.bgScale,
    required this.bgRotation,
    required this.borderType,
    required this.borderColor,
  });
}
