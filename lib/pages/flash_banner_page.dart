import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image_lib;

enum _BannerEffect { scroll, blink }
enum _ScrollDirection { rightToLeft, leftToRight, topToBottom, bottomToTop }

class FlashBannerPage extends StatefulWidget {
  const FlashBannerPage({super.key});

  @override
  State<FlashBannerPage> createState() => _FlashBannerPageState();
}

class _FlashBannerPageState extends State<FlashBannerPage> {
  // Native landscape canvas — matches the panel's physical 960×192 layout.
  // The firmware memcpys decoded pixels straight into the 960×192 framebuffer,
  // so the JPEG must be exactly this size.
  static const double _canvasWidth = 960;
  static const double _canvasHeight = 192;

  final TextEditingController _textController = TextEditingController(text: 'HELLO!');
  Color _textColor = Colors.white;
  Color _bgColor = Colors.black;
  _BannerEffect _effect = _BannerEffect.scroll;
  _ScrollDirection _direction = _ScrollDirection.rightToLeft;
  double _fontSize = 90;
  bool _generating = false;

  static const List<Color> _colorPalette = [
    Colors.white, Colors.black, Colors.red, Colors.orange, Colors.amber,
    Colors.yellow, Colors.green, Colors.teal, Colors.cyan, Colors.blue,
    Colors.indigo, Colors.purple, Colors.pink, Colors.brown, Colors.grey,
  ];

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Widget _colorSwatches(Color active, ValueChanged<Color> onPicked) {
    return SizedBox(
      height: 34,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _colorPalette.length,
        itemBuilder: (ctx, idx) {
          final c = _colorPalette[idx];
          final isSelected = c == active;
          return GestureDetector(
            onTap: () => onPicked(c),
            child: Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.symmetric(horizontal: 3),
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

  TextPainter _makeTextPainter() {
    final tp = TextPainter(
      text: TextSpan(
        text: _textController.text,
        style: TextStyle(color: _textColor, fontSize: _fontSize, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    return tp;
  }

  Future<Uint8List> _renderFrame({required double textX, required double textY, required bool showText}) async {
    final recorder = ui.PictureRecorder();
    // Draw directly on the native 960×192 landscape canvas — no rotation tricks.
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, _canvasWidth, _canvasHeight));

    canvas.drawRect(const Rect.fromLTWH(0, 0, _canvasWidth, _canvasHeight), Paint()..color = _bgColor);

    if (showText && _textController.text.isNotEmpty) {
      final tp = _makeTextPainter();
      tp.paint(canvas, Offset(textX, textY));
    }

    final picture = recorder.endRecording();
    // toImage() produces exactly 960×192 — landscape, matching the firmware framebuffer.
    final uiImg = await picture.toImage(_canvasWidth.round(), _canvasHeight.round());
    final byteData = await uiImg.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rawPixels = byteData!.buffer.asUint8List();
    final landscape = image_lib.Image.fromBytes(
      width: _canvasWidth.round(),   // 960
      height: _canvasHeight.round(), // 192
      bytes: rawPixels.buffer,
      format: image_lib.Format.uint8,
      numChannels: 4,
    );
    final rotated = image_lib.copyRotate(landscape, angle: 90);
    return Uint8List.fromList(image_lib.encodeJpg(rotated, quality: 90));
  }

  Future<List<Uint8List>> _generateFrames() async {
    final frames = <Uint8List>[];
    final tp = _makeTextPainter();
    final textWidth = tp.width;
    final textHeight = tp.height;

    if (_effect == _BannerEffect.blink) {
      final centeredX = (_canvasWidth - textWidth) / 2;
      final centeredY = (_canvasHeight - textHeight) / 2;
      frames.add(await _renderFrame(textX: centeredX, textY: centeredY, showText: true));
      frames.add(await _renderFrame(textX: centeredX, textY: centeredY, showText: false));
    } else {
      const int steps = 14; // keep the BLE upload count manageable
      double startX = 0, endX = 0, startY = 0, endY = 0;

      switch (_direction) {
        case _ScrollDirection.rightToLeft:
          startX = _canvasWidth;
          endX = -textWidth;
          startY = (_canvasHeight - textHeight) / 2;
          endY = startY;
          break;
        case _ScrollDirection.leftToRight:
          startX = -textWidth;
          endX = _canvasWidth;
          startY = (_canvasHeight - textHeight) / 2;
          endY = startY;
          break;
        case _ScrollDirection.topToBottom:
          startX = (_canvasWidth - textWidth) / 2;
          endX = startX;
          startY = -textHeight;
          endY = _canvasHeight;
          break;
        case _ScrollDirection.bottomToTop:
          startX = (_canvasWidth - textWidth) / 2;
          endX = startX;
          startY = _canvasHeight;
          endY = -textHeight;
          break;
      }

      for (int i = 0; i <= steps; i++) {
        final t = i / steps;
        final x = startX + (endX - startX) * t;
        final y = startY + (endY - startY) * t;
        frames.add(await _renderFrame(textX: x, textY: y, showText: true));
      }
    }
    return frames;
  }

  Future<void> _confirm() async {
    if (_textController.text.trim().isEmpty) return;
    setState(() => _generating = true);
    try {
      final frames = await _generateFrames();
      if (!mounted) return;
      Navigator.of(context).pop(frames);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flash Banner'),
        actions: [
          if (_generating)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(icon: const Icon(Icons.check), onPressed: _confirm),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _textController,
              decoration: const InputDecoration(
                labelText: 'Banner text',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            const Text('Effect', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<_BannerEffect>(
              segments: const [
                ButtonSegment(value: _BannerEffect.scroll, label: Text('Scroll'), icon: Icon(Icons.swap_horiz)),
                ButtonSegment(value: _BannerEffect.blink, label: Text('Blink')),
              ],
              selected: {_effect},
              onSelectionChanged: (s) => setState(() => _effect = s.first),
            ),
            if (_effect == _BannerEffect.scroll) ...[
              const SizedBox(height: 16),
              const Text('Scroll Direction', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SegmentedButton<_ScrollDirection>(
                segments: const [
                  ButtonSegment(value: _ScrollDirection.rightToLeft, icon: Icon(Icons.arrow_back)),
                  ButtonSegment(value: _ScrollDirection.leftToRight, icon: Icon(Icons.arrow_forward)),
                  ButtonSegment(value: _ScrollDirection.topToBottom, icon: Icon(Icons.arrow_downward)),
                  ButtonSegment(value: _ScrollDirection.bottomToTop, icon: Icon(Icons.arrow_upward)),
                ],
                selected: {_direction},
                onSelectionChanged: (s) => setState(() => _direction = s.first),
                showSelectedIcon: false,
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.format_size),
                Expanded(
                  child: Slider(
                    value: _fontSize,
                    min: 40,
                    max: 160,
                    onChanged: (v) => setState(() => _fontSize = v),
                  ),
                ),
                SizedBox(width: 36, child: Text(_fontSize.round().toString())),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Text color', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            _colorSwatches(_textColor, (c) => setState(() => _textColor = c)),
            const SizedBox(height: 12),
            const Text('Background color', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            _colorSwatches(_bgColor, (c) => setState(() => _bgColor = c)),
            const SizedBox(height: 20),
            AspectRatio(
              aspectRatio: _canvasWidth / _canvasHeight,
              child: Container(
                decoration: BoxDecoration(
                  color: _bgColor,
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    _textController.text,
                    style: TextStyle(
                      color: _textColor,
                      fontSize: _fontSize / 4,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _effect == _BannerEffect.scroll
                  ? 'Preview (not to scale) — the real banner scrolls across the panel.'
                  : 'Preview (not to scale) — the real banner blinks on/off on the panel.',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

