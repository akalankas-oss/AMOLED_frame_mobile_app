import 'package:flutter/material.dart';

class NeumorphicCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final bool isInset;
  final Color? color;
  final double blurRadius;
  final double shadowOffset;

  const NeumorphicCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 16.0,
    this.isInset = false,
    this.color,
    this.blurRadius = 8.0,
    this.shadowOffset = 4.0,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = color ?? Colors.grey.shade900;
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: isInset
            ? null // Native BoxShadow doesn't support inset. We remove shadow to simulate pressed state visually.
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  offset: Offset(shadowOffset, shadowOffset),
                  blurRadius: blurRadius,
                ),
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.05),
                  offset: Offset(-shadowOffset, -shadowOffset),
                  blurRadius: blurRadius,
                ),
              ],
        border: isInset
            ? Border.all(color: Colors.black.withValues(alpha: 0.3), width: 2) // Fake inset with a dark border
            : Border.all(color: Colors.transparent, width: 2),
      ),
      child: child,
    );
  }
}

class NeumorphicIconButton extends StatefulWidget {
  final Widget icon;
  final VoidCallback? onPressed;
  final bool isActive;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const NeumorphicIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.isActive = false,
    this.borderRadius = 12.0,
    this.padding = const EdgeInsets.all(12.0),
    this.color,
  });

  @override
  State<NeumorphicIconButton> createState() => _NeumorphicIconButtonState();
}

class _NeumorphicIconButtonState extends State<NeumorphicIconButton> {
  bool _isPressed = false;

  void _handleTapDown(TapDownDetails details) {
    if (widget.onPressed != null) {
      setState(() => _isPressed = true);
    }
  }

  void _handleTapUp(TapUpDetails details) {
    if (widget.onPressed != null) {
      setState(() => _isPressed = false);
      widget.onPressed!();
    }
  }

  void _handleTapCancel() {
    if (widget.onPressed != null) {
      setState(() => _isPressed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool showInset = _isPressed || widget.isActive;
    
    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedScale(
        scale: showInset ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: NeumorphicCard(
          padding: widget.padding,
          borderRadius: widget.borderRadius,
          isInset: showInset,
          color: widget.color,
          blurRadius: 6.0,
          shadowOffset: 3.0,
          child: widget.icon,
        ),
      ),
    );
  }
}
