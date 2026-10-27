import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:two_tally/main.dart';
import 'package:two_tally/realtime_sync.dart';

class FakeRealtime extends LedgerRealtime {
  @override
  Future<void> start(String group, void Function() changed,
      void Function(bool) connection) async {
    connection(true);
  }

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('ledger, monthly summary and settings render on a compact phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final packages = jsonDecode(
          await File('.dart_tool/package_config.json').readAsString()) as Map;
      final flutter = (packages['packages'] as List)
          .firstWhere((p) => p['name'] == 'flutter');
      final sdk = Uri.parse('${flutter['rootUri']}/').resolve('../../');
      final font = FontLoader('Roboto');
      for (final variant in ['regular', 'bold']) {
        font.addFont(File.fromUri(sdk.resolve(
                'bin/cache/artifacts/material_fonts/roboto-$variant.ttf'))
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)));
      }
      await font.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    final group = {'id': 'group', 'name': 'Our everyday', 'ready': true};
    final snapshot = {
      'group': group,
      'members': [
        {
          'id': 'a',
          'name': 'Asha',
          'contributed': 35000,
          'share': 24500,
          'balance': 10500
        },
        {
          'id': 'b',
          'name': 'Riya',
          'contributed': 10000,
          'share': 20500,
          'balance': -10500
        },
      ],
      'month': {'start': '2026-09-30T18:30:00Z', 'total': 45000, 'count': 2},
      'expenses': [
        {
          'id': '1',
          'payer_id': 'a',
          'amount_paise': 35000,
          'payer_share_paise': 17500,
          'kind': 'expense',
          'recipient': 'Coffee & conversation',
          'occurred_at': '2026-10-27T09:00:00Z',
          'source': 'manual'
        },
        {
          'id': '2',
          'payer_id': 'b',
          'amount_paise': 10000,
          'payer_share_paise': 3000,
          'kind': 'expense',
          'recipient': 'Ride home',
          'occurred_at': '2026-10-26T12:00:00Z',
          'source': 'manual'
        },
      ]
    };
    const channel = MethodChannel('two_tally/native');
    var listenerConnected = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') {
        return jsonEncode({
          'configured': true,
          'user_id': 'a',
          'group': group,
          'pending': [],
          'listener': true,
          'listener_connected': listenerConnected,
          'notifications': true,
          'detection': true,
          'firebase': true
        });
      }
      if (call.method == 'reconnectListener') listenerConnected = true;
      if (call.method == 'snapshot') return jsonEncode(snapshot);
      return '{}';
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: TwoTallyApp(home: HomeScreen(sync: FakeRealtime()))));
    await tester.runAsync(() => precacheImage(
        const AssetImage('assets/branding/aadha-aadha-logo.png'),
        tester.element(find.byType(HomeScreen))));
    await tester.pumpAndSettle();
    expect(find.text('₹105.00'), findsOneWidget);
    expect(find.text('Coffee & conversation'), findsOneWidget);
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('artifacts/previews/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('ledger');
    await tester.tap(find.text('Summary'));
    await tester.pumpAndSettle();
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('₹450.00'), findsOneWidget);
    await capture('summary');
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Detect payment notifications'), findsOneWidget);
    await capture('settings');
    expect(find.text('Payment listener disconnected'), findsOneWidget);
    await tester.ensureVisible(find.text('Reconnect'));
    await tester.tap(find.text('Reconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Payment listener connected'), findsOneWidget);
    expect(find.text('Payment listener disconnected'), findsNothing);
    debugDisableShadows = true;
    await tester.pumpWidget(const SizedBox());
  });
}
