import 'package:speed_test_dart/classes/classes.dart';
import 'package:xml/xml.dart';

class Server {
  Server(
    this.id,
    this.name,
    this.country,
    this.sponsor,
    this.host,
    this.url,
    this.latitude,
    this.longitude,
    this.distance,
    this.latency,
    this.geoCoordinate,
  );

  Server.fromXMLElement(XmlElement? element) {
    if (element == null) {
      throw ArgumentError('XML element cannot be null');
    }

    final idStr = element.getAttribute('id');
    final latStr = element.getAttribute('lat');
    final lonStr = element.getAttribute('lon');

    if (idStr == null || latStr == null || lonStr == null) {
      throw ArgumentError('Required attributes (id, lat, lon) are missing');
    }

    id = int.parse(idStr);
    name = element.getAttribute('name') ?? '';
    country = element.getAttribute('country') ?? '';
    sponsor = element.getAttribute('sponsor') ?? '';
    host = element.getAttribute('host') ?? '';
    url = element.getAttribute('url') ?? '';
    latitude = double.parse(latStr);
    longitude = double.parse(lonStr);
    distance = 99999999999;
    latency = 99999999999;
    geoCoordinate = Coordinate(latitude, longitude);
  }

  late int id;
  late String name;
  late String country;
  late String sponsor;
  late String host;
  late String url;
  late double latitude;
  late double longitude;
  late double distance;
  late double latency;
  late Coordinate geoCoordinate;
}

class ServersList {
  ServersList(this.servers);

  ServersList.fromXMLElement(XmlElement? element) {
    if (element == null) {
      servers = <Server>[];
      return;
    }

    final serversElement = element.getElement('servers');
    if (serversElement == null) {
      servers = <Server>[];
      return;
    }

    try {
      servers = serversElement.children
          .where((child) => child is XmlElement) // Sadece XmlElement'leri filtrele
          .cast<XmlElement>()
          .map((xmlElement) {
            try {
              return Server.fromXMLElement(xmlElement);
            } catch (e) {
              print('Error parsing server element: $e');
              return null;
            }
          })
          .where((server) => server != null) // Null değerleri filtrele
          .cast<Server>()
          .toList();
    } catch (e) {
      print('Error parsing servers: $e');
      servers = <Server>[];
    }
  }

  late List<Server> servers;

  void calculateDistances(Coordinate clientCoordinate) {
    for (final s in servers) {
      s.distance = clientCoordinate.getDistanceTo(s.geoCoordinate);
    }
  }
}
