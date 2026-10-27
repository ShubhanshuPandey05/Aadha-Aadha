import 'dart:convert';
import 'package:flutter/services.dart';

class NativeBridge {
  static const channel = MethodChannel('two_tally/native');
  static Future<Map<String, dynamic>> call(String method,
      [Map<String, dynamic>? arguments]) async {
    final raw = await channel.invokeMethod<String>(method, arguments);
    return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }
}
