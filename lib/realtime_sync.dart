import 'dart:async';
import 'package:realtime_client/realtime_client.dart';
import 'native_bridge.dart';

class LedgerRealtime {
  RealtimeClient? _client;
  String? _group;
  Timer? _authTimer;
  Future<void> start(String group, void Function() changed,
      void Function(bool) connection) async {
    if (_group == group) return;
    await stop();
    final config = await NativeBridge.call('realtime');
    final client = RealtimeClient(config['url'] + '/realtime/v1',
        params: {'apikey': config['key']},
        customAccessToken: () async =>
            (await NativeBridge.call('realtime'))['token'] as String);
    _client = client;
    _group = group;
    await client.setAuth(config['token'] as String);
    final channel = client.channel('ledger:$group');
    for (final table in ['expenses', 'group_members']) {
      channel.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'group_id',
              value: group),
          callback: (_) => changed());
    }
    channel.subscribe((status, error) {
      final ready = status == RealtimeSubscribeStatus.subscribed;
      connection(ready);
      if (ready) changed();
    });
    _authTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
      try {
        final refreshed = await NativeBridge.call('realtime');
        if (_client == client) {
          await client.setAuth(refreshed['token'] as String);
        }
      } catch (_) {
        connection(false);
      }
    });
  }

  Future<void> stop() async {
    _authTimer?.cancel();
    final client = _client;
    _client = null;
    _group = null;
    if (client != null) await client.disconnect();
  }
}
