import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
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
    final result = await ref.read(functionsGatewayProvider).quoteInsurerService(
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
      setState(() => _orderError = _quoteError ??
          'Espera a que aparezca el precio antes de pedir la grúa.');
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
          subtitle: 'Llena los datos del siniestro y marca dónde está el '
              'vehículo. Al confirmar buscamos la grúa más cercana.',
        ),
        const SizedBox(height: Insets.xl),
        Form(
          key: _formKey,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(
                      title: 'Siniestro',
                      children: [
                        _pair(
                          TextFormField(
                            key: const Key('claim-number'),
                            controller: _claim,
                            textCapitalization: TextCapitalization.characters,
                            maxLength: 40,
                            decoration: const InputDecoration(
                              labelText: 'Número de siniestro *',
                              hintText: 'SIN-2024-001489',
                              counterText: '',
                            ),
                            validator: (v) => (v?.trim().isEmpty ?? true)
                                ? 'Escribe el número de siniestro.'
                                : null,
                          ),
                          TextFormField(
                            key: const Key('policy-number'),
                            controller: _policy,
                            maxLength: 40,
                            decoration: const InputDecoration(
                              labelText: 'Número de póliza',
                              counterText: '',
                            ),
                          ),
                        ),
                        _pair(
                          TextFormField(
                            key: const Key('insured-name'),
                            controller: _insuredName,
                            maxLength: 120,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Nombre del asegurado',
                              counterText: '',
                            ),
                          ),
                          TextFormField(
                            key: const Key('insured-phone'),
                            controller: _insuredPhone,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              labelText: 'Teléfono del asegurado',
                              hintText: '809-555-0123',
                            ),
                            validator: (v) {
                              final value = v?.trim() ?? '';
                              if (value.isEmpty) return null;
                              return DoValidators.phone(value);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Insets.lg),
                    _Section(
                      title: 'Ubicaciones',
                      children: [
                        AddressField(
                          key: const Key('pickup-field'),
                          fieldKey: 'pickup',
                          label: 'Dónde está el vehículo *',
                          hint: 'Calle, sector o lugar conocido',
                          value: _pickup,
                          onChanged: (place) {
                            _pickup = place;
                            _priceInputsChanged();
                          },
                        ),
                        const SizedBox(height: Insets.lg),
                        AddressField(
                          key: const Key('dropoff-field'),
                          fieldKey: 'dropoff',
                          label: 'A dónde se lleva *',
                          hint: 'Taller, casa del asegurado…',
                          value: _dropoff,
                          onChanged: (place) {
                            _dropoff = place;
                            _priceInputsChanged();
                          },
                        ),
                        if (_placesMissing) ...[
                          const SizedBox(height: Insets.md),
                          const InlineNotice(
                            key: Key('places-missing'),
                            tone: NoticeTone.error,
                            message: 'Elige el punto de recogida y el destino.',
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: Insets.lg),
                    _Section(
                      title: 'Vehículo',
                      children: [
                        DropdownButtonFormField<VehicleType>(
                          key: const Key('vehicle-type'),
                          initialValue: _vehicleType,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Tipo de vehículo *',
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
                        const SizedBox(height: Insets.md),
                        _pair(
                          TextFormField(
                            key: const Key('vehicle-plate'),
                            controller: _plate,
                            maxLength: 20,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'Placa',
                              hintText: 'A123456',
                              counterText: '',
                            ),
                          ),
                          TextFormField(
                            key: const Key('vehicle-make'),
                            controller: _make,
                            maxLength: 60,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Marca',
                              hintText: 'Toyota',
                              counterText: '',
                            ),
                          ),
                        ),
                        _pair(
                          TextFormField(
                            key: const Key('vehicle-model'),
                            controller: _model,
                            maxLength: 60,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Modelo',
                              hintText: 'Corolla',
                              counterText: '',
                            ),
                          ),
                          TextFormField(
                            key: const Key('vehicle-color'),
                            controller: _color,
                            maxLength: 40,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Color',
                              hintText: 'Gris',
                              counterText: '',
                            ),
                          ),
                        ),
                        TextFormField(
                          key: const Key('service-notes'),
                          controller: _notes,
                          maxLength: 500,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Notas para el chofer',
                            hintText: 'Vehículo en el parqueo, llave con el '
                                'guardia…',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Insets.xl),
              SizedBox(
                width: 340,
                child: FloatingCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Precio', style: text.titleMedium),
                      const SizedBox(height: Insets.md),
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
                          message: _orderError!,
                        ),
                      ],
                      const SizedBox(height: Insets.lg),
                      ElevatedButton(
                        key: const Key('order-service'),
                        onPressed: _ordering || suspended ? null : _order,
                        child: _ordering
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: BrandColors.white,
                                ),
                              )
                            : const Text('Crear servicio'),
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

  Widget _pair(Widget a, Widget b) => Padding(
        padding: const EdgeInsets.only(bottom: Insets.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: a),
            const SizedBox(width: Insets.md),
            Expanded(child: b),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Insets.md),
          ...children,
        ],
      ),
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
      return Text(
        'Elige el punto de recogida y el destino para ver el precio.',
        key: const Key('price-waiting'),
        style: muted,
      );
    }
    if (loading) {
      return const Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: Insets.md),
          Text('Calculando la ruta…'),
        ],
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
