import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../models/editor_item.dart';
import 'color_swatch_picker.dart';
import 'neumorphic_components.dart';

class EditorStylePanel extends StatefulWidget {
  final EditorItem activeItem;
  final VoidCallback onChanged;
  final VoidCallback onDelete;
  final VoidCallback? onEditStart;

  const EditorStylePanel({
    super.key,
    required this.activeItem,
    required this.onChanged,
    required this.onDelete,
    this.onEditStart,
  });

  @override
  State<EditorStylePanel> createState() => _EditorStylePanelState();
}

class _EditorStylePanelState extends State<EditorStylePanel> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Widget _styleToggleButton({required IconData icon, required bool active, required VoidCallback onTap}) {
    return NeumorphicIconButton(
      icon: Icon(icon, size: 20, color: active ? Colors.amberAccent : Colors.white70),
      isActive: active,
      onPressed: onTap,
      borderRadius: 8,
      padding: const EdgeInsets.all(8),
    );
  }

  Widget _fontChip(String label, String? family) {
    final selected = widget.activeItem.fontFamily == family;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(fontFamily: family, fontSize: 12)),
        selected: selected,
        onSelected: (_) {
          widget.onEditStart?.call();
          widget.activeItem.fontFamily = family;
          widget.onChanged();
        },
        selectedColor: Colors.amberAccent,
        backgroundColor: Colors.white10,
        labelStyle: TextStyle(color: selected ? Colors.black : Colors.white70),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.activeItem;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                indicatorColor: Colors.cyanAccent,
                labelColor: Colors.cyanAccent,
                unselectedLabelColor: Colors.white54,
                dividerColor: Colors.transparent,
                labelPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                tabs: const [
                  Tab(text: 'Transform'),
                  Tab(text: 'Text'),
                  Tab(text: 'Color'),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.pinkAccent, size: 20),
              onPressed: widget.onDelete,
              tooltip: 'Delete Item',
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildTabContent(item),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildTabContent(EditorItem item) {
    switch (_tabController.index) {
      case 0: // Transform
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.photo_size_select_large_outlined, size: 18, color: Colors.white),
                Expanded(
                  child: Slider(
                    value: item.scale,
                    min: 0.3,
                    max: 4.0,
                    onChangeStart: (_) => widget.onEditStart?.call(),
                    onChanged: (v) {
                      item.scale = v;
                      widget.onChanged();
                    },
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${(item.scale * 100).round()}%',
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
                    value: ((item.rotation * 180 / math.pi) % 360 + 360) % 360,
                    min: 0,
                    max: 360,
                    onChangeStart: (_) => widget.onEditStart?.call(),
                    onChanged: (v) {
                      item.rotation = v * math.pi / 180;
                      widget.onChanged();
                    },
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${(((item.rotation * 180 / math.pi) % 360 + 360) % 360).round()}°',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        );
      case 1: // Text
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.format_size, size: 18, color: Colors.white),
                Expanded(
                  child: Slider(
                    value: item.fontSize,
                    min: 12,
                    max: 90,
                    onChangeStart: (_) => widget.onEditStart?.call(),
                    onChanged: (v) {
                      item.fontSize = v;
                      widget.onChanged();
                    },
                  ),
                ),
                SizedBox(
                  width: 30,
                  child: Text(
                    item.fontSize.round().toString(),
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
                    value: item.letterSpacing,
                    min: -2,
                    max: 20,
                    onChangeStart: (_) => widget.onEditStart?.call(),
                    onChanged: (v) {
                      item.letterSpacing = v;
                      widget.onChanged();
                    },
                  ),
                ),
                SizedBox(
                  width: 30,
                  child: Text(
                    item.letterSpacing.round().toString(),
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
                  active: item.bold,
                  onTap: () {
                    widget.onEditStart?.call();
                    item.bold = !item.bold;
                    widget.onChanged();
                  },
                ),
                _styleToggleButton(
                  icon: Icons.format_italic,
                  active: item.italic,
                  onTap: () {
                    widget.onEditStart?.call();
                    item.italic = !item.italic;
                    widget.onChanged();
                  },
                ),
                _styleToggleButton(
                  icon: Icons.format_underline,
                  active: item.underline,
                  onTap: () {
                    widget.onEditStart?.call();
                    item.underline = !item.underline;
                    widget.onChanged();
                  },
                ),
                _styleToggleButton(
                  icon: Icons.format_strikethrough,
                  active: item.strikethrough,
                  onTap: () {
                    widget.onEditStart?.call();
                    item.strikethrough = !item.strikethrough;
                    widget.onChanged();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _fontChip('Default', null),
                  _fontChip('Serif', 'serif'),
                  _fontChip('Monospace', 'monospace'),
                  _fontChip('Condensed', 'sans-serif-condensed'),
                  _fontChip('Cursive', 'cursive'),
                ],
              ),
            ),
          ],
        );
      case 2: // Color
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColorSwatchPicker(
              activeColor: item.color,
              onColorPicked: (c) {
                widget.onEditStart?.call();
                item.color = c;
                widget.onChanged();
              },
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
