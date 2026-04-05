import 'package:demo_ai_even/services/glance_source.dart';
import 'package:flutter/services.dart';

class LocationSource implements GlanceSource {
  static const _channel = MethodChannel('method.location');

  @override
  String get name => 'location';

  @override
  bool get enabled => true;

  @override
  Duration get cacheDuration => const Duration(seconds: 60);

  @override
  Future<String?> fetch() async {
    try {
      final perm = await _channel.invokeMethod<String>('checkPermission');
      if (perm == 'notDetermined') {
        await _channel.invokeMethod('requestPermission');
        // Permission dialog shown — skip this cycle.
        return null;
      }
      if (perm == 'denied') return null;

      final pos = await _channel.invokeMethod<Map>('getCurrentPosition');
      if (pos == null) return null;

      final lat = pos['latitude'] as double;
      final lon = pos['longitude'] as double;

      final geo = await _channel.invokeMethod<Map>(
        'reverseGeocode',
        {'latitude': lat, 'longitude': lon},
      );

      if (geo != null) {
        final placeName = geo['placeName'] as String? ?? '';
        if (placeName.isNotEmpty) {
          return 'Location: $placeName';
        }
      }

      return 'Location: ${lat.toStringAsFixed(2)}, ${lon.toStringAsFixed(2)}';
    } on PlatformException catch (e) {
      print('LocationSource error: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
