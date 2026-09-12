/// Off the web there is no page to load a script into; the native SDKs take
/// their key from the platform build instead.
bool get googleMapsScriptLoaded => false;

/// Off the web the key comes from the platform build, not a script tag.
String get googleMapsScriptKey => '';
