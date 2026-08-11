import 'package:image/image.dart' as img;
void main() {
  final canvas = img.Image(width: 960, height: 192, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(0, 0, 0));
  final src = img.Image(width: 100, height: 100, numChannels: 3);
  img.fill(src, color: img.ColorRgb8(255, 0, 0));
  img.compositeImage(canvas, src, dstX: 430, dstY: 46);
  print('success');
}
