/// How Google's own tiles are painted under our markers.
///
/// Only the dark skin needs one: by default the map is Google's daylight
/// style, which is what the light panel and both phone apps want. On a dark
/// panel that same map is a white rectangle in the middle of the screen, so
/// the panel hands Google this style instead. The markers, the route and the
/// legend colours are ours and are unaffected by it.
abstract final class MapStyles {
  /// A night map built to sit under the Grúas markers: near-black land, roads
  /// a step lighter so a route still reads, and no points of interest
  /// competing with the trucks.
  static const String dark = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1b1c20"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#9a9490"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#121316"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#3a3a40"}]},
  {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#c4bebb"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#2b2d33"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#1b1c20"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8e8886"}]},
  {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#33363d"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#454950"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#222429"}]},
  {"featureType":"road.local","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0e1013"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#4a5158"}]}
]
''';
}
