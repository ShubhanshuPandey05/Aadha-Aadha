import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:two_tally/main.dart';
import 'package:two_tally/forms.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('two_tally/native');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  testWidgets('unconfigured build explains setup without fake ledger data',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return jsonEncode(call.method == 'status'
          ? {'configured': false, 'user_id': '', 'pending': []}
          : <String, dynamic>{});
    });
    await tester.pumpWidget(const TwoTallyApp());
    await tester.pumpAndSettle();
    expect(find.text('This build is not connected yet.'), findsOneWidget);
    expect(find.text('Add expense'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('invalid custom share does not queue a write', (tester) async {
    var writes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'queue') writes++;
      return '{}';
    });
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ExpenseEditor(friend: 'Riya'))));
    await tester.enterText(find.byType(TextField).first, '350');
    await tester.tap(find.text('Custom split'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '351');
    await tester.ensureVisible(find.text('Confirm shared expense'));
    await tester.tap(find.text('Confirm shared expense'));
    await tester.pump();
    expect(writes, 0);
    expect(find.textContaining('Your share must be'), findsOneWidget);
  });
  testWidgets('Google sign-in opens native auth without requiring a password',
      (tester) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return '{"started":true}';
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AuthScreen(
      configured: true,
      onSignedIn: () async {},
    ))));
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(calls, ['googleSignIn']);
    expect(find.textContaining('Complete Google sign-in'), findsOneWidget);
  });
}
