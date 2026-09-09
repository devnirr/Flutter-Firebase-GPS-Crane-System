import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';

/// The first screen a new customer sees.
///
/// Plain black ground carrying nothing but the mark, and the two entry points
/// raised into a white sheet at the bottom where a thumb reaches. Somebody
/// opening this app is usually stranded on a road, so there is nothing else.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrandColors.ink,
      body: Column(
        children: [
          // The mark holds the black area on its own, so it takes as much of
          // it as it can. Sizing off the constraints rather than a fixed width
          // keeps it clear of the sheet on short screens, where the height runs
          // out well before the width does.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Center(
                child: GruaLogo(
                  size: math.min(
                    constraints.maxWidth * 0.82,
                    constraints.maxHeight * 0.82 / GruaLogo.artworkRatio,
                  ),
                ),
              ),
            ),
          ),
          _EntrySheet(
            onPhone: () => context.push(Routes.phone),
            onRegister: () => context.push(Routes.register),
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
    return BottomActionSheet(
      // The sheet stands 1.6x its old height: the two buttons keep their
      // proportions and the extra room goes into the padding and the gaps, so
      // the sheet grows without the buttons stretching out of shape.
      padding: const EdgeInsets.fromLTRB(
        Insets.gutter,
        64,
        Insets.gutter,
        72,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(
            onPressed: onPhone,
            style: _entryButton,
            child: const Text('Entrar con Teléfono'),
          ),
          const SizedBox(height: 28),
          OutlinedButton(
            onPressed: onRegister,
            style: _entryButton,
            child: const Text('Registrarme'),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// Both entry points wear the same outline, so neither reads as the lesser
/// choice and the two can never drift apart in height or colour.
final ButtonStyle _entryButton = OutlinedButton.styleFrom(
  minimumSize: const Size.fromHeight(58),
  side: const BorderSide(color: BrandColors.red, width: 1.6),
  foregroundColor: BrandColors.red,
  shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
  textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
);
