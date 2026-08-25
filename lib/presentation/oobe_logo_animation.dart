import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Static Wristload mark for compact title rows and device identity surfaces.
class WristloadLogoMark extends StatelessWidget {
  const WristloadLogoMark({
    super.key,
    this.dimension = 32,
    this.color,
  });

  final double dimension;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final markColor = color ?? Theme.of(context).colorScheme.primary;
    return Semantics(
      label: 'Wristload',
      image: true,
      child: SizedBox.square(
        dimension: dimension,
        child: CustomPaint(
          painter: _OobeLogoPainter(progress: 1, color: markColor),
        ),
      ),
    );
  }
}

/// Expands the Wristload mark from the first outline to its ten-part fan.
class OobeLogoAnimation extends StatefulWidget {
  const OobeLogoAnimation({super.key});

  @override
  State<OobeLogoAnimation> createState() => _OobeLogoAnimationState();
}

class _OobeLogoAnimationState extends State<OobeLogoAnimation>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 1800);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
  );
  bool _animationPreferenceApplied = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_animationPreferenceApplied) return;
    _animationPreferenceApplied = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Semantics(
      label: 'Wristload',
      image: true,
      child: SizedBox.square(
        dimension: 220,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => CustomPaint(
            painter: _OobeLogoPainter(
              progress: _controller.value,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _OobeLogoPainter extends CustomPainter {
  const _OobeLogoPainter({required this.progress, required this.color});

  static const _outlineCount = 10;
  static const _maximumAngle = math.pi / 2;

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final outline = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: side * (276 / 824),
        height: side * (560 / 824),
      ),
      Radius.circular(side * (138 / 824)),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = side * (10 / 824)
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    for (var index = 0; index < _outlineCount; index++) {
      final target = index / (_outlineCount - 1);
      final intervalStart = target * .42;
      final localProgress = ((progress - intervalStart) / (1 - intervalStart))
          .clamp(0.0, 1.0);
      final easedProgress = Curves.easeOutCubic.transform(localProgress);
      final angle = _maximumAngle * target * easedProgress;

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      canvas.translate(-center.dx, -center.dy);
      canvas.drawRRect(outline, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _OobeLogoPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
