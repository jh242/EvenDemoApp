import 'package:demo_ai_even/services/glance_source.dart';
import 'package:flutter/services.dart';

/// Transit departures via Apple MapKit.
class TransitSource implements GlanceSource {
  static const _channel = MethodChannel('method.transit');

  @override
  String get name => 'transit';

  @override
  bool get enabled => true;

  @override
  Duration get cacheDuration => const Duration(minutes: 2);

  @override
  Future<String?> fetch() async {
    try {
      final result = await _channel.invokeMethod<String>('getNearbyDepartures');
      if (result == null || result.isEmpty) return null;
      return 'Transit: $result';
    } on MissingPluginException {
      return null;
    } catch (e) {
      print('TransitSource error: $e');
      return null;
    }
  }
}
