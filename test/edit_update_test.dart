import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:two_tally/forms.dart';
import 'package:two_tally/main.dart';
import 'package:two_tally/realtime_sync.dart';

class NoRealtime extends LedgerRealtime {
  @override
  Future<void> start(String group, void Function() changed,
      void Function(bool) connection) async {}
  @override
  Future<void> stop() async {}
}

void main() {
  const channel = MethodChannel('two_tally/native');
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  final entry = <String, dynamic>{
    'id': 'expense',
    'payer_id': 'me',
    'payer_name': 'Me',
    'amount_paise': 35000,
    'payer_share_paise': 10000,
    'revision': 2,
    'name': 'Food',
    'recipient': 'Cafe',
    'kind': 'expense',
    'source': 'manual',
    'occurred_at': '2026-10-27T09:00:00Z',
    'history': [],
  };
  testWidgets(
      'editing preserves custom share and retries the same request after a timeout',
      (tester) async {
    final calls = <Map<dynamic, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'editExpense') {
        calls.add(call.arguments as Map);
        throw PlatformException(
            code: 'network', message: 'Connection lost. Retry.');
      }
      return '{}';
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ExpenseEditor(friend: 'Friend', entry: entry))));
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('100.00'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Name (optional)'), 'Dinner');
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(calls.length, 2);
    expect(calls[0], calls[1]);
    expect(calls[0]['p_expected_revision'], 2);
    expect(calls[0]['p_payer_share_paise'], 10000);
    expect(calls[0]['p_name'], 'Dinner');
    expect(calls[0].containsKey('payer_id'), false);
  });
  for (final own in [true, false]) {
    testWidgets(
        'edit control is ${own ? 'shown for own' : 'hidden for friend'} entry',
        (tester) async {
      final row = {...entry, 'payer_id': own ? 'me' : 'friend'};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') {
          return jsonEncode(
              {'configured': true, 'user_id': 'me', 'pending': []});
        }
        if (call.method == 'snapshot') {
          return jsonEncode({
            'group': {'id': 'group', 'ready': true, 'name': 'Our ledger'},
            'members': [
              {
                'id': 'me',
                'name': 'Me',
                'balance': 0,
                'share': 0,
                'contributed': 0
              },
              {
                'id': 'friend',
                'name': 'Friend',
                'balance': 0,
                'share': 0,
                'contributed': 0
              }
            ],
            'expenses': [row],
            'month': {'total': 35000, 'count': 1}
          });
        }
        if (call.method == 'expense') return jsonEncode(row);
        return '{}';
      });
      await tester
          .pumpWidget(TwoTallyApp(home: HomeScreen(sync: NoRealtime())));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Food'));
      await tester.pumpAndSettle();
      expect(find.text('Edit your entry'), own ? findsOneWidget : findsNothing);
      expect(find.text('Entry history'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'automatic update check offers release and Later never starts download',
      (tester) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'status') {
        return '{"configured":false,"user_id":"","pending":[]}';
      }
      if (call.method == 'checkUpdate') {
        return '{"available":true,"version":"1.0.9","size":8100000,"current":"1.0.8"}';
      }
      return '{}';
    });
    await tester.pumpWidget(const TwoTallyApp());
    await tester.pumpAndSettle();
    expect(find.text('Update to 1.0.9'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'checkUpdate').length, 1);
    expect(calls.contains('installUpdate'), false);
    await tester.pumpWidget(const SizedBox());
  });
}
