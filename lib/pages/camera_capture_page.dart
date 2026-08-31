import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image_lib;

import '../widgets/neumorphic_components.dart';

/// A dedicated camera-capture screen for the image editor.
///
/// The preview is letterboxed/constrained to the AMOLED panel's 5:1 aspect
/// ratio (960 x 192) so the user sees exactly what will be cropped.
/// After tapping the shutter the image is cropped to 5:1 and the resulting
/// [Uint8List] is returned via [Navigator.pop].
class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key});

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage>
    with WidgetsBindingObserver {
  // Target aspect ratio: 960 / 192 = 5.0
  static const double _panelAspect = 960.0 / 192.0;

  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  int _selectedCameraIdx = 0;
  bool _isInitialized = false;
  bool _isCapturing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCameras();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      ctrl.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initController(_cameras[_selectedCameraIdx]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // ── Camera initialisation ─────────────────────────────────────────────────

  Future<void> _initCameras() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _errorMessage = 'No cameras found on this device.');
        return;
      }
      final backIdx = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      _selectedCameraIdx = backIdx >= 0 ? backIdx : 0;
      await _initController(_cameras[_selectedCameraIdx]);
    } catch (e) {
      setState(() => _errorMessage = 'Camera error: $e');
    }
  }

  Future<void> _initController(CameraDescription camera) async {
    final ctrl = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = ctrl;
    try {
      await ctrl.initialize();
      if (!mounted) return;
      setState(() {
        _isInitialized = true;
        _errorMessage = null;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = _describeCameraError(e));
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    setState(() => _isInitialized = false);
    await _controller?.dispose();
    _selectedCameraIdx = (_selectedCameraIdx + 1) % _cameras.length;
    await _initController(_cameras[_selectedCameraIdx]);
  }

  // ── Capture ───────────────────────────────────────────────────────────────

  Future<void> _capture() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _isCapturing) return;

    setState(() => _isCapturing = true);
    try {
      final file = await ctrl.takePicture();
      final rawBytes = await file.readAsBytes();

      final decoded = image_lib.decodeImage(rawBytes);
      if (decoded == null || !mounted) return;
      final oriented = image_lib.bakeOrientation(decoded);

      final cropped = _cropTo5x1(oriented);
      final jpegBytes =
          Uint8List.fromList(image_lib.encodeJpg(cropped, quality: 92));

      if (mounted) Navigator.of(context).pop(jpegBytes);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isCapturing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Capture failed: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  /// Crop [src] to 5:1 from the centre, then resize to 960x192.
  image_lib.Image _cropTo5x1(image_lib.Image src) {
    final srcW = src.width.toDouble();
    final srcH = src.height.toDouble();
    final srcAspect = srcW / srcH;

    int cropW, cropH, x0, y0;

    if (srcAspect >= _panelAspect) {
      cropH = src.height;
      cropW = (cropH * _panelAspect).round();
      x0 = ((src.width - cropW) / 2).round();
      y0 = 0;
    } else {
      cropW = src.width;
      cropH = (cropW / _panelAspect).round();
      x0 = 0;
      y0 = ((src.height - cropH) / 2).round();
    }

    final cropped =
        image_lib.copyCrop(src, x: x0, y: y0, width: cropW, height: cropH);

    return image_lib.copyResize(
      cropped,
      width: 960,
      height: 192,
      interpolation: image_lib.Interpolation.linear,
    );
  }

  String _describeCameraError(CameraException e) {
    switch (e.code) {
      case 'CameraAccessDenied':
        return 'Camera access denied. Please grant permission in Settings.';
      case 'CameraAccessDeniedWithoutPrompt':
        return 'Camera permission was permanently denied. Enable it in Settings.';
      default:
        return 'Camera error (${e.code}): ${e.description}';
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
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
        title: const Text(
          'Camera',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          if (_cameras.length > 1)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: NeumorphicIconButton(
                icon: const Icon(Icons.cameraswitch_outlined,
                    color: AppColors.cyanAccent, size: 22),
                onPressed: _isInitialized ? _switchCamera : null,
                borderRadius: 24,
                padding: const EdgeInsets.all(8.0),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Live preview constrained to 5:1
          Expanded(
            flex: 4,
            child: Center(child: _buildPreview()),
          ),
          // Shutter controls
          Expanded(
            flex: 2,
            child: _buildControls(),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.camera_alt_outlined,
                color: Colors.white30, size: 48),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (!_isInitialized || _controller == null) {
      return const CircularProgressIndicator(color: AppColors.cyanAccent);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: AspectRatio(
        aspectRatio: _panelAspect,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final previewAspect = _controller!.value.aspectRatio;
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Scale and centre the camera preview inside the 5:1 frame.
                  FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: constraints.maxWidth,
                      height: constraints.maxWidth / previewAspect,
                      child: CameraPreview(_controller!),
                    ),
                  ),

                  // Cyan border crop guide.
                  IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: AppColors.cyanAccent.withValues(alpha: 0.7),
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),

                  // Corner markers.
                  const IgnorePointer(child: _CornerMarkers()),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Frame will be cropped to the 5:1 panel ratio',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 20),
          // Shutter button
          GestureDetector(
            onTap: (_isInitialized && !_isCapturing) ? _capture : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isCapturing ? Colors.white24 : Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.cyanAccent.withValues(alpha: 0.4),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: _isCapturing
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.cyanAccent,
                      ),
                    )
                  : Container(
                      margin: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap to capture',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Corner Marker overlay ─────────────────────────────────────────────────────

class _CornerMarkers extends StatelessWidget {
  const _CornerMarkers();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _CornerPainter());
  }
}

class _CornerPainter extends CustomPainter {
  static const double _armLen = 16.0;
  static const double _strokeW = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.cyanAccent
      ..strokeWidth = _strokeW
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    _drawCorner(canvas, paint, Offset.zero, 1, 1);
    _drawCorner(canvas, paint, Offset(size.width, 0), -1, 1);
    _drawCorner(canvas, paint, Offset(0, size.height), 1, -1);
    _drawCorner(canvas, paint, Offset(size.width, size.height), -1, -1);
  }

  void _drawCorner(
      Canvas canvas, Paint paint, Offset origin, double dx, double dy) {
    canvas.drawLine(origin, origin + Offset(_armLen * dx, 0), paint);
    canvas.drawLine(origin, origin + Offset(0, _armLen * dy), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
