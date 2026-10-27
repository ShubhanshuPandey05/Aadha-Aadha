import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ledger.dart';
import 'native_bridge.dart';
import 'realtime_sync.dart';
import 'forms.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TwoTallyApp());
}

const ink = Color(0xff173c3b),
    teal = Color(0xff16766b),
    paper = Color(0xfff5f7f4);

class TwoTallyApp extends StatelessWidget {
  const TwoTallyApp({super.key, this.home = const HomeScreen()});
  final Widget home;
  @override
  Widget build(BuildContext context) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Aadha/Aadha',
      theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: teal),
          scaffoldBackgroundColor: paper,
          appBarTheme:
              const AppBarTheme(backgroundColor: paper, foregroundColor: ink),
          cardTheme: CardTheme(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20))),
          inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xffd7dfd8)))),
          filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))))),
      home: home);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.sync});
  final LedgerRealtime? sync;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  Map<String, dynamic> status = {}, snapshot = {};
  bool loading = true, busy = false, live = false, refreshing = false;
  String? error;
  int tab = 0;
  late final LedgerRealtime realtime;
  Timer? poll;
  Map<String, dynamic> update = {};
  bool checkingUpdate = false, downloadingUpdate = false;
  String? updateError;
  String? promptedVersion;
  Map<String, dynamic>? deferredRoute;
  String get user => status['user_id'] as String? ?? '';
  Map<String, dynamic>? get group => snapshot['group'] as Map<String, dynamic>?;
  List<Map<String, dynamic>> get members =>
      (snapshot['members'] as List? ?? []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get entries =>
      (snapshot['expenses'] as List? ?? []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get pending =>
      (status['pending'] as List? ?? []).cast<Map<String, dynamic>>();
  String get friend =>
      members
          .where((m) => m['id'] != user)
          .map((m) => m['name'] as String)
          .firstOrNull ??
      'Your friend';
  Map<String, dynamic> get me =>
      members.where((m) => m['id'] == user).firstOrNull ?? {};
  int get balance => (me['balance'] as num?)?.toInt() ?? 0;

  @override
  void initState() {
    super.initState();
    realtime = widget.sync ?? LedgerRealtime();
    WidgetsBinding.instance.addObserver(this);
    NativeBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'route') await readRoute();
    });
    refresh().then((_) async {
      await readRoute();
      await checkUpdate();
    });
    startPolling();
  }

  Future<void> checkUpdate({bool manual = false}) async {
    if (!mounted || checkingUpdate || downloadingUpdate) return;
    setState(() {
      checkingUpdate = true;
      updateError = null;
    });
    try {
      final next = await NativeBridge.call('checkUpdate', {'force': manual});
      if (!mounted) return;
      setState(() => update = next);
      if (next['available'] == true &&
          (manual || promptedVersion != next['version'])) {
        promptedVersion = next['version'] as String;
        final accept = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: Text('Update to ${next['version']}'),
                    content: Text(
                        'A new Aadha/Aadha update is available (${((next['size'] as num) / 1000000).toStringAsFixed(2)} MB). Download it now? Android will ask you to confirm installation. Your ledger and login stay intact.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Later')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Download update'))
                    ]));
        if (accept == true && mounted) await installUpdate();
      } else if (manual) {
        message('No newer compatible release is available.');
      }
    } catch (e) {
      if (mounted) setState(() => updateError = humanError(e));
      if (manual) message(humanError(e));
    } finally {
      if (mounted) setState(() => checkingUpdate = false);
    }
  }

  Future<void> installUpdate() async {
    if (downloadingUpdate) return;
    setState(() {
      downloadingUpdate = true;
      updateError = null;
      tab = 2;
    });
    message('Downloading update. You can keep using your ledger.');
    try {
      final result = await NativeBridge.call('installUpdate');
      if (result['permission'] == true) {
        message(
            'Allow updates from Aadha/Aadha, then return and tap Install update again.');
      }
    } catch (e) {
      if (mounted) setState(() => updateError = humanError(e));
      message(humanError(e));
    } finally {
      if (mounted) setState(() => downloadingUpdate = false);
    }
  }

  void startPolling() {
    poll?.cancel();
    poll = Timer.periodic(const Duration(seconds: 10), (_) async {
      try {
        final next = await NativeBridge.call('status');
        if (!mounted) return;
        final wasQueued = pending.any((p) => p['state'] == 'queued');
        final accountChanged = user != (next['user_id'] as String? ?? '');
        setState(() => status = next);
        if (wasQueued || accountChanged) await refresh(quiet: true);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NativeBridge.channel.setMethodCallHandler(null);
    poll?.cancel();
    realtime.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh(quiet: true).then((_) async {
        await readRoute();
        await checkUpdate();
      });
      startPolling();
    } else if (state == AppLifecycleState.paused) {
      poll?.cancel();
      realtime.stop();
      live = false;
    }
  }

  Future<void> refresh({bool quiet = false}) async {
    if (refreshing) return;
    refreshing = true;
    if (!quiet && mounted) setState(() => loading = true);
    try {
      final next = await NativeBridge.call('status');
      if (!mounted) return;
      setState(() => status = next);
      if (user.isNotEmpty) {
        final data = await NativeBridge.call('snapshot');
        if (!mounted) return;
        setState(() => snapshot = data);
        if (group != null) {
          await realtime.start(
              group!['id'] as String, () => refresh(quiet: true), (connected) {
            if (mounted) setState(() => live = connected);
          });
        }
      } else {
        await realtime.stop();
        snapshot = {};
      }
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = humanError(e));
    } finally {
      refreshing = false;
      if (mounted) setState(() => loading = false);
    }
  }

  String humanError(Object e) => e is PlatformException
      ? e.message ?? 'Could not complete the request.'
      : 'Could not connect. Check your connection and try again.';
  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (e) {
      message(humanError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> readRoute() async {
    final route = await NativeBridge.call('takeRoute');
    if (route['kind'] == 'auth') {
      await refresh(quiet: true);
      message(route['id'] as String? ?? 'Sign-in updated.');
      return;
    }
    if (route.isNotEmpty) deferredRoute = route;
    if (!mounted || user.isEmpty || group == null || deferredRoute == null) {
      return;
    }
    final target = deferredRoute!;
    deferredRoute = null;
    if (target['kind'] == 'expense') {
      await showExpense(target['id'] as String);
    } else if (target['kind'] == 'candidate') {
      final fresh = await NativeBridge.call('status');
      if (!mounted) return;
      setState(() => status = fresh);
      final item = pending
          .where((e) => e['id'] == target['id'] && e['state'] == 'suggested')
          .firstOrNull;
      if (item != null) {
        await editor(candidate: item);
      } else {
        message('This payment was already handled or the suggestion expired.');
      }
    } else {
      setState(() => tab = 2);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Row(children: [
            Image.asset('assets/branding/aadha-aadha-logo.png',
                width: 42, height: 42, excludeFromSemantics: true),
            const SizedBox(width: 9),
            const Text('Aadha/Aadha',
                style:
                    TextStyle(fontWeight: FontWeight.w800, letterSpacing: -1))
          ]),
          actions: [
            if (user.isNotEmpty)
              IconButton(
                  tooltip: 'Refresh ledger',
                  onPressed: loading ? null : () => refresh(),
                  icon: const Icon(Icons.refresh_rounded)),
            const SizedBox(width: 8)
          ]),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: loading && status.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : Column(children: [
                          if (error != null)
                            MaterialBanner(content: Text(error!), actions: [
                              TextButton(
                                  onPressed: () => refresh(),
                                  child: const Text('Retry')),
                              if (user.isNotEmpty)
                                TextButton(
                                    onPressed: reauthenticate,
                                    child: const Text('Sign in'))
                            ]),
                          if (loading)
                            const LinearProgressIndicator(minHeight: 2),
                          Expanded(
                              child: user.isEmpty
                                  ? AuthScreen(
                                      configured: status['configured'] == true,
                                      onSignedIn: () async {
                                        await refresh();
                                        await readRoute();
                                      })
                                  : group == null
                                      ? groupSetup()
                                      : tab == 0
                                          ? ledgerView()
                                          : tab == 1
                                              ? summaryView()
                                              : settingsView())
                        ])))),
      bottomNavigationBar: user.isNotEmpty && group != null
          ? NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (value) => setState(() => tab = value),
              destinations: const [
                  NavigationDestination(
                      icon: Icon(Icons.receipt_long_outlined),
                      selectedIcon: Icon(Icons.receipt_long),
                      label: 'Ledger'),
                  NavigationDestination(
                      icon: Icon(Icons.donut_small_outlined),
                      selectedIcon: Icon(Icons.donut_small),
                      label: 'Summary'),
                  NavigationDestination(
                      icon: Icon(Icons.tune_rounded), label: 'Settings')
                ])
          : null,
      floatingActionButton:
          user.isNotEmpty && group?['ready'] == true && tab == 0
              ? FloatingActionButton.extended(
                  onPressed: busy ? null : () => editor(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add expense'))
              : null);

  Widget groupSetup() => ListView(padding: const EdgeInsets.all(24), children: [
        const SizedBox(height: 36),
        const Icon(Icons.people_alt_outlined, size: 60, color: teal),
        const SizedBox(height: 24),
        const Text('Just the two of you.',
            style: TextStyle(
                fontSize: 32, fontWeight: FontWeight.w800, color: ink)),
        const SizedBox(height: 12),
        const Text(
            'Create a shared ledger, or join your friend with their invitation code. Each account belongs to one group.',
            style: TextStyle(fontSize: 16, height: 1.5)),
        const SizedBox(height: 30),
        FilledButton(
            onPressed: busy
                ? null
                : () => run(() async {
                      final name = await askText('Name your shared ledger',
                          'e.g. Our everyday expenses',
                          maxLength: 60);
                      if (name == null || name.trim().isEmpty) return;
                      await NativeBridge.call(
                          'createGroup', {'name': name.trim()});
                      await refresh();
                      await invite();
                    }),
            child: const Text('Create a group')),
        const SizedBox(height: 12),
        OutlinedButton(
            onPressed: busy
                ? null
                : () => run(() async {
                      final code =
                          await askText('Join your friend', 'Invitation code');
                      if (code == null) return;
                      await NativeBridge.call('joinGroup', {'code': code});
                      await refresh();
                    }),
            child: const Text('Join with a code')),
        TextButton(
            onPressed: busy ? null : signOut, child: const Text('Sign out'))
      ]);

  Widget ledgerView() => RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
          children: [
            Row(children: [
              Expanded(
                  child: Text(group!['name'] as String,
                      style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: ink))),
              Icon(Icons.circle, size: 8, color: live ? teal : Colors.orange),
              const SizedBox(width: 5),
              Text(live ? 'Live' : 'Reconnecting',
                  style: const TextStyle(fontSize: 12))
            ]),
            const SizedBox(height: 6),
            Text(group!['ready'] == true
                ? 'You & $friend · A little less keeping score.'
                : 'Invite your friend to get started.'),
            const SizedBox(height: 24),
            if (group!['ready'] != true)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Your friend has a place here.',
                                style: TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            const Text(
                                'Send a private, single-use invitation. Logging becomes available when they join.'),
                            const SizedBox(height: 16),
                            FilledButton(
                                onPressed: busy ? null : () => run(invite),
                                child: const Text('Get invitation code'))
                          ]))),
            if (group!['ready'] == true)
              Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                      color: ink, borderRadius: BorderRadius.circular(24)),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            balance == 0
                                ? 'ALL SQUARE'
                                : balance > 0
                                    ? '$friend owes you'.toUpperCase()
                                    : 'YOU OWE $friend'.toUpperCase(),
                            style: const TextStyle(
                                color: Color(0xffb6d4c5),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2)),
                        const SizedBox(height: 12),
                        Text(money(balance.abs()),
                            style: const TextStyle(
                                fontSize: 40,
                                color: Colors.white,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(
                            balance == 0
                                ? 'Nothing to settle. Keep enjoying the shared things.'
                                : 'Across all expenses and recorded repayments.',
                            style: const TextStyle(color: Color(0xffdce9df))),
                        if (balance < 0)
                          Padding(
                              padding: const EdgeInsets.only(top: 18),
                              child: FilledButton.tonal(
                                  onPressed: () => editor(repayment: true),
                                  child: const Text('Record a repayment')))
                      ])),
            if (pending
                .any((e) => e['state'] == 'queued' || e['state'] == 'failed'))
              Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: ListTile(
                      tileColor: const Color(0xfff2e7d5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      leading: const Icon(Icons.cloud_upload_outlined),
                      title: const Text('Expenses waiting to sync'),
                      subtitle: const Text(
                          'Only saved expenses appear in your balance.'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setState(() => tab = 2))),
            const SizedBox(height: 28),
            const Text('RECENT ACTIVITY',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    fontSize: 12)),
            const SizedBox(height: 12),
            if (entries.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Column(children: [
                    Icon(Icons.receipt_long_outlined, size: 46, color: teal),
                    SizedBox(height: 12),
                    Text('A fresh start.',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w700)),
                    SizedBox(height: 6),
                    Text('Your shared expenses will land here.')
                  ])),
            for (final row in entries) expenseTile(row),
            if (entries.length == 100)
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      'Showing the latest 100 entries. Balances and summaries include your full ledger.'))
          ]));
  Widget expenseTile(Map<String, dynamic> row) {
    final payer =
        members.where((m) => m['id'] == row['payer_id']).firstOrNull?['name'] ??
            'Friend';
    final repayment = row['kind'] == 'repayment';
    final date = DateTime.parse(row['occurred_at'] as String).toLocal();
    return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: CircleAvatar(
                backgroundColor: const Color(0xffe8f1e9),
                child: Icon(
                    repayment ? Icons.swap_horiz : Icons.receipt_outlined,
                    color: teal)),
            title: Text(
                row['name'] as String? ??
                    (repayment
                        ? 'Repayment'
                        : row['recipient'] as String? ?? 'Shared expense'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
                '${row['payer_id'] == user ? 'You' : payer.toString()} paid · ${dateLabel(date)}'),
            trailing: Text(money((row['amount_paise'] as num).toInt()),
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 16, color: ink)),
            onTap: () => showExpense(row['id'] as String)));
  }

  String dateLabel(DateTime date) =>
      [date.day, date.month, date.year].join('/');

  Widget summaryView() {
    final month = snapshot['month'] as Map<String, dynamic>? ?? {};
    final start = month['start'] == null
        ? DateTime.now()
        : DateTime.parse(month['start'] as String)
            .add(const Duration(hours: 5, minutes: 30));
    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    return ListView(padding: const EdgeInsets.all(24), children: [
      const Text('The bigger picture.',
          style:
              TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: ink)),
      const SizedBox(height: 24),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${names[start.month - 1]} ${start.year}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 18)),
                    const SizedBox(height: 16),
                    Text(money((month['total'] as num?)?.toInt() ?? 0),
                        style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w800,
                            color: ink)),
                    Text('${month['count'] ?? 0} shared expenses · India time'),
                    const SizedBox(height: 8),
                    const Text('Repayments do not count as spending.')
                  ]))),
      const SizedBox(height: 24),
      const Text('ALL-TIME CONTRIBUTIONS',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      const SizedBox(height: 12),
      for (final member in members)
        Card(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          member['id'] == user
                              ? 'You'
                              : member['name'] as String,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 20)),
                      const SizedBox(height: 12),
                      info('Paid for expenses',
                          money((member['contributed'] as num).toInt())),
                      info('Share of expenses',
                          money((member['share'] as num).toInt())),
                      info('Net, after repayments',
                          money((member['balance'] as num).toInt()))
                    ]))),
      const SizedBox(height: 20),
      const Text('Settlement',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(
          balance == 0
              ? 'You are settled up.'
              : balance > 0
                  ? '$friend pays you ${money(balance)} to settle the ledger.'
                  : 'Pay $friend ${money(-balance)} to settle the ledger.',
          style: const TextStyle(fontSize: 17, height: 1.5)),
      const SizedBox(height: 12),
      const Text(
          'Net balance = contributions − your expense shares + repayments you made − repayments you received.'),
      const SizedBox(height: 24),
      if (group?['ready'] == true)
        OutlinedButton.icon(
            onPressed: () => editor(repayment: true),
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Record a repayment you made')),
      const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
              'Record only money already transferred. Aadha/Aadha never sends a payment.'))
    ]);
  }

  Widget settingsView() =>
      ListView(padding: const EdgeInsets.all(24), children: [
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'App updates${update['current'] == null ? '' : ' - ${update['current']}'}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const Text(
                          'Checks automatically when you open the app, up to once a day. Android asks before installation.'),
                      if (downloadingUpdate) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                        const Text('Downloading and verifying update...')
                      ],
                      if (updateError != null)
                        Text(updateError!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      TextButton(
                          onPressed: checkingUpdate || downloadingUpdate
                              ? null
                              : () => checkUpdate(manual: true),
                          child: Text(checkingUpdate
                              ? 'Checking...'
                              : 'Check for updates')),
                      if (update['available'] == true)
                        FilledButton(
                            onPressed: downloadingUpdate ? null : installUpdate,
                            child: Text('Install update ${update['version']}')),
                    ]))),
        const SizedBox(height: 20),
        const Text('Make it one tap.',
            style: TextStyle(
                fontSize: 28, fontWeight: FontWeight.w800, color: ink)),
        const SizedBox(height: 12),
        const Text(
            'Android notification access lets Aadha/Aadha see notifications. It processes only Google Pay, PhonePe, Paytm, Kotak 811, and BHIM locally. Only a payment you confirm is sent to your shared ledger.',
            style: TextStyle(height: 1.5)),
        const SizedBox(height: 16),
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Detect payment notifications'),
            subtitle: const Text('“Yes, Log Expense” uses an equal split.'),
            value: status['detection'] == true,
            onChanged: (value) => run(() async {
                  if (value) {
                    final consent = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                                title: const Text('Allow payment detection?'),
                                content: const Text(
                                    'Android grants access to notifications from all apps. Aadha/Aadha discards other apps’ notifications and never stores raw notification text. Suggestions expire after 24 hours. Tapping Yes confirms an equal split; dismissing does nothing.\n\nYou can turn this off at any time.'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel')),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('I agree'))
                                ]));
                    if (consent != true) return;
                  }
                  await NativeBridge.call('detection', {'enabled': value});
                  if (value) await NativeBridge.call('reconnectListener');
                  final next = await NativeBridge.call('status');
                  if (mounted) setState(() => status = next);
                })),
        permissionTile('Notification access', status['listener'] == true,
            'listenerSettings'),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
                status['listener_connected'] == true
                    ? Icons.check_circle
                    : Icons.warning_amber_rounded,
                color: teal),
            title: Text(status['listener_connected'] == true
                ? 'Payment listener connected'
                : 'Payment listener disconnected'),
            subtitle: status['listener_connected'] == true
                ? null
                : const Text(
                    'Permission alone is not enough. Reconnect before testing a payment.'),
            trailing: status['listener_connected'] == true
                ? null
                : TextButton(
                    onPressed: () => run(() async {
                          await NativeBridge.call('reconnectListener');
                          await refresh(quiet: true);
                        }),
                    child: const Text('Reconnect'))),
        permissionTile('Show prompts and alerts',
            status['notifications'] == true, 'notificationPermission'),
        const SizedBox(height: 12),
        const Text(
            'Some phones delay background work. If prompts or sync stop, review battery and autostart settings for Aadha/Aadha. Force-stopping the app pauses work until you reopen it.'),
        TextButton(
            onPressed: () => NativeBridge.call('appSettings'),
            child: const Text('Open Android app settings')),
        if ((status['detection_check'] as Map?)?['message'] != null)
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                  'Latest notification check · ${TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(((status['detection_check'] as Map)['time'] as num).toInt())).format(context)}'),
              subtitle: Text(
                  (status['detection_check'] as Map)['message'] as String)),
        if (status['firebase'] != true)
          const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Push alerts are not configured in this build.'),
              subtitle:
                  Text('The ledger can still sync while the app is open.')),
        const Divider(height: 32),
        const Text('On this device',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (pending.isEmpty) const Text('No payments waiting for attention.'),
        for (final item in pending)
          Card(
              child: ListTile(
                  title: Text(item['amount'] == null
                      ? 'Amount needed'
                      : money((item['amount'] as num).toInt())),
                  subtitle: Text(item['state'] == 'queued'
                      ? 'Confirmed · waiting to sync'
                      : item['state'] == 'failed'
                          ? item['message'] as String? ?? 'Needs attention'
                          : 'Not logged · confirm or dismiss'),
                  onTap: item['state'] == 'suggested'
                      ? () => editor(candidate: item)
                      : null,
                  trailing: item['state'] == 'queued'
                      ? const Icon(Icons.schedule)
                      : item['state'] == 'failed'
                          ? IconButton(
                              tooltip: 'Retry sync',
                              icon: const Icon(Icons.refresh),
                              onPressed: () => run(() async {
                                    await NativeBridge.call(
                                        'retry', {'id': item['id']});
                                    await refresh(quiet: true);
                                  }))
                          : IconButton(
                              tooltip: 'Dismiss suggestion',
                              icon: const Icon(Icons.close),
                              onPressed: () => run(() async {
                                    await NativeBridge.call(
                                        'dismiss', {'id': item['id']});
                                    await refresh(quiet: true);
                                  })))),
        const SizedBox(height: 24),
        const Text(
            'Detection is best effort. Formats and languages differ by payment app; hidden amounts need manual entry. No OTP, banking login, SMS, accessibility access, or payment initiation is used.'),
        const SizedBox(height: 24),
        OutlinedButton(
            onPressed: busy ? null : signOut, child: const Text('Sign out'))
      ]);

  Widget permissionTile(String title, bool enabled, String method) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(enabled ? Icons.check_circle : Icons.radio_button_unchecked,
          color: enabled ? teal : Colors.grey),
      title: Text(title),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => NativeBridge.call(method));
  Widget info(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w600)))
      ]));

  Future<String?> askText(String title, String hint, {int? maxLength}) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(title),
                content: TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: maxLength,
                    decoration: InputDecoration(hintText: hint)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: const Text('Continue'))
                ]));
    Future.delayed(const Duration(seconds: 1), controller.dispose);
    return result;
  }

  Future<void> invite() async {
    final result = await NativeBridge.call('invite');
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Invite your friend'),
                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          'Send this code privately. It can be used once and expires in 48 hours. Creating another code replaces this one.'),
                      const SizedBox(height: 18),
                      SelectableText(result['code'] as String,
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 18,
                              fontWeight: FontWeight.bold))
                    ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Done')),
                  FilledButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: result['code'] as String));
                        message('Invitation code copied.');
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy code'))
                ]));
  }

  Future<void> reauthenticate() async {
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
            child: SizedBox(
                height: MediaQuery.sizeOf(sheetContext).height * .85,
                child: AuthScreen(
                    configured: true,
                    existingOnly: true,
                    onSignedIn: () async {
                      Navigator.pop(sheetContext);
                      await refresh();
                    }))));
  }

  Future<void> signOut() => run(() async {
        try {
          await NativeBridge.call('logout');
        } finally {
          await refresh();
        }
      });
  Future<void> editor(
      {Map<String, dynamic>? candidate,
      Map<String, dynamic>? entry,
      bool repayment = false}) async {
    if (group?['ready'] != true) {
      message('Connect your friend first.');
      return;
    }
    final saved = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => ExpenseEditor(
            friend: friend,
            candidate: candidate,
            entry: entry,
            repayment: repayment,
            suggestedRepayment: repayment && balance < 0 ? -balance : null));
    if (saved == true) {
      message(entry == null
          ? 'Confirmed. The expense will sync in the background.'
          : 'Entry updated. Changes recorded in history.');
      await refresh(quiet: true);
    }
  }

  String historyText(dynamic history) {
    String describe(dynamic value) =>
        '${value['name'] ?? 'Unnamed'} | ${money((value['amount_paise'] as num).toInt())} | payer share ${money((value['payer_share_paise'] as num).toInt())} | paid to ${value['recipient'] ?? 'Not specified'}';
    final before = history['before_value'];
    return before == null
        ? describe(history['after_value'])
        : 'Before: ${describe(before)}\nAfter: ${describe(history['after_value'])}';
  }

  Future<void> showExpense(String id) async {
    try {
      final row = await NativeBridge.call('expense', {'id': id});
      if (!mounted) return;
      final amount = (row['amount_paise'] as num).toInt(),
          share = (row['payer_share_paise'] as num).toInt();
      final mine = row['payer_id'] == user,
          repayment = row['kind'] == 'repayment';
      final edit = await showModalBottomSheet<bool>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          builder: (context) => SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        row['name'] as String? ??
                            (repayment
                                ? 'Repayment'
                                : row['recipient'] as String? ??
                                    'Shared expense'),
                        style: const TextStyle(
                            fontSize: 26, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 16),
                    Text(money(amount),
                        style: const TextStyle(
                            fontSize: 40,
                            color: teal,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 20),
                    info('Paid by', mine ? 'You' : row['payer_name'] as String),
                    if (row['recipient'] != null)
                      info('Paid to', row['recipient'] as String),
                    if (!repayment) ...[
                      info('Your share', money(mine ? share : amount - share)),
                      info('$friend’s share',
                          money(mine ? amount - share : share))
                    ],
                    info(
                        'When',
                        DateTime.parse(row['occurred_at'] as String)
                            .toLocal()
                            .toString()
                            .split('.')
                            .first),
                    info(
                        'Logged from',
                        row['source'] == 'manual'
                            ? 'Manual entry'
                            : 'Payment notification'),
                    if (row['transaction_ref'] != null)
                      info('Reference', row['transaction_ref'] as String),
                    const SizedBox(height: 16),
                    const Text(
                        'A shared ledger entry records what you confirmed. It is not bank verification.'),
                    const SizedBox(height: 24),
                    if (mine)
                      OutlinedButton.icon(
                          onPressed: () => Navigator.pop(context, true),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit your entry')),
                    ExpansionTile(
                        title: const Text('Entry history'),
                        children: [
                          for (final h in (row['history'] as List? ?? []))
                            ListTile(
                                isThreeLine: true,
                                title: Text(
                                    '${h['revision'] == 0 ? 'Created' : 'Edited'} by ${h['actor_name']}'),
                                subtitle: Text(
                                    '${DateTime.parse(h['changed_at'] as String).toLocal().toString().split('.').first}\n${historyText(h)}')),
                        ]),
                    SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Done')))
                  ])));
      if (edit == true && mounted) {
        await editor(entry: row, repayment: repayment);
      }
    } catch (e) {
      message(humanError(e));
    }
  }
}
