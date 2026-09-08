import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import 'quote_sheet.dart';
import 'request_controller.dart';

/// The request form.
///
/// Red header with the mark, then one white sheet carrying every field, exactly
/// as in the mockup. The order matters: vehicle, then problem, then photos,
/// then where — a stranded customer can answer the first three from memory, and
/// the address is the one that needs them to look around.
class RequestScreen extends ConsumerStatefulWidget {
  const RequestScreen({super.key});

  @override
  ConsumerState<RequestScreen> createState() => _RequestScreenState();
}

class _RequestScreenState extends ConsumerState<RequestScreen> {
  final _formKey = GlobalKey<FormState>();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _plate = TextEditingController();
  final _pickup = TextEditingController();
  final _reference = TextEditingController();
  final _dropoff = TextEditingController();

  @override
  void initState() {
    super.initState();
    final draft = ref.read(requestControllerProvider);
    _pickup.text = draft.pickup?.address ?? '';
    _reference.text = draft.pickup?.reference ?? '';
  }

  @override
  void dispose() {
    _make.dispose();
    _model.dispose();
    _plate.dispose();
    _pickup.dispose();
    _reference.dispose();
    _dropoff.dispose();
    super.dispose();
  }

  void _syncVehicle() {
    final controller = ref.read(requestControllerProvider.notifier);
    final current = ref.read(requestControllerProvider).vehicle;
    controller.setVehicle(
      current.copyWith(
        make: _make.text.trim(),
        model: _model.text.trim(),
        plate: _plate.text.trim().toUpperCase(),
      ),
    );
  }

  void _syncLocations() {
    final controller = ref.read(requestControllerProvider.notifier);
    final draft = ref.read(requestControllerProvider);

    controller.setPickup(
      (draft.pickup ??
              const ServiceLocation(geo: DoLocations.defaultCenter))
          .copyWith(
        address: _pickup.text.trim(),
        reference: _reference.text.trim(),
      ),
    );

    final dropoffText = _dropoff.text.trim();
    if (dropoffText.isNotEmpty) {
      controller.setDropoff(
        (draft.dropoff ??
                // Stand-in coordinates until the map picker lands; the address
                // text is what the chofer actually navigates by today.
                const ServiceLocation(geo: DoLocations.santoDomingo))
            .copyWith(address: dropoffText),
      );
    }
  }

  Future<void> _continue() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    _syncVehicle();
    _syncLocations();

    final controller = ref.read(requestControllerProvider.notifier);
    await controller.requestQuote();
    if (!mounted) return;

    final draft = ref.read(requestControllerProvider);
    if (draft.quote == null) return;

    final serviceId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const QuoteSheet(),
    );

    if (serviceId != null && mounted) {
      controller.reset();
      context.go(Routes.trackingFor(serviceId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(requestControllerProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: BrandColors.redDark,
      body: Column(
        children: [
          _Header(onBack: () => context.pop()),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                color: BrandColors.white,
                borderRadius: Corners.sheet,
              ),
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.gutter,
                    Insets.xxl,
                    Insets.gutter,
                    Insets.xxxl,
                  ),
                  children: [
                    Text('Detalles del vehículo', style: text.headlineSmall),
                    const SizedBox(height: Insets.lg),
                    _VehicleTypePicker(
                      selected: draft.vehicle.type,
                      onChanged: (type) => ref
                          .read(requestControllerProvider.notifier)
                          .setVehicle(draft.vehicle.copyWith(type: type)),
                    ),
                    const SizedBox(height: Insets.lg),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _make,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(hintText: 'Marca'),
                            validator: (v) => (v?.trim().isEmpty ?? true)
                                ? 'Requerido'
                                : null,
                          ),
                        ),
                        const SizedBox(width: Insets.md),
                        Expanded(
                          child: TextFormField(
                            controller: _model,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(hintText: 'Modelo'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      controller: _plate,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        hintText: 'Placa (ej. A123456)',
                      ),
                    ),

                    const SizedBox(height: Insets.xxl),
                    Text('¿Qué le pasa?', style: text.headlineSmall),
                    const SizedBox(height: Insets.lg),
                    _ConditionPicker(
                      selected: draft.vehicle.condition,
                      onChanged: (condition) => ref
                          .read(requestControllerProvider.notifier)
                          .setVehicle(
                            draft.vehicle.copyWith(condition: condition),
                          ),
                    ),
                    const SizedBox(height: Insets.lg),
                    _TruckTypeNotice(truckType: draft.truckType),

                    const SizedBox(height: Insets.xxl),
                    Text('Fotos (opcional)', style: text.headlineSmall),
                    const SizedBox(height: Insets.xs),
                    Text(
                      'Ayudan al chofer a llegar preparado.',
                      style: text.bodyMedium?.copyWith(color: BrandColors.grey600),
                    ),
                    const SizedBox(height: Insets.lg),
                    _PhotoStrip(
                      paths: draft.photoPaths,
                      onAdd: () => ref
                          .read(requestControllerProvider.notifier)
                          .addPhoto('demo-${draft.photoPaths.length}'),
                      onRemove: (path) => ref
                          .read(requestControllerProvider.notifier)
                          .removePhoto(path),
                    ),

                    const SizedBox(height: Insets.xxl),
                    Text('¿Dónde estás?', style: text.headlineSmall),
                    const SizedBox(height: Insets.lg),
                    TextFormField(
                      controller: _pickup,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.my_location, color: BrandColors.red),
                        hintText: 'Dirección de recogida',
                      ),
                      validator: (v) => (v?.trim().isEmpty ?? true)
                          ? 'Necesitamos saber dónde estás.'
                          : null,
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      controller: _reference,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.push_pin_outlined,
                            color: BrandColors.grey400),
                        hintText: 'Referencia (frente al colmado, km 12…)',
                      ),
                      validator: (v) => (v?.trim().isEmpty ?? true)
                          ? 'Una referencia ayuda al chofer a encontrarte.'
                          : null,
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      controller: _dropoff,
                      decoration: const InputDecoration(
                        prefixIcon:
                            Icon(Icons.flag_outlined, color: BrandColors.ink),
                        hintText: '¿A dónde la llevamos?',
                      ),
                      validator: (v) => (v?.trim().isEmpty ?? true)
                          ? 'Indica el destino.'
                          : null,
                    ),

                    if (draft.failure != null) ...[
                      const SizedBox(height: Insets.xl),
                      InlineNotice(
                        message: draft.failure!.userMessage,
                        tone: NoticeTone.error,
                      ),
                    ],

                    const SizedBox(height: Insets.xxl),
                    ElevatedButton(
                      onPressed: draft.quoting ? null : _continue,
                      child: draft.quoting
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: BrandColors.white,
                              ),
                            )
                          : const Text('VER PRECIO'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 116,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const GruaLogo(size: 98, variant: GruaLogoVariant.onDark),
            Positioned(
              left: Insets.sm,
              top: 0,
              child: IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back, color: BrandColors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VehicleTypePicker extends StatelessWidget {
  const _VehicleTypePicker({required this.selected, required this.onChanged});

  final VehicleType selected;
  final ValueChanged<VehicleType> onChanged;

  static const List<(VehicleType, IconData)> _options = [
    (VehicleType.sedan, Icons.directions_car_outlined),
    (VehicleType.suv, Icons.airport_shuttle_outlined),
    (VehicleType.camioneta, Icons.local_shipping_outlined),
    (VehicleType.camion, Icons.fire_truck_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (type, icon) in _options) ...[
          Expanded(
            child: _ChoiceTile(
              icon: icon,
              label: type.label,
              selected: selected == type,
              onTap: () => onChanged(type),
            ),
          ),
          if (type != _options.last.$1) const SizedBox(width: Insets.sm),
        ],
      ],
    );
  }
}

class _ConditionPicker extends StatelessWidget {
  const _ConditionPicker({required this.selected, required this.onChanged});

  final VehicleCondition selected;
  final ValueChanged<VehicleCondition> onChanged;

  static const List<VehicleCondition> _options = [
    VehicleCondition.noArranca,
    VehicleCondition.gomaPinchada,
    VehicleCondition.sinCombustible,
    VehicleCondition.ruedasBloqueadas,
    VehicleCondition.accidentado,
    VehicleCondition.volcado,
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.sm,
      children: [
        for (final condition in _options)
          ChoiceChip(
            label: Text(condition.label),
            selected: selected == condition,
            onSelected: (_) => onChanged(condition),
            showCheckmark: false,
            selectedColor: BrandColors.redTint,
            backgroundColor: BrandColors.grey100,
            side: BorderSide(
              color: selected == condition
                  ? BrandColors.red
                  : Colors.transparent,
            ),
            labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: selected == condition
                      ? BrandColors.redDeep
                      : BrandColors.grey800,
                ),
          ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Corners.brMd,
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(vertical: Insets.md),
        decoration: BoxDecoration(
          color: selected ? BrandColors.redTint : BrandColors.grey100,
          borderRadius: Corners.brMd,
          border: Border.all(
            color: selected ? BrandColors.red : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 26,
              color: selected ? BrandColors.red : BrandColors.grey800,
            ),
            const SizedBox(height: Insets.xs),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: selected ? BrandColors.redDeep : BrandColors.grey800,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Explains which grúa is being sent and why, because the type drives the price
/// and a surprise on the invoice is worse than a sentence here.
class _TruckTypeNotice extends StatelessWidget {
  const _TruckTypeNotice({required this.truckType});

  final TruckType truckType;

  @override
  Widget build(BuildContext context) {
    final reason = switch (truckType) {
      TruckType.plataforma =>
        'Tu vehículo no puede rodar, así que enviamos una plataforma.',
      TruckType.pesada => 'Por el tamaño del vehículo enviamos una grúa pesada.',
      TruckType.gancho => 'Enviamos una grúa de gancho, la más económica.',
      TruckType.unknown => 'Definiremos el tipo de grúa según tu vehículo.',
    };

    return InlineNotice(
      message: '${truckType.label}. $reason',
      icon: Icons.local_shipping_outlined,
      tone: NoticeTone.info,
    );
  }
}

class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({
    required this.paths,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> paths;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  static const _max = 3;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: paths.length + (paths.length < _max ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: Insets.md),
        itemBuilder: (context, index) {
          if (index == paths.length) {
            return InkWell(
              onTap: onAdd,
              borderRadius: Corners.brMd,
              child: Container(
                width: 92,
                decoration: BoxDecoration(
                  color: BrandColors.grey100,
                  borderRadius: Corners.brMd,
                  border: Border.all(color: BrandColors.grey200),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_a_photo_outlined, color: BrandColors.grey600),
                    SizedBox(height: Insets.xs),
                    Text(
                      'Subir foto',
                      style: TextStyle(fontSize: 11, color: BrandColors.grey600),
                    ),
                  ],
                ),
              ),
            );
          }

          return Stack(
            children: [
              Container(
                width: 92,
                decoration: const BoxDecoration(
                  color: BrandColors.grey200,
                  borderRadius: Corners.brMd,
                ),
                child: const Icon(Icons.image_outlined, color: BrandColors.grey600),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: InkWell(
                  onTap: () => onRemove(paths[index]),
                  child: const CircleAvatar(
                    radius: 11,
                    backgroundColor: BrandColors.ink,
                    child: Icon(Icons.close, size: 13, color: BrandColors.white),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
