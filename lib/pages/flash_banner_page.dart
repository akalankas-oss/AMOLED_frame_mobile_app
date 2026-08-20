import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image_lib;
import '../widgets/neumorphic_components.dart';

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
    double maxWidth = double.infinity;
    if (_effect == _BannerEffect.blink ||
        (_effect == _BannerEffect.scroll &&
            (_direction == _ScrollDirection.topToBottom ||
             _direction == _ScrollDirection.bottomToTop))) {
      maxWidth = _canvasWidth;
    }

    final tp = TextPainter(
      text: TextSpan(
        text: _textController.text,
        style: TextStyle(color: _textColor, fontSize: _fontSize, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout(minWidth: 0, maxWidth: maxWidth);
    return tp;
  }

  Future<Uint8List> _renderFrame({required double textX, required double textY, required bool showText}) async {
    final recorder = ui.PictureRecorder();
    // Draw directly on the native 960×192 landscape canvas — no rotation tricks.
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, _canvasWidth, _canvasHeight));
    canvas.clipRect(const Rect.fromLTWH(0, 0, _canvasWidth, _canvasHeight));

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
        title: const Text(
          'Flash Banner',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: _generating
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(color: AppColors.cyanAccent, strokeWidth: 2.5),
                    ),
                  )
                : NeumorphicButton(
                    onPressed: _textController.text.trim().isEmpty ? null : _confirm,
                    gradient: AppColors.primaryGradient,
                    icon: const Icon(Icons.bolt, size: 18, color: Colors.white),
                    label: 'Generate',
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
                aspectRatio: _canvasWidth / _canvasHeight,
                child: Container(
                  decoration: BoxDecoration(
                    color: _bgColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      _textController.text.isEmpty ? 'PREVIEW' : _textController.text,
                      style: TextStyle(
                        color: _textController.text.isEmpty ? Colors.white24 : _textColor,
                        fontSize: _fontSize / 4,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _effect == _BannerEffect.scroll
                  ? 'Preview • Scrolls across the 960×192 AMOLED frame'
                  : 'Preview • Blinks on and off on the 960×192 AMOLED frame',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),

            const SizedBox(height: 16),

            // ── Text Input Card ──────────────────────────────────────────────
            NeumorphicCard(
              borderRadius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: TextField(
                controller: _textController,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: const InputDecoration(
                  labelText: 'Banner Text',
                  labelStyle: TextStyle(color: AppColors.cyanAccent),
                  border: InputBorder.none,
                  hintText: 'Type your message...',
                  hintStyle: TextStyle(color: Colors.white30),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),

            const SizedBox(height: 14),

            // ── Effects & Animation Card ─────────────────────────────────────
            NeumorphicCard(
              borderRadius: 18,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Animation Effect', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: NeumorphicButton(
                          isActive: _effect == _BannerEffect.scroll,
                          onPressed: () => setState(() => _effect = _BannerEffect.scroll),
                          icon: const Icon(Icons.swap_horiz, size: 18, color: AppColors.cyanAccent),
                          label: 'Scroll',
                          borderRadius: 14,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: NeumorphicButton(
                          isActive: _effect == _BannerEffect.blink,
                          onPressed: () => setState(() => _effect = _BannerEffect.blink),
                          icon: const Icon(Icons.flash_on, size: 18, color: AppColors.pinkAccent),
                          label: 'Blink',
                          borderRadius: 14,
                        ),
                      ),
                    ],
                  ),
                  if (_effect == _BannerEffect.scroll) ...[
                    const SizedBox(height: 14),
                    const Text('Scroll Direction', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14)),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        NeumorphicIconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          isActive: _direction == _ScrollDirection.rightToLeft,
                          onPressed: () => setState(() => _direction = _ScrollDirection.rightToLeft),
                          tooltip: 'Right to Left',
                        ),
                        NeumorphicIconButton(
                          icon: const Icon(Icons.arrow_forward, color: Colors.white),
                          isActive: _direction == _ScrollDirection.leftToRight,
                          onPressed: () => setState(() => _direction = _ScrollDirection.leftToRight),
                          tooltip: 'Left to Right',
                        ),
                        NeumorphicIconButton(
                          icon: const Icon(Icons.arrow_downward, color: Colors.white),
                          isActive: _direction == _ScrollDirection.topToBottom,
                          onPressed: () => setState(() => _direction = _ScrollDirection.topToBottom),
                          tooltip: 'Top to Bottom',
                        ),
                        NeumorphicIconButton(
                          icon: const Icon(Icons.arrow_upward, color: Colors.white),
                          isActive: _direction == _ScrollDirection.bottomToTop,
                          onPressed: () => setState(() => _direction = _ScrollDirection.bottomToTop),
                          tooltip: 'Bottom to Top',
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 14),

            // ── Typography & Colors Card ─────────────────────────────────────
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
                          min: 40,
                          max: 160,
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
                  const SizedBox(height: 12),
                  const Text('Text Color', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 6),
                  _colorSwatches(_textColor, (c) => setState(() => _textColor = c)),
                  const SizedBox(height: 12),
                  const Text('Background Color', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 6),
                  _colorSwatches(_bgColor, (c) => setState(() => _bgColor = c)),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

