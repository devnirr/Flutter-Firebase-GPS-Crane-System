import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import 'registration_controller.dart';

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({required this.verificationId, required this.phone, super.key});

  final String verificationId;
  final String phone;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  var _verifying = false;
  String? _error;

  /// Resend is locked for a minute. Without it, a user tapping "reenviar"
  /// impatiently burns SMS credit and hits the provider's rate limit, which
  /// then blocks the legitimate retry.
  static const _resendCooldown = Duration(seconds: 60);
  Timer? _timer;
  var _secondsLeft = 60;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _secondsLeft = _resendCooldown.inSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) timer.cancel();
    });
  }

  Future<void> _verify(String code) async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
    });

    final result = await ref.read(authRepositoryProvider).confirmSmsCode(
          verificationId: widget.verificationId,
          smsCode: code,
        );
    if (!mounted) return;

    if (result.isErr) {
      final failure = result.fold((_) => null, (failure) => failure)!;
      setState(() {
        _verifying = false;
        _error = failure.userMessage;
        _controller.clear();
        _focus.requestFocus();
      });
      return;
    }

    // Signed in. If this code came from the register screen there are answers
    // waiting to be written, and they can only be written now that there is an
    // account to write them to. It is a no-op for a plain sign-in.
    final applied =
        await ref.read(registrationControllerProvider.notifier).apply();
    if (!mounted) return;

    // From here the router's redirect takes over: once the profile stream
    // reports a name it sends us home, and without one to the profile step.
    setState(() {
      _verifying = false;
      // The account exists either way, so a failure here is not a dead end -
      // say so and let the profile step collect what did not save.
      _error = applied.fold(
        (_) => null,
        (failure) => failure.userMessage,
      );
    });
  }

  Future<void> _resend() async {
    if (_secondsLeft > 0) return;
    await ref.read(authRepositoryProvider).startPhoneVerification(widget.phone);
    if (!mounted) return;
    _startCooldown();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Código reenviado.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pretty = widget.phone.length == 12
        ? '${widget.phone.substring(2, 5)}-'
            '${widget.phone.substring(5, 8)}-${widget.phone.substring(8)}'
        : widget.phone;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.gutter,
            vertical: Insets.xl,
          ),
          children: [
            const Center(child: GruaLogo(size: 180)),
            const SizedBox(height: Insets.xl),
            Text('Ingresa el código', style: text.headlineMedium),
            const SizedBox(height: Insets.sm),
            Text.rich(
              TextSpan(
                style: text.bodyLarge?.copyWith(color: BrandColors.grey600),
                children: [
                  const TextSpan(text: 'Enviamos un código de 6 dígitos al '),
                  TextSpan(
                    text: pretty,
                    style: text.bodyLarge?.copyWith(
                      color: BrandColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const TextSpan(text: '.'),
                ],
              ),
            ),
            const SizedBox(height: Insets.xxxl),
            _CodeField(
              controller: _controller,
              focusNode: _focus,
              enabled: !_verifying,
              hasError: _error != null,
              onCompleted: _verify,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: Insets.xl),
              InlineNotice(message: _error!, tone: NoticeTone.error),
            ],
            const SizedBox(height: Insets.xxl),
            if (_verifying)
              const BrandLoader(message: 'Verificando…')
            else
              Center(
                child: TextButton(
                  onPressed: _secondsLeft > 0 ? null : _resend,
                  child: Text(
                    _secondsLeft > 0
                        ? 'Reenviar código en $_secondsLeft s'
                        : 'Reenviar código',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Six boxes over one hidden field. A single field keeps paste, autofill and
/// SMS auto-retrieval working, which per-digit fields all break.
class _CodeField extends StatelessWidget {
  const _CodeField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.hasError,
    required this.onCompleted,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool hasError;
  final ValueChanged<String> onCompleted;
  final ValueChanged<String> onChanged;

  static const _length = 6;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final digits = value.text;
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < _length; i++)
                  _Box(
                    digit: i < digits.length ? digits[i] : '',
                    active: enabled && i == digits.length,
                    hasError: hasError,
                  ),
              ],
            );
          },
        ),
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              autofocus: true,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(_length),
              ],
              onChanged: (value) {
                onChanged(value);
                if (value.length == _length) onCompleted(value);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.digit, required this.active, required this.hasError});

  final String digit;
  final bool active;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final borderColor = hasError
        ? BrandColors.danger
        : active
            ? BrandColors.red
            : BrandColors.grey200;

    return AnimatedContainer(
      duration: Motion.fast,
      width: 48,
      height: 60,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: BrandColors.white,
        borderRadius: Corners.brMd,
        border: Border.all(color: borderColor, width: active ? 1.8 : 1.2),
      ),
      child: Text(
        digit,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
    );
  }
}
