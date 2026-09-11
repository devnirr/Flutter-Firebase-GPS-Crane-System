import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:image_picker/image_picker.dart';

import '../../router.dart';
import 'location_picker_screen.dart';
import 'quote_sheet.dart';
import 'request_controller.dart';

/// The request form.
///
/// Red header with the mark, then one white sheet carrying every field, exactly
/// as in the mockup. The order matters: vehicle, then problem, then photos,
/// then where — a stranded customer can answer the first three from memory, and
/// the address is the one that needs them to look around.
class RequestScreen extends ConsumerStatefulWidget {
  const RequestScreen({this.preferredTruck, super.key});

  /// Set when the form was opened from "Pedir esta grúa" on the home map.
  final PreferredTruck? preferredTruck;

  @override
  ConsumerState<RequestScreen> createState() => _RequestScreenState();
}

class _RequestScreenState extends ConsumerState<RequestScreen> {
  final _formKey = GlobalKey<FormState>();
  final _picker = ImagePicker();
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
    // After the first frame: a provider may not be changed mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref
            .read(requestControllerProvider.notifier)
            .setPreferredTruck(widget.preferredTruck);
      }
    });
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

  /// Opens the map picker and folds the result back into the draft.
  Future<void> _pickLocation({required bool isPickup}) async {
    final draft = ref.read(requestControllerProvider);
    final picked = await Navigator.of(context).push<ServiceLocation>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          title: isPickup ? '¿Dónde estás?' : '¿A dónde la llevamos?',
          initial: isPickup ? draft.pickup : draft.dropoff,
          requireReference: isPickup,
        ),
      ),
    );
    if (picked == null || !mounted) return;

    final controller = ref.read(requestControllerProvider.notifier);
    if (isPickup) {
      controller.setPickup(picked);
      _pickup.text = picked.address;
      _reference.text = picked.reference;
    } else {
      controller.setDropoff(picked);
      _dropoff.text = picked.address;
    }
  }

  /// Folds any address text the customer edited by hand back onto the point
  /// they already chose on the map.
  void _syncLocations() {
    final controller = ref.read(requestControllerProvider.notifier);
    final draft = ref.read(requestControllerProvider);

    final pickup = draft.pickup;
    if (pickup != null) {
      controller.setPickup(
        pickup.copyWith(
          address: _pickup.text.trim(),
          reference: _reference.text.trim(),
        ),
      );
    }

    final dropoff = draft.dropoff;
    if (dropoff != null) {
      controller.setDropoff(dropoff.copyWith(address: _dropoff.text.trim()));
    }
  }

  Future<void> _continue() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final chosen = ref.read(requestControllerProvider);
    if (chosen.pickup == null) {
      _showMissing('Marca dónde estás para poder enviarte la grúa.');
      return;
    }
    if (chosen.dropoff == null) {
      _showMissing('Marca a dónde llevamos el vehículo.');
      return;
    }
    if (chosen.pickup!.reference.trim().isEmpty) {
      _showMissing('Escribe una referencia del punto de recogida.');
      return;
    }

    _syncVehicle();
    _syncLocations();

    final controller = ref.read(requestControllerProvider.notifier);
    await controller.requestQuote();
    if (!mounted) return;

    if (ref.read(requestControllerProvider).quote == null) return;

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

  /// Asks where the photo comes from, then hands the picked file to the draft.
  ///
  /// The picker is capped well below full sensor resolution on purpose: these
  /// photos exist so a chofer knows what he is driving to, and a 12-megapixel
  /// original is a slow upload from a roadside with one bar for no extra
  /// information.
  Future<void> _addPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _PhotoSourceSheet(),
    );
    if (source == null || !mounted) return;

    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 80,
      );
      if (file == null || !mounted) return;
      ref.read(requestControllerProvider.notifier).addPhoto(file.path);
    } on PlatformException {
      // Almost always a denied camera or photos permission. There is nothing
      // to retry in-app, so say what to fix.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No pudimos abrir la cámara ni la galería. Revisa los permisos.',
          ),
        ),
      );
    }
  }

  void _showMissing(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
                    if (draft.preferredTruck case final chosen?) ...[
                      _PreferredTruckNotice(
                        chosen: chosen,
                        needed: draft.truckType,
                        onRemove: () => ref
                            .read(requestControllerProvider.notifier)
                            .setPreferredTruck(null),
                      ),
                      const SizedBox(height: Insets.lg),
                    ],
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
                      onAdd: _addPhoto,
                      onRemove: (path) => ref
                          .read(requestControllerProvider.notifier)
                          .removePhoto(path),
                    ),

                    const SizedBox(height: Insets.xxl),
                    Text('¿Dónde estás?', style: text.headlineSmall),
                    const SizedBox(height: Insets.lg),
                    _LocationField(
                      icon: Icons.my_location,
                      iconColor: BrandColors.red,
                      label: 'Punto de recogida',
                      value: draft.pickup?.address ?? '',
                      reference: draft.pickup?.reference ?? '',
                      hint: 'Toca para marcarlo en el mapa',
                      onTap: () => _pickLocation(isPickup: true),
                    ),
                    const SizedBox(height: Insets.md),
                    _LocationField(
                      icon: Icons.flag_outlined,
                      iconColor: BrandColors.ink,
                      label: 'Destino',
                      value: draft.dropoff?.address ?? '',
                      hint: '¿A dónde la llevamos?',
                      onTap: () => _pickLocation(isPickup: false),
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

  /// How far the arrow sits in from the edge of the screen.
  static const double _backInset = Insets.lg;

  /// The inset plus the button's tap target, mirrored on the right so the
  /// mark stays centred.
  static const double _backSlotWidth = _backInset + kMinInteractiveDimension;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 116,
        // A Row, not a Stack: the button owns the left end of the banner
        // outright, so it can never end up floating over the mark however the
        // logo is sized. The Row centres its children vertically, which is
        // what puts the button level with the middle of the banner.
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: _backInset),
              child: IconButton(
                onPressed: onBack,
                iconSize: 30,
                icon: const Icon(Icons.arrow_back, color: BrandColors.white),
              ),
            ),
            const Expanded(child: Center(child: GruaLogo(size: 98))),
            // Balances the button, so the mark sits on the true centre of the
            // screen rather than being pushed right by it.
            const SizedBox(width: _backSlotWidth),
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
                clipBehavior: Clip.antiAlias,
                child: _PhotoThumb(path: paths[index]),
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

/// A tappable summary of a chosen point.
///
/// Not a text field: a typed address with no coordinates behind it cannot be
/// dispatched to, so the only way to set a location is the map.
class _LocationField extends StatelessWidget {
  const _LocationField({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.hint,
    required this.onTap,
    this.reference = '',
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String reference;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final chosen = value.isNotEmpty;

    return Material(
      color: BrandColors.white,
      borderRadius: Corners.brMd,
      child: InkWell(
        onTap: onTap,
        borderRadius: Corners.brMd,
        child: Container(
          padding: const EdgeInsets.all(Insets.lg),
          decoration: BoxDecoration(
            borderRadius: Corners.brMd,
            border: Border.all(
              color: chosen ? BrandColors.grey200 : BrandColors.redTintStrong,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 20),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FieldLabel(label),
                    const SizedBox(height: 2),
                    Text(
                      chosen ? value : hint,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: chosen
                          ? text.titleSmall
                          : text.bodyMedium
                              ?.copyWith(color: BrandColors.grey400),
                    ),
                    if (reference.isNotEmpty)
                      Text(
                        reference,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            text.bodySmall?.copyWith(color: BrandColors.grey600),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: BrandColors.grey400),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where a photo comes from.
///
/// Two options, both one tap. Somebody standing next to a broken car in
/// traffic is not going to work through a menu, and the camera comes first
/// because photographing the car in front of them is the common case.
/// Says the chosen truck gets the job first, and when it cannot: a vehicle
/// that needs a different kind of grúa than the one picked.
class _PreferredTruckNotice extends StatelessWidget {
  const _PreferredTruckNotice({
    required this.chosen,
    required this.needed,
    required this.onRemove,
  });

  final PreferredTruck chosen;
  final TruckType needed;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final fits = chosen.truckType == needed;
    return InlineNotice(
      key: const Key('preferred-truck-notice'),
      icon: fits ? Icons.local_shipping_outlined : Icons.info_outline,
      tone: fits ? NoticeTone.success : NoticeTone.warning,
      message: fits
          ? 'Le ofreceremos primero tu servicio a la grúa que elegiste en el '
              'mapa (${chosen.truckType.label}). Si no acepta, buscamos otra.'
          : 'Elegiste una grúa ${chosen.truckType.label}, pero tu vehículo '
              'necesita ${needed.label}. Buscaremos la grúa adecuada más cercana.',
      actionLabel: 'Quitar',
      onAction: onRemove,
    );
  }
}

class _PhotoSourceSheet extends StatelessWidget {
  const _PhotoSourceSheet();

  @override
  Widget build(BuildContext context) {
    return BottomActionSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Agregar foto',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: Insets.md),
          ListTile(
            leading: const Icon(
              Icons.photo_camera_outlined,
              color: BrandColors.red,
            ),
            title: const Text('Cámara'),
            onTap: () => Navigator.of(context).pop(ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(
              Icons.photo_library_outlined,
              color: BrandColors.red,
            ),
            title: const Text('Galería'),
            onTap: () => Navigator.of(context).pop(ImageSource.gallery),
          ),
        ],
      ),
    );
  }
}

/// A picked photo, read once and kept.
///
/// The bytes come through [XFile] rather than `Image.file` so there is one code
/// path: image_picker returns a filesystem path on a phone and a blob URL in a
/// browser, and `dart:io` cannot be imported into a web build at all. At three
/// photos capped at 1600px this costs little and saves a conditional import.
class _PhotoThumb extends StatefulWidget {
  const _PhotoThumb({required this.path});

  final String path;

  @override
  State<_PhotoThumb> createState() => _PhotoThumbState();
}

class _PhotoThumbState extends State<_PhotoThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bytes = await XFile(widget.path).readAsBytes();
      if (mounted) setState(() => _bytes = bytes);
    } on Object {
      // A thumbnail that will not decode is not worth an error message to
      // somebody waiting on a tow. The placeholder icon stays put.
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return const Icon(Icons.image_outlined, color: BrandColors.grey600);
    }
    return Image.memory(bytes, width: 92, height: 92, fit: BoxFit.cover);
  }
}
