library speed_test_dart;

import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:speed_test_dart/classes/classes.dart';
import 'package:speed_test_dart/constants.dart';
import 'package:speed_test_dart/enums/file_size.dart';
import 'package:sync/sync.dart';
import 'package:xml/xml.dart';

typedef void DoneCallback(double transferRate);
typedef void ProgressCallback(double transferRate);
typedef void ErrorCallback(String errorMessage);

/// A Speed tester.
class SpeedTestDart {
  /// Returns [Settings] from speedtest.net.
  Future<Settings> getSettings() async {
    final headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.5',
      'Accept-Encoding': 'gzip, deflate',
      'Connection': 'keep-alive',
      'Upgrade-Insecure-Requests': '1',
    };

    try {
      final response = await http.get(
        Uri.parse(configUrl),
        headers: headers,
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP Error: ${response.statusCode}');
      }

      // XML parsing ile güvenli element arama
      final xmlDoc = XmlDocument.parse(response.body);
      XmlElement? settingsElement;

      if (xmlDoc.rootElement.name.local == 'settings') {
        settingsElement = xmlDoc.rootElement;
      } else {
        settingsElement = xmlDoc.rootElement.getElement('settings');
      }

      if (settingsElement == null) {
        throw Exception('Settings element not found in XML response');
      }

      final settings = Settings.fromXMLElement(settingsElement);

      var serversConfig = ServersList(<Server>[]);
      for (final element in serversUrls) {
        if (serversConfig.servers.isNotEmpty) break;
        try {
          final resp = await http.get(Uri.parse(element), headers: headers);

          if (resp.statusCode == 200) {
            final serverXmlDoc = XmlDocument.parse(resp.body);
            XmlElement? serverSettingsElement;

            if (serverXmlDoc.rootElement.name.local == 'settings') {
              serverSettingsElement = serverXmlDoc.rootElement;
            } else {
              serverSettingsElement = serverXmlDoc.rootElement.getElement('settings');
            }

            if (serverSettingsElement != null) {
              serversConfig = ServersList.fromXMLElement(serverSettingsElement);
            }
          }
        } catch (ex) {
          print('Error fetching server config from $element: $ex');
          serversConfig = ServersList(<Server>[]);
        }
      }

      final ignoredIds = settings.serverConfig.ignoreIds.split(',');
      serversConfig.calculateDistances(settings.client.geoCoordinate);
      settings.servers = serversConfig.servers.where((s) => !ignoredIds.contains(s.id.toString())).toList();
      settings.servers.sort((a, b) => a.distance.compareTo(b.distance));

      return settings;
    } catch (e) {
      print('Error in getSettings: $e');
      rethrow;
    }
  }

  /// Returns a List[Server] with the best servers, ordered
  /// by lowest to highest latency.
  Future<List<Server>> getBestServers({
    required List<Server> servers,
    int retryCount = 2,
    int timeoutInSeconds = 2,
  }) async {
    List<Server> serversToTest = [];

    for (final server in servers) {
      final latencyUri = createTestUrl(server, 'latency.txt');
      final stopwatch = Stopwatch();

      stopwatch.start();
      try {
        await http.get(latencyUri).timeout(
              Duration(
                seconds: timeoutInSeconds,
              ),
              onTimeout: (() => http.Response(
                    '999999999',
                    500,
                  )),
            );
        // If a server fails the request, continue in the iteration
      } catch (_) {
        continue;
      } finally {
        stopwatch.stop();
      }

      final latency = stopwatch.elapsedMilliseconds / retryCount;
      if (latency < 500) {
        server.latency = latency;
        serversToTest.add(server);
      }
    }

    serversToTest.sort((a, b) => a.latency.compareTo(b.latency));

    return serversToTest;
  }

  /// Creates [Uri] from [Server] and [String] file
  Uri createTestUrl(Server server, String file) {
    return Uri.parse(
      Uri.parse(server.url).toString().replaceAll('upload.php', file),
    );
  }

  /// Returns urls for download test.
  List<String> generateDownloadUrls(
    Server server,
    int retryCount,
    List<FileSize> downloadSizes,
  ) {
    final downloadUriBase = createTestUrl(server, 'random{0}x{0}.jpg?r={1}');
    final result = <String>[];
    for (final ds in downloadSizes) {
      for (var i = 0; i < retryCount; i++) {
        result.add(
          downloadUriBase.toString().replaceAll('%7B0%7D', FILE_SIZE_MAPPING[ds].toString()).replaceAll('%7B1%7D', i.toString()),
        );
      }
    }
    return result;
  }

  double getSpeed(List<int> tasks, int elapsedMilliseconds) {
    final _totalSize = tasks.reduce((a, b) => a + b);
    return (_totalSize * 8 / 1024) / (elapsedMilliseconds / 1000) / 1000;
  }

  /// Returns [double] downloaded speed in MB/s.
  Future<void> testDownloadSpeed({
    required List<Server> servers,
    int simultaneousDownloads = 2,
    int retryCount = 3,
    List<FileSize> downloadSizes = defaultDownloadSizes,
    required ProgressCallback onProgress,
    required DoneCallback onDone,
    required ErrorCallback onError,
  }) async {
    try {
      double downloadSpeed = 0;

      // Iterates over all servers, if one request fails, the next one is tried.
      for (final s in servers) {
        final testData = generateDownloadUrls(s, retryCount, downloadSizes);
        final semaphore = Semaphore(simultaneousDownloads);
        final tasks = <int>[];
        final stopwatch = Stopwatch()..start();

        try {
          await Future.forEach(testData, (String td) async {
            await semaphore.acquire();
            try {
              final data = await http.get(Uri.parse(td));
              tasks.add(data.bodyBytes.length);
              onProgress(
                getSpeed(
                  tasks,
                  stopwatch.elapsedMilliseconds,
                ),
              );
            } finally {
              semaphore.release();
            }
          });
          stopwatch.stop();
          downloadSpeed = getSpeed(tasks, stopwatch.elapsedMilliseconds);

          break;
        } catch (_) {
          continue;
        }
      }
      onDone(downloadSpeed);
    } catch (e) {
      onError(e.toString());
    }
  }

  /// Returns [double] upload speed in MB/s.
  Future<void> testUploadSpeed({
    required List<Server> servers,
    int simultaneousUploads = 2,
    int retryCount = 3,
    required ProgressCallback onProgress,
    required DoneCallback onDone,
    required ErrorCallback onError,
  }) async {
    try {
      double uploadSpeed = 0;
      for (var s in servers) {
        final testData = generateUploadData(retryCount);
        final semaphore = Semaphore(simultaneousUploads);
        final stopwatch = Stopwatch()..start();
        final tasks = <int>[];

        try {
          await Future.forEach(testData, (String td) async {
            await semaphore.acquire();
            try {
              // do post request to measure time for upload
              await http.post(Uri.parse(s.url), body: td);
              tasks.add(td.length);
              onProgress(
                getSpeed(
                  tasks,
                  stopwatch.elapsedMilliseconds,
                ),
              );
            } finally {
              semaphore.release();
            }
          });
          stopwatch.stop();
          uploadSpeed = getSpeed(tasks, stopwatch.elapsedMilliseconds);

          break;
        } catch (_) {
          continue;
        }
      }
      onDone(uploadSpeed);
    } catch (e) {
      onError(e.toString());
    }
  }

  /// Generate list of [String] urls for upload.
  List<String> generateUploadData(int retryCount) {
    final random = Random();
    final result = <String>[];

    for (var sizeCounter = 1; sizeCounter < maxUploadSize + 1; sizeCounter++) {
      final size = sizeCounter * 200 * 1024;
      final builder = StringBuffer()..write('content ${sizeCounter.toString()}=');

      for (var i = 0; i < size; ++i) {
        builder.write(hars[random.nextInt(hars.length)]);
      }

      for (var i = 0; i < retryCount; i++) {
        result.add(builder.toString());
      }
    }

    return result;
  }
}
