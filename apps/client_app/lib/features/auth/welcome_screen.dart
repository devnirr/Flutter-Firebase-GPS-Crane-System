import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

/// The first screen a new customer sees.
///
/// Black ground with the outlined mark, and the two entry points raised into a
/// white sheet at the bottom where a thumb reaches. Somebody opening this app
/// is usually stranded on a road, so there is nothing else on it.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.ink,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Positioned.fill(child: _DiagonalStripes()),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const GruaLogo(size: 168, variant: GruaLogoVariant.outline),
                    const SizedBox(height: Insets.xxl),
                    Text(
                      'Grúas cuando más las necesitas',
                      textAlign: TextAlign.center,
                      style: text.titleMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _EntrySheet(
            onPhone: () => context.push(Routes.phone),
            onRegister: () => context.push(Routes.phone),
          ),
        ],
      ),
    );
  }
}

class _EntrySheet extends StatelessWidget {
  const _EntrySheet({required this.onPhone, required this.onRegister});

  final VoidCallback onPhone;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return BottomActionSheet(
      padding: const EdgeInsets.fromLTRB(
        Insets.gutter,
        Insets.xxl,
        Insets.gutter,
        Insets.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(
            onPressed: onPhone,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(58),
              side: const BorderSide(color: BrandColors.red, width: 1.6),
              foregroundColor: BrandColors.red,
              shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
              textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            child: const Text('Entrar con teléfono'),
          ),
          const SizedBox(height: Insets.md),
          OutlinedButton(
            onPressed: onRegister,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(58),
              side: const BorderSide(color: BrandColors.grey200, width: 1.6),
              foregroundColor: BrandColors.ink,
              shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
              textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            child: const Text('Registrarme'),
          ),
          const SizedBox(height: Insets.lg),
          Text(
            'Al continuar aceptas nuestros Términos y la Política de '
            'privacidad.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
        ],
      ),
    );
  }
}

/// The faint red hatching behind the mark, from the mockup.
class _DiagonalStripes extends StatelessWidget {
  const _DiagonalStripes();

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(painter: _StripePainter());
}

class _StripePainter extends CustomPainter {
  const _StripePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = BrandColors.red.withValues(alpha: 0.14)
      ..strokeWidth = 14;

    // Only the upper-right corner is hatched, so the mark stays on clean black.
    canvas
      ..save()
      ..clipRect(
        Rect.fromLTWH(size.width * 0.45, 0, size.width, size.height * 0.5),
      );
    for (var x = size.width * 0.2; x < size.width * 1.6; x += 34) {
      canvas.drawLine(Offset(x, -40), Offset(x - size.height, size.height), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripePainter oldDelegate) => false;
}
