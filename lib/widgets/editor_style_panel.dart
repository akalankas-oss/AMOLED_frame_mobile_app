import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../models/editor_item.dart';
import 'color_swatch_picker.dart';
import 'neumorphic_components.dart';

class EditorStylePanel extends StatelessWidget {
  final EditorItem activeItem;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  const EditorStylePanel({
    super.key,
    required this.activeItem,
    required this.onChanged,
    required this.onDelete,
  });

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
    final selected = activeItem.fontFamily == family;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(fontFamily: family, fontSize: 12)),
        selected: selected,
        onSelected: (_) {
          activeItem.fontFamily = family;
          onChanged();
        },
        selectedColor: Colors.amberAccent,
        backgroundColor: Colors.white10,
        labelStyle: TextStyle(color: selected ? Colors.black : Colors.white70),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(Icons.photo_size_select_large_outlined, size: 18, color: Colors.white),
            Expanded(
              child: Slider(
                value: activeItem.scale,
                min: 0.3,
                max: 4.0,
                onChanged: (v) {
                  activeItem.scale = v;
                  onChanged();
                },
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
                onChanged: (v) {
                  activeItem.rotation = v * math.pi / 180;
                  onChanged();
                },
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
                  onChanged: (v) {
                    activeItem.fontSize = v;
                    onChanged();
                  },
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
                  onChanged: (v) {
                    activeItem.letterSpacing = v;
                    onChanged();
                  },
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
                onTap: () {
                  activeItem.bold = !activeItem.bold;
                  onChanged();
                },
              ),
              _styleToggleButton(
                icon: Icons.format_italic,
                active: activeItem.italic,
                onTap: () {
                  activeItem.italic = !activeItem.italic;
                  onChanged();
                },
              ),
              _styleToggleButton(
                icon: Icons.format_underline,
                active: activeItem.underline,
                onTap: () {
                  activeItem.underline = !activeItem.underline;
                  onChanged();
                },
              ),
              _styleToggleButton(
                icon: Icons.format_strikethrough,
                active: activeItem.strikethrough,
                onTap: () {
                  activeItem.strikethrough = !activeItem.strikethrough;
                  onChanged();
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
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
          const SizedBox(height: 4),
        ],
        const Align(
          alignment: Alignment.centerLeft,
          child: Text('COLOR', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1)),
        ),
        const SizedBox(height: 4),
        ColorSwatchPicker(
          activeColor: activeItem.color,
          onColorPicked: (c) {
            activeItem.color = c;
            onChanged();
          },
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade800,
              foregroundColor: Colors.white,
            ),
            onPressed: onDelete,
            icon: const Icon(Icons.delete),
            label: const Text('Delete Selected Item'),
          ),
        ),
        const Divider(color: Colors.white24),
      ],
    );
  }
}
