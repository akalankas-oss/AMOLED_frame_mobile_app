import 'package:flutter/material.dart';

// AMOLED Neumorphic Design Tokens
class AppColors {
  static const Color black = Color(0xFF1A1A2E);
  static const Color surface = Color(0xFF252535);
  static const Color surfaceElevated = Color(0xFF2E2E40);
  static const Color surfaceElevatedLighter = Color(0xFF38384C);
  static const Color surfaceInset = Color(0xFF1C1C2C);
  
  static const Color cyanAccent = Color(0xFF00F0FF);
  static const Color pinkAccent = Color(0xFFFF2A85);
  static const Color amberAccent = Color(0xFFFFB800);
  static const Color greenAccent = Color(0xFF00E676);
  static const Color purpleAccent = Color(0xFFBD00FF);

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFFFF2A85), Color(0xFFFF8B3D)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cyanGradient = LinearGradient(
    colors: [Color(0xFF00F0FF), Color(0xFF0088FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class NeumorphicCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final bool isInset;
  final Color? color;
  final double blurRadius;
  final double shadowOffset;
  final Border? border;
  final Gradient? gradient;

  const NeumorphicCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 18.0,
    this.isInset = false,
    this.color,
    this.blurRadius = 10.0,
    this.shadowOffset = 4.0,
    this.border,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = color ?? (isInset ? AppColors.surfaceInset : AppColors.surfaceElevated);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? bgColor : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: isInset
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.8),
                  offset: Offset(shadowOffset * 0.5, shadowOffset * 0.5),
                  blurRadius: blurRadius * 0.6,
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.7),
                  offset: Offset(shadowOffset, shadowOffset),
                  blurRadius: blurRadius,
                ),
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.04),
                  offset: Offset(-shadowOffset, -shadowOffset),
                  blurRadius: blurRadius,
                ),
              ],
        border: border ??
            (isInset
                ? Border.all(color: Colors.black.withValues(alpha: 0.5), width: 1.5)
                : Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.0)),
      ),
      child: child,
    );
  }
}

class NeumorphicButton extends StatefulWidget {
  final Widget? child;
  final String? label;
  final Widget? icon;
  final VoidCallback? onPressed;
  final bool isActive;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Gradient? gradient;
  final Color? textColor;
  final double? height;
  final double? width;

  const NeumorphicButton({
    super.key,
    this.child,
    this.label,
    this.icon,
    this.onPressed,
    this.isActive = false,
    this.borderRadius = 16.0,
    this.padding = const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
    this.color,
    this.gradient,
    this.textColor,
    this.height,
    this.width,
  });

  @override
  State<NeumorphicButton> createState() => _NeumorphicButtonState();
}

class _NeumorphicButtonState extends State<NeumorphicButton> {
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
    final bool isEnabled = widget.onPressed != null;

    Widget content;
    if (widget.child != null) {
      content = widget.child!;
    } else {
      final List<Widget> children = [];
      if (widget.icon != null) {
        children.add(widget.icon!);
      }
      if (widget.icon != null && widget.label != null) {
        children.add(const SizedBox(width: 8));
      }
      if (widget.label != null) {
        children.add(
          Text(
            widget.label!,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: widget.textColor ?? (isEnabled ? Colors.white : Colors.white38),
            ),
          ),
        );
      }
      content = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: children,
      );
    }

    return Opacity(
      opacity: isEnabled ? 1.0 : 0.45,
      child: GestureDetector(
        onTapDown: isEnabled ? _handleTapDown : null,
        onTapUp: isEnabled ? _handleTapUp : null,
        onTapCancel: isEnabled ? _handleTapCancel : null,
        child: AnimatedScale(
          scale: showInset ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: SizedBox(
            height: widget.height,
            width: widget.width,
            child: NeumorphicCard(
              padding: widget.padding,
              borderRadius: widget.borderRadius,
              isInset: showInset,
              color: widget.color,
              gradient: widget.gradient,
              blurRadius: 8.0,
              shadowOffset: 3.5,
              border: widget.isActive
                  ? Border.all(color: AppColors.cyanAccent, width: 1.5)
                  : null,
              child: Center(child: content),
            ),
          ),
        ),
      ),
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
  final Gradient? gradient;
  final String? tooltip;

  const NeumorphicIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.isActive = false,
    this.borderRadius = 14.0,
    this.padding = const EdgeInsets.all(12.0),
    this.color,
    this.gradient,
    this.tooltip,
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
    final bool isEnabled = widget.onPressed != null;

    Widget button = Opacity(
      opacity: isEnabled ? 1.0 : 0.4,
      child: GestureDetector(
        onTapDown: isEnabled ? _handleTapDown : null,
        onTapUp: isEnabled ? _handleTapUp : null,
        onTapCancel: isEnabled ? _handleTapCancel : null,
        child: AnimatedScale(
          scale: showInset ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: NeumorphicCard(
            padding: widget.padding,
            borderRadius: widget.borderRadius,
            isInset: showInset,
            color: widget.color,
            gradient: widget.gradient,
            blurRadius: 7.0,
            shadowOffset: 3.0,
            border: widget.isActive
                ? Border.all(color: AppColors.cyanAccent, width: 1.5)
                : null,
            child: widget.icon,
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}
