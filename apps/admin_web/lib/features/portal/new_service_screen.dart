import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../shared/form_dialog.dart';
import '../shared/toast.dart';
import 'address_field.dart';
import 'portal_shell.dart';

/// "Crear nuevo servicio": the insurance company orders a tow for its
/// policyholder.
///
/// The price is shown before anything is ordered and the order is billed at
/// exactly that price: the preview is signed by the server, and sending it
/// back with the order stops a second route lookup from changing the zone.
/// The nearest chofer is then found by the same dispatch as any tow.
class NewServiceScreen extends ConsumerStatefulWidget {
  const NewServiceScreen({super.key});

  /// What the form offers, in the order an operator thinks of them.
  static const List<VehicleType> vehicleTypes = [
    VehicleType.sedan,
    VehicleType.suv,
    VehicleType.camioneta,
    VehicleType.motor,
    VehicleType.camion,
    VehicleType.patana,
    VehicleType.equipoPesado,
  ];

  @override
  ConsumerState<NewServiceScreen> createState() => _NewServiceScreenState();
}

class _NewServiceScreenState extends ConsumerState<NewServiceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _claim = TextEditingController();
  final _policy = TextEditingController();
  final _insuredName = TextEditingController();
  final _insuredPhone = TextEditingController();
  final _plate = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _color = TextEditingController();
  final _notes = TextEditingController();

  ServiceLocation? _pickup;
  ServiceLocation? _dropoff;
  VehicleType _vehicleType = VehicleType.sedan;

  InsurerQuote? _quote;
  String? _quoteError;
  var _quoting = false;

  /// Bumped whenever an input the price depends on changes, so a late answer
  /// for the old places is thrown away rather than shown.
  var _quoteRound = 0;

  var _ordering = false;
  String? _orderError;
  var _placesMissing = false;

  @override
  void dispose() {
    for (final c in [
      _claim,
      _policy,
      _insuredName,
      _insuredPhone,
      _plate,
      _make,
      _model,
      _color,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _priceInputsChanged() {
    _quoteRound++;
    setState(() {
      _quote = null;
      _quoteError = null;
      _quoting = false;
      _placesMissing = false;
    });
    unawaited(_requote());
  }

  Future<void> _requote() async {
    final pickup = _pickup;
    final dropoff = _dropoff;
    if (pickup == null || dropoff == null) return;

    final round = _quoteRound;
    setState(() => _quoting = true);
    final result = await ref
        .read(functionsGatewayProvider)
        .quoteInsurerService(
          pickup: pickup,
          dropoff: dropoff,
          vehicleType: _vehicleType,
        );
    if (!mounted || round != _quoteRound) return;
    setState(() {
      _quoting = false;
      switch (result) {
        case Ok(:final value):
          _quote = value;
        case Err(:final failure):
          _quoteError = failure.userMessage;
      }
    });
  }

  Future<void> _order() async {
    if (_ordering) return;
    final formOk = _formKey.currentState?.validate() ?? false;
    final placesOk = _pickup != null && _dropoff != null;
    setState(() {
      _placesMissing = !placesOk;
      _orderError = null;
    });
    if (!formOk || !placesOk) return;

    var quote = _quote;
    // A price left on screen too long is asked for again rather than refused
    // by the server after the operator pressed the button.
    if (quote != null && quote.isExpiredAt(DateTime.now().toUtc())) {
      _quoteRound++;
      await _requote();
      if (!mounted) return;
      quote = _quote;
    }
    if (quote == null) {
      setState(
        () => _orderError =
            _quoteError ??
            'Espera a que aparezca el precio antes de pedir la grúa.',
      );
      return;
    }

    setState(() => _ordering = true);
    final request = InsurerServiceRequest(
      claimNumber: _claim.text,
      pickup: _pickup!,
      dropoff: _dropoff!,
      vehicleType: _vehicleType,
      policyNumber: _policy.text,
      insuredName: _insuredName.text,
      insuredPhone: _insuredPhone.text,
      plate: _plate.text,
      make: _make.text,
      model: _model.text,
      color: _color.text,
      notes: _notes.text,
    );
    final result = await ref
        .read(functionsGatewayProvider)
        .createInsurerService(request, priced: quote);
    if (!mounted) return;

    switch (result) {
      case Ok(:final value):
        showToast(
          context,
          'Servicio ${value.code} creado. Buscando la grúa más cercana…',
        );
        context.go(Routes.portalServiceFor(value.serviceId));
      case Err(:final failure):
        setState(() {
          _ordering = false;
          _orderError = switch (failure.code) {
            FailureCode.alreadyHasActiveService =>
              'Ya hay una grúa en curso para ese número de siniestro.',
            FailureCode.quoteExpired =>
              'El precio venció. Revisa el precio nuevo y vuelve a pedir.',
            _ => failure.userMessage,
          };
        });
        if (failure.code == FailureCode.quoteExpired) {
          _priceInputsChanged();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final insurer = ref.watch(myInsurerProvider).value;
    final suspended = insurer != null && !insurer.isActive;

    return ListView(
      padding: const EdgeInsets.all(Insets.xl),
      children: [
        const PortalHeader(
          title: 'Crear nuevo servicio',
          subtitle:
              'Llena los datos del siniestro y marca dónde está el '
              'vehículo. Al confirmar buscamos la grúa más cercana.',
        ),
        const SizedBox(height: Insets.xl),
        Form(
          key: _formKey,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(
                      icon: Icons.description_outlined,
                      title: 'Siniestro',
                      note: 'El número con que tu aseguradora lo archiva.',
                      children: [
                        FormRow(
                          left: LabeledField(
                            label: 'Número de siniestro',
                            required: true,
                            child: TextFormField(
                              key: const Key('claim-number'),
                              controller: _claim,
                              textCapitalization: TextCapitalization.characters,
                              maxLength: 40,
                              decoration: const InputDecoration(
                                hintText: 'SIN-2024-001489',
                                counterText: '',
                                prefixIcon: Icon(Icons.tag, size: 18),
                              ),
                              validator: (v) => (v?.trim().isEmpty ?? true)
                                  ? 'Escribe el número de siniestro.'
                                  : null,
                            ),
                          ),
                          right: LabeledField(
                            label: 'Número de póliza',
                            child: TextFormField(
                              key: const Key('policy-number'),
                              controller: _policy,
                              maxLength: 40,
                              decoration: const InputDecoration(
                                hintText: 'POL-000123',
                                counterText: '',
                                prefixIcon: Icon(
                                  Icons.shield_outlined,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                        ),
                        FormRow(
                          left: LabeledField(
                            label: 'Nombre del asegurado',
                            child: TextFormField(
                              key: const Key('insured-name'),
                              controller: _insuredName,
                              maxLength: 120,
                              textCapitalization: TextCapitalization.words,
                              decoration: const InputDecoration(
                                hintText: 'Juan Pérez',
                                counterText: '',
                                prefixIcon: Icon(
                                  Icons.person_outline,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                          right: LabeledField(
                            label: 'Teléfono del asegurado',
                            help: 'El chofer lo llama al llegar.',
                            child: TextFormField(
                              key: const Key('insured-phone'),
                              controller: _insuredPhone,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                hintText: '809 555-0123',
                                prefixIcon: Icon(
                                  Icons.phone_outlined,
                                  size: 18,
                                ),
                              ),
                              validator: (v) {
                                final value = v?.trim() ?? '';
                                if (value.isEmpty) return null;
                                return DoValidators.phone(value);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Insets.lg),
                    _Section(
                      icon: Icons.place_outlined,
                      title: 'Ubicaciones',
                      // Not the how-to: each field already says that under
                      // itself, and a third copy up here was noise.
                      note: 'De dónde se recoge y a dónde se lleva.',
                      children: [
                        LabeledField(
                          label: 'Dónde está el vehículo',
                          required: true,
                          child: AddressField(
                            key: const Key('pickup-field'),
                            fieldKey: 'pickup',
                            label: 'Dónde está el vehículo',
                            labelInside: false,
                            hint: 'Calle, sector o lugar conocido',
                            value: _pickup,
                            onChanged: (place) {
                              _pickup = place;
                              _priceInputsChanged();
                            },
                          ),
                        ),
                        LabeledField(
                          label: 'A dónde se lleva',
                          required: true,
                          child: AddressField(
                            key: const Key('dropoff-field'),
                            fieldKey: 'dropoff',
                            label: 'A dónde se lleva',
                            labelInside: false,
                            hint: 'Taller, casa del asegurado…',
                            value: _dropoff,
                            onChanged: (place) {
                              _dropoff = place;
                              _priceInputsChanged();
                            },
                          ),
                        ),
                        if (_placesMissing)
                          const InlineNotice(
                            key: Key('places-missing'),
                            tone: NoticeTone.error,
                            icon: Icons.error_outline,
                            message: 'Elige el punto de recogida y el destino.',
                          ),
                      ],
                    ),
                    const SizedBox(height: Insets.lg),
                    _Section(
                      icon: Icons.directions_car_outlined,
                      title: 'Vehículo',
                      note: 'El tipo decide la grúa y la columna de precio.',
                      children: [
                        LabeledField(
                          label: 'Tipo de vehículo',
                          required: true,
                          child: DropdownButtonFormField<VehicleType>(
                            key: const Key('vehicle-type'),
                            initialValue: _vehicleType,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              prefixIcon: Icon(
                                Icons.local_shipping_outlined,
                                size: 18,
                              ),
                            ),
                            items: [
                              for (final type in NewServiceScreen.vehicleTypes)
                                DropdownMenuItem(
                                  value: type,
                                  child: Text(
                                    '${type.label} · '
                                    '${VehicleClass.of(type).label}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (type) {
                              if (type == null || type == _vehicleType) return;
                              _vehicleType = type;
                              _priceInputsChanged();
                            },
                          ),
                        ),
                        FormRow(
                          left: LabeledField(
                            label: 'Placa',
                            child: TextFormField(
                              key: const Key('vehicle-plate'),
                              controller: _plate,
                              maxLength: 20,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(
                                hintText: 'A123456',
                                counterText: '',
                                prefixIcon: Icon(
                                  Icons.confirmation_number_outlined,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                          right: LabeledField(
                            label: 'Marca',
                            child: TextFormField(
                              key: const Key('vehicle-make'),
                              controller: _make,
                              maxLength: 60,
                              textCapitalization: TextCapitalization.words,
                              decoration: const InputDecoration(
                                hintText: 'Toyota',
                                counterText: '',
                              ),
                            ),
                          ),
                        ),
                        FormRow(
                          left: LabeledField(
                            label: 'Modelo',
                            child: TextFormField(
                              key: const Key('vehicle-model'),
                              controller: _model,
                              maxLength: 60,
                              textCapitalization: TextCapitalization.words,
                              decoration: const InputDecoration(
                                hintText: 'Corolla',
                                counterText: '',
                              ),
                            ),
                          ),
                          right: LabeledField(
                            label: 'Color',
                            child: TextFormField(
                              key: const Key('vehicle-color'),
                              controller: _color,
                              maxLength: 40,
                              textCapitalization: TextCapitalization.words,
                              decoration: const InputDecoration(
                                hintText: 'Gris',
                                counterText: '',
                              ),
                            ),
                          ),
                        ),
                        LabeledField(
                          label: 'Notas para el chofer',
                          child: TextFormField(
                            key: const Key('service-notes'),
                            controller: _notes,
                            maxLength: 500,
                            minLines: 3,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              hintText:
                                  'Vehículo en el parqueo, llave con el '
                                  'guardia…',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Insets.xl),
              SizedBox(
                width: 360,
                child: FloatingCard(
                  padding: const EdgeInsets.all(Insets.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _CardTitle(
                        icon: Icons.request_quote_outlined,
                        title: 'Precio',
                        note: 'Según la distancia y tu tarifa.',
                      ),
                      const SizedBox(height: Insets.lg),
                      _PricePanel(
                        quote: _quote,
                        error: _quoteError,
                        loading: _quoting,
                        waitingForPlaces: _pickup == null || _dropoff == null,
                      ),
                      if (_orderError != null) ...[
                        const SizedBox(height: Insets.md),
                        InlineNotice(
                          key: const Key('order-error'),
                          tone: NoticeTone.error,
                          icon: Icons.error_outline,
                          message: _orderError!,
                        ),
                      ],
                      if (suspended) ...[
                        const SizedBox(height: Insets.md),
                        const InlineNotice(
                          tone: NoticeTone.error,
                          icon: Icons.block,
                          message:
                              'Tu aseguradora está suspendida y no puede '
                              'pedir grúas ahora.',
                        ),
                      ],
                      const SizedBox(height: Insets.lg),
                      ElevatedButton.icon(
                        key: const Key('order-service'),
                        onPressed: _ordering || suspended ? null : _order,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          disabledBackgroundColor: _ordering
                              ? palette.brand.withValues(alpha: 0.75)
                              : null,
                          disabledForegroundColor: _ordering
                              ? BrandColors.white
                              : null,
                        ),
                        icon: _ordering
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: BrandColors.white,
                                ),
                              )
                            : const Icon(Icons.local_shipping_outlined),
                        label: Text(
                          _ordering ? 'Creando servicio…' : 'Crear servicio',
                        ),
                      ),
                      const SizedBox(height: Insets.sm),
                      Text(
                        'Se factura a tu aseguradora al cierre del mes.',
                        textAlign: TextAlign.center,
                        style: text.bodySmall?.copyWith(
                          color: palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One part of the order form: a card with an icon, a title and a line
/// saying what the part is for, and its fields under that.
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.note,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String note;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return FloatingCard(
      padding: const EdgeInsets.fromLTRB(
        Insets.xl,
        Insets.xl,
        Insets.xl,
        Insets.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardTitle(icon: icon, title: title, note: note),
          const SizedBox(height: Insets.xl),
          ...children,
        ],
      ),
    );
  }
}

/// An icon in a tinted square, a card's title, and what the card is for.
class _CardTitle extends StatelessWidget {
  const _CardTitle({
    required this.icon,
    required this.title,
    required this.note,
  });

  final IconData icon;
  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: palette.brandTint,
            borderRadius: Corners.brSm,
          ),
          child: Icon(icon, size: 20, color: palette.brand),
        ),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: text.titleMedium),
              Text(
                note,
                style: text.bodySmall?.copyWith(color: palette.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PricePanel extends StatelessWidget {
  const _PricePanel({
    required this.quote,
    required this.error,
    required this.loading,
    required this.waitingForPlaces,
  });

  final InsurerQuote? quote;
  final String? error;
  final bool loading;
  final bool waitingForPlaces;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final muted = text.bodyMedium?.copyWith(color: palette.textMuted);

    if (waitingForPlaces) {
      return _PriceNote(
        icon: Icons.route_outlined,
        child: Text(
          'Elige el punto de recogida y el destino para ver el precio.',
          key: const Key('price-waiting'),
          style: muted,
        ),
      );
    }
    if (loading) {
      return _PriceNote(
        icon: null,
        child: Text('Calculando la ruta…', style: muted),
      );
    }
    if (error != null) {
      return InlineNotice(
        key: const Key('price-error'),
        tone: NoticeTone.error,
        message: error!,
      );
    }
    final q = quote;
    if (q == null) return const SizedBox.shrink();

    return Column(
      key: const Key('price-preview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailRow(
          label: 'Distancia',
          value: '${q.distanceKm.toStringAsFixed(1)} km',
        ),
        DetailRow(
          label: 'Zona',
          value: '${q.zoneLabel} · ${q.vehicleClass.label}',
        ),
        DetailRow(label: 'Tarifa de la zona', value: q.baseCents.formatDOP),
        if (q.extraCents > 0)
          DetailRow(
            label: 'Km adicionales (${q.extraKm.toStringAsFixed(1)} km)',
            value: q.extraCents.formatDOP,
          ),
        const Divider(),
        DetailRow(label: 'Subtotal', value: q.subtotalCents.formatDOP),
        DetailRow(label: 'ITBIS 18%', value: q.itbisCents.formatDOP),
        DetailRow(
          key: const Key('price-total'),
          label: 'Total',
          value: q.totalCents.formatDOP,
          emphasise: true,
        ),
        const SizedBox(height: Insets.xs),
        Text(
          q.negotiated ? 'Tarifa acordada con tu aseguradora.' : 'Tarifa base.',
          style: text.bodySmall?.copyWith(color: palette.textMuted),
        ),
      ],
    );
  }
}

/// A state of the price panel before there is a price: a tinted box with an
/// icon, or a spinner while the route is worked out.
class _PriceNote extends StatelessWidget {
  const _PriceNote({required this.icon, required this.child});

  /// Null for the spinner.
  final IconData? icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: palette.surfaceSubtle,
        borderRadius: Corners.brMd,
      ),
      child: Row(
        children: [
          if (icon == null)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, size: 20, color: palette.textMuted),
          const SizedBox(width: Insets.md),
          Expanded(child: child),
        ],
      ),
    );
  }
}
