import 'package:flutter/material.dart';

class EditorItem {
  EditorItem({
    required this.id,
    required this.content,
    this.offset = const Offset(50, 50),
    this.scale = 1.0,
    this.rotation = 0.0,
    Color? color,
    this.fontSize = 34,
    this.fontFamily,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.letterSpacing = 0,
  }) : color = color ?? Colors.white;

  final String id;
  final String content;
  Offset offset;
  double scale;
  double rotation; // radians
  Color color;
  double fontSize;
  String? fontFamily; // null = default
  bool bold;
  bool italic;
  bool underline;
  bool strikethrough;
  double letterSpacing;

  EditorItem clone() {
    return EditorItem(
      id: id,
      content: content,
      offset: offset,
      scale: scale,
      rotation: rotation,
      color: color,
      fontSize: fontSize,
      fontFamily: fontFamily,
      bold: bold,
      italic: italic,
      underline: underline,
      strikethrough: strikethrough,
      letterSpacing: letterSpacing,
    );
  }
}
