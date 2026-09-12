/// Off the web there is no Maps script on a page; the platform geocoder in
/// `LocationService.describe` is the only one, and it works there.
Future<String?> scriptReverseGeocode(double latitude, double longitude) async =>
    null;
