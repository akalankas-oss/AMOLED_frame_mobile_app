import 'package:flutter/material.dart';

class ColorSwatchPicker extends StatelessWidget {
  final Color activeColor;
  final ValueChanged<Color> onColorPicked;

  const ColorSwatchPicker({
    super.key,
    required this.activeColor,
    required this.onColorPicked,
  });

  static const List<Color> colorPalette = [
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

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: colorPalette.length,
        itemBuilder: (ctx, idx) {
          final c = colorPalette[idx];
          final isSelected = c.toARGB32() == activeColor.toARGB32();
          return GestureDetector(
            onTap: () => onColorPicked(c),
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

  static Future<void> showCustomColorPicker(
    BuildContext context,
    Color initial,
    ValueChanged<Color> onPicked,
  ) async {
    final int argb = initial.toARGB32();
    int r = (argb >> 16) & 0xFF;
    int g = (argb >> 8) & 0xFF;
    int b = argb & 0xFF;
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
}
