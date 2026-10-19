import 'package:flutter/material.dart';
import 'package:pushpal_flutter/pushpal_flutter.dart';

/// Minimal example without Firebase: registers a token you paste in.
/// In a real app call PushPal.attachFirebase(FirebaseMessaging.instance, …).
final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PushPal.configure(
      appKey:
          const String.fromEnvironment('PUSHPAL_KEY', defaultValue: 'pk_demo'),
      debug: true);
  PushPal.enableInAppMessages(navigatorKey: navigatorKey);
  runApp(MaterialApp(navigatorKey: navigatorKey, home: const Home()));
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _token = TextEditingController();
  String _log = '';

  Future<void> _run(String label, Future<Object?> Function() f) async {
    final r = await f();
    setState(() => _log = '$label → ${r ?? 'ok'}\n$_log');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('PushPal example')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
              controller: _token,
              decoration: const InputDecoration(labelText: 'Push token')),
          Wrap(spacing: 8, children: [
            FilledButton(
                onPressed: () => _run(
                    'register', () => PushPal.registerPushToken(_token.text)),
                child: const Text('Register')),
            OutlinedButton(
                onPressed: () => _run(
                    'identify',
                    () => PushPal.identify('demo-user',
                        attributes: {'first_name': 'Demo'})),
                child: const Text('Identify')),
            OutlinedButton(
                onPressed: () =>
                    _run('track', () => PushPal.track('demo_event')),
                child: const Text('Track')),
            OutlinedButton(
                onPressed: () =>
                    _run('purchase', () => PushPal.trackPurchase(1.99)),
                child: const Text('Purchase')),
            OutlinedButton(
                onPressed: () =>
                    _run('inbox', () async => (await PushPal.inbox()).length),
                child: const Text('Inbox')),
            OutlinedButton(
                onPressed: () => _run('setup',
                    () async => (await PushPal.runSetupTest()).join('\n')),
                child: const Text('Setup test')),
          ]),
          const SizedBox(height: 16),
          Text(_log, style: const TextStyle(fontFamily: 'monospace')),
        ]),
      );
}
