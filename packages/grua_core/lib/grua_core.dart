/// Shared domain, data and design layer for the three Grúas RD 24/7 products.
///
/// The client app, the driver app and the admin panel all depend on this
/// package and on nothing else in common. Anything that must behave the same
/// way in more than one of them — the service state machine, the pricing
/// formula, money formatting, the brand — lives here so it cannot drift.
library;

// Configuration and startup
export 'src/bootstrap.dart';
// Chat — the screens both the customer and the chofer app show as-is
export 'src/calls/call_controller.dart';
export 'src/calls/call_layer.dart';
export 'src/calls/voice_call.dart';
export 'src/calls/voice_transport.dart';
export 'src/chat/request_chat_screen.dart';
export 'src/chat/service_chat_screen.dart';
export 'src/config/app_config.dart';

// Data layer
export 'src/data/converters.dart';
export 'src/data/demo/demo_backend.dart';
export 'src/data/demo/demo_repositories.dart';
export 'src/data/firebase/firebase_bootstrap.dart';
export 'src/data/firebase/firebase_repositories.dart';
export 'src/data/firebase/functions_gateway.dart';
export 'src/data/paths.dart';
export 'src/data/pricing.dart';

// Domain layer
export 'src/domain/enums.dart';
export 'src/domain/failures.dart';
export 'src/domain/models/app_user.dart';
export 'src/domain/models/billing.dart';
export 'src/domain/models/chat_prefs.dart';
export 'src/domain/models/chat_request.dart';
export 'src/domain/models/dispatch_models.dart';
export 'src/domain/models/driver.dart';
export 'src/domain/models/remote_config_models.dart';
export 'src/domain/models/service.dart';
export 'src/domain/models/truck.dart';
export 'src/domain/repositories.dart';
export 'src/domain/value_objects.dart';

// Location
export 'src/location/geohash.dart';
export 'src/location/location_service.dart';
export 'src/location/my_position.dart';
export 'src/location/places_service.dart';
export 'src/location/polyline.dart';
export 'src/location/route_service.dart';

// Media — photos a form or a chat sends
export 'src/media/photo_picker.dart';

// Dependency wiring
export 'src/providers.dart';

// Design system
export 'src/theme/app_theme.dart';
export 'src/theme/brand.dart';
export 'src/theme/widgets/brand_widgets.dart';
export 'src/theme/widgets/driver_avatar.dart';
export 'src/theme/widgets/grua_logo.dart';
export 'src/theme/widgets/grua_map.dart';
export 'src/theme/widgets/notification_banner.dart';
export 'src/theme/widgets/schematic_map.dart';

// Utilities
export 'src/utils/date_time_do.dart';
export 'src/utils/do_validators.dart';
export 'src/utils/money.dart';
