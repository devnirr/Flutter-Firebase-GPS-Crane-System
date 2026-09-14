/// Road routes through the page's Maps script, where there is one.
library;

export 'script_router_stub.dart'
    if (dart.library.js_interop) 'script_router_web.dart';
