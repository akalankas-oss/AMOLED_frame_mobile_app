import 'package:flutter/material.dart';

import '../utils/image_utils.dart';
import '../widgets/neumorphic_components.dart';

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
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.cyan,
    Colors.blue,
    Colors.purple,
    Colors.pink,
    Colors.brown,
    Colors.grey,
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
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 8),
        SizedBox(
          height: 36,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _presetColors.length,
            itemBuilder: (ctx, idx) {
              final c = _presetColors[idx];
              final isSelected = c.toARGB32() == selected.toARGB32();
              return GestureDetector(
                onTap: () => onSelect(c),
                child: Container(
                  width: 30,
                  height: 30,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? AppColors.cyanAccent : Colors.white24,
                      width: isSelected ? 2.5 : 1,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: NeumorphicIconButton(
            icon: const Icon(Icons.arrow_back, size: 20, color: Colors.white),
            onPressed: () => Navigator.maybePop(context),
            borderRadius: 20,
            padding: EdgeInsets.zero,
          ),
        ),
        title: const Text('Create Text Image', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18)),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: _rendering
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(color: AppColors.cyanAccent, strokeWidth: 2.5),
                    ),
                  )
                : NeumorphicButton(
                    onPressed: _controller.text.trim().isEmpty ? null : _createAndReturn,
                    gradient: AppColors.primaryGradient,
                    icon: const Icon(Icons.check, size: 18, color: Colors.white),
                    label: 'Done',
                    borderRadius: 20,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Live Inset Preview ──────────────────────────────────────────
            NeumorphicCard(
              isInset: true,
              borderRadius: 18,
              padding: const EdgeInsets.all(6),
              child: AspectRatio(
                aspectRatio: panelWidth / panelHeight,
                child: Container(
                  decoration: BoxDecoration(
                    color: _bgColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0),
                      child: Text(
                        _controller.text.isEmpty ? 'Type text below' : _controller.text,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _controller.text.isEmpty ? Colors.white24 : _textColor,
                          fontSize: _fontSize / 4.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Preview • Rendered to 960×192 AMOLED resolution',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),

            const SizedBox(height: 16),

            // ── Text Input Card ──────────────────────────────────────────────
            NeumorphicCard(
              borderRadius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: TextField(
                controller: _controller,
                maxLength: 40,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: const InputDecoration(
                  labelText: 'Message Text',
                  labelStyle: TextStyle(color: AppColors.cyanAccent),
                  border: InputBorder.none,
                  counterStyle: TextStyle(color: Colors.white38),
                  hintText: 'Enter text here...',
                  hintStyle: TextStyle(color: Colors.white30),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),

            const SizedBox(height: 14),

            // ── Font Size & Colors Card ──────────────────────────────────────
            NeumorphicCard(
              borderRadius: 18,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.format_size, size: 20, color: AppColors.amberAccent),
                      const SizedBox(width: 8),
                      const Text('Font Size', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                      Expanded(
                        child: Slider(
                          value: _fontSize,
                          min: 24,
                          max: 140,
                          activeColor: AppColors.cyanAccent,
                          inactiveColor: AppColors.surfaceElevatedLighter,
                          onChanged: (v) => setState(() => _fontSize = v),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceInset,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _fontSize.round().toString(),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _colorSwatchRow('Text Color', _textColor, (c) => setState(() => _textColor = c)),
                  const SizedBox(height: 14),
                  _colorSwatchRow('Background Color', _bgColor, (c) => setState(() => _bgColor = c)),
                ],
              ),
            ),

            const SizedBox(height: 24),

            NeumorphicButton(
              onPressed: _rendering || _controller.text.trim().isEmpty ? null : _createAndReturn,
              gradient: AppColors.primaryGradient,
              icon: const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
              label: _rendering ? 'Rendering...' : 'Use This Image',
              textColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
