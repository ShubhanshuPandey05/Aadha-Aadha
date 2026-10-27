import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'native_bridge.dart';
import 'ledger.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen(
      {super.key,
      required this.configured,
      required this.onSignedIn,
      this.existingOnly = false});
  final bool configured, existingOnly;
  final Future<void> Function() onSignedIn;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final email = TextEditingController(),
      password = TextEditingController(),
      name = TextEditingController();
  bool signup = false, busy = false;
  String? error, notice;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!email.text.contains('@') ||
        password.text.length < 8 ||
        (signup && name.text.trim().isEmpty)) {
      setState(() => error =
          'Enter your email, an 8+ character password, and a name when creating an account.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final result = await NativeBridge.call('auth', {
        'email': email.text.trim(),
        'password': password.text,
        'name': name.text.trim(),
        'signup': signup,
      });
      if (result['signed_in'] == true) {
        await widget.onSignedIn();
      } else if (mounted) {
        setState(() {
          notice =
              'Check your email to confirm your account, then sign in here.';
          signup = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e is PlatformException
            ? e.message
            : 'Could not sign in. Please try again.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> googleSignIn() async {
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await NativeBridge.call('googleSignIn');
      if (mounted) {
        setState(() => notice =
            'Complete Google sign-in in your browser. You will return here automatically.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e is PlatformException
            ? e.message
            : 'Could not start Google sign-in.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
          padding: EdgeInsets.fromLTRB(
              28, 32, 28, 24 + MediaQuery.viewInsetsOf(context).bottom),
          children: [
            Align(
                alignment: Alignment.centerLeft,
                child: Image.asset('assets/branding/aadha-aadha-logo.png',
                    width: 112, height: 112, semanticLabel: 'Aadha/Aadha')),
            const SizedBox(height: 26),
            const Text('Shared moments.\nSimple balances.',
                style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    height: 1.12,
                    letterSpacing: -1.2,
                    color: Color(0xff173c3b))),
            const SizedBox(height: 16),
            const Text(
                'A quiet little ledger for you and a friend.\nConfirm a payment. Split it. Carry on.',
                style: TextStyle(fontSize: 16, height: 1.6)),
            const SizedBox(height: 32),
            if (!widget.configured)
              const Card(
                  child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('This build is not connected yet.',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 18)),
                            SizedBox(height: 8),
                            Text(
                                'Add your project configuration and rebuild to enable sign-in and shared expenses. See the setup guide included with the source.'),
                          ])))
            else ...[
              OutlinedButton(
                  onPressed: busy ? null : googleSignIn,
                  child: const Text('Continue with Google')),
              const SizedBox(height: 16),
              const Text('Or use email and password',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              if (signup) ...[
                TextField(
                    controller: name,
                    maxLength: 60,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Your name')),
                const SizedBox(height: 12)
              ],
              TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 12),
              TextField(
                  controller: password,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  autofillHints: [
                    signup ? AutofillHints.newPassword : AutofillHints.password
                  ],
                  onSubmitted: (_) {
                    if (!busy) submit();
                  },
                  decoration: const InputDecoration(
                      labelText: 'Password',
                      helperText: 'At least 8 characters')),
              if (error != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              if (notice != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(notice!)),
              const SizedBox(height: 18),
              FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(busy
                      ? 'Please wait…'
                      : signup
                          ? 'Create account'
                          : 'Sign in')),
              if (!widget.existingOnly)
                TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                              signup = !signup;
                              error = null;
                            }),
                    child: Text(signup
                        ? 'Already have an account? Sign in'
                        : 'New here? Create an account')),
              const SizedBox(height: 20),
              const Text(
                  'Notification access is optional and explained after setup. You can always enter expenses manually.',
                  style: TextStyle(fontSize: 12, height: 1.5)),
            ],
          ]);
}

class ExpenseEditor extends StatefulWidget {
  const ExpenseEditor(
      {super.key,
      required this.friend,
      this.candidate,
      this.repayment = false,
      this.suggestedRepayment});
  final String friend;
  final Map<String, dynamic>? candidate;
  final bool repayment;
  final int? suggestedRepayment;
  @override
  State<ExpenseEditor> createState() => _ExpenseEditorState();
}

class _ExpenseEditorState extends State<ExpenseEditor> {
  final amount = TextEditingController(),
      recipient = TextEditingController(),
      share = TextEditingController();
  late final String requestId;
  bool custom = false, saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    requestId = widget.candidate?['id'] as String? ?? newRequestId();
    final initial =
        widget.candidate?['amount'] as num? ?? widget.suggestedRepayment;
    if (initial != null) {
      amount.text = (initial.toInt() / 100).toStringAsFixed(2);
    }
    recipient.text = widget.candidate?['recipient'] as String? ?? '';
  }

  @override
  void dispose() {
    amount.dispose();
    recipient.dispose();
    share.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final paise = parsePaise(amount.text);
    final myShare = custom ? parsePaise(share.text) : null;
    if (paise == null ||
        paise <= 0 ||
        (custom && (myShare == null || myShare > paise))) {
      setState(() => error =
          'Enter a positive amount with up to 2 decimals. Your share must be between zero and the total.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await NativeBridge.call('queue', {
        'id': requestId,
        'amount': paise,
        'share': myShare,
        'recipient':
            recipient.text.trim().isEmpty ? null : recipient.text.trim(),
        'repayment': widget.repayment,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is PlatformException
              ? e.message
              : 'Could not save. Please try again.';
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = parsePaise(amount.text) ?? 0;
    final mine = custom ? parsePaise(share.text) ?? 0 : (value + 1) ~/ 2;
    return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  widget.repayment
                      ? 'Record a repayment'
                      : 'Log a shared expense',
                  style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Color(0xff173c3b))),
              const SizedBox(height: 8),
              Text(widget.repayment
                  ? 'Record money you already paid to ${widget.friend}.'
                  : 'You paid. Decide how much each of you shares.'),
              const SizedBox(height: 24),
              TextField(
                  controller: amount,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                      labelText: 'Amount', prefixText: '₹ ')),
              const SizedBox(height: 16),
              if (!widget.repayment) ...[
                TextField(
                    controller: recipient,
                    maxLength: 100,
                    decoration:
                        const InputDecoration(labelText: 'Paid to (optional)')),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Split equally')),
                      ButtonSegment(value: true, label: Text('Custom split')),
                    ],
                    selected: {
                      custom
                    },
                    onSelectionChanged: (values) =>
                        setState(() => custom = values.first)),
                const SizedBox(height: 20),
                if (custom)
                  TextField(
                      controller: share,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                          labelText: 'Your share', prefixText: '₹ ')),
                const SizedBox(height: 12),
                Text(
                    'You: ${money(mine)}   ·   ${widget.friend}: ${money(value - mine)}'),
                if (!custom)
                  const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('If there is an odd paise, you cover it.',
                          style: TextStyle(fontSize: 12))),
              ],
              if (widget.candidate != null &&
                  widget.candidate!['amount'] == null)
                const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                        'The notification did not contain an unambiguous amount. Check the payment before logging.')),
              if (error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 24),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                      onPressed: saving ? null : save,
                      child: Text(saving
                          ? 'Saving…'
                          : widget.repayment
                              ? 'Confirm repayment'
                              : 'Confirm shared expense'))),
              TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel')),
            ]));
  }
}
