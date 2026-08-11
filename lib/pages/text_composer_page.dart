import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../utils/image_utils.dart';

class TextComposerPage extends StatefulWidget {
  const TextComposerPage({super.key});

  @override
  State<TextComposerPage> createState() => _TextComposerPageState();
}

class _TextComposerPageState extends State<TextComposerPage> {
  final _controller = TextEditingController();
  Color _textColor = Colors.white;
  Color _bgColor = Colors.black;
  double _fontSize = 64;
  bool _rendering = false;

  static const _presetColors = [
    Colors.white,
    Colors.black,
    Colors.red,
    Colors.green,
    Colors.blue,
    Colors.yellow,
    Colors.orange,
    Colors.purple,
    Colors.pink,
    Colors.cyan,
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _createAndReturn() async {
    if (_controller.text.trim().isEmpty) return;
    setState(() => _rendering = true);
    try {
      final bytes = await renderTextToPanelImage(
        text: _controller.text.trim(),
        textColor: _textColor,
        backgroundColor: _bgColor,
        fontSize: _fontSize,
      );
      if (mounted) Navigator.of(context).pop(bytes);
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
  }

  Widget _colorSwatchRow(String label, Color selected, ValueChanged<Color> onSelect) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _presetColors.map((c) {
            final isSelected = c.toARGB32() == selected.toARGB32();
            return GestureDetector(
              onTap: () => onSelect(c),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? Colors.blueAccent : Colors.grey,
                    width: isSelected ? 3 : 1,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Text Image')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              maxLength: 40,
              decoration: const InputDecoration(labelText: 'Message', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Text('Font size: ${_fontSize.round()}'),
            Slider(
              value: _fontSize,
              min: 24,
              max: 140,
              onChanged: (v) => setState(() => _fontSize = v),
            ),
            const SizedBox(height: 8),
            _colorSwatchRow('Text color', _textColor, (c) => setState(() => _textColor = c)),
            const SizedBox(height: 12),
            _colorSwatchRow('Background color', _bgColor, (c) => setState(() => _bgColor = c)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _rendering ? null : _createAndReturn,
              icon: const Icon(Icons.check),
              label: Text(_rendering ? 'Rendering...' : 'Use This Image'),
            ),
          ],
        ),
      ),
    );
  }
}
