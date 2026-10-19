# pushpal_flutter

Flutter SDK for [PushPal](https://push.neptechpal.com.np): push notifications, in-app messages, inbox, identity, events and attribution.

**Pure Dart.** No native code; dependencies are only `http` and `shared_preferences`. It attaches to *your* `firebase_messaging`, so there are no plugin version conflicts. PushPal is not a replacement for FCM: you keep Firebase, PushPal decides who gets what.

## Install

```yaml
dependencies:
  firebase_core: any
  firebase_messaging: any
  pushpal_flutter:
    git:
      url: https://github.com/Neptechpal-pvt-ltd/pushpal_flutter.git
      ref: v1.0.0
```

Run `flutterfire configure` once if the app has no Firebase yet.

## 1. Configure and attach Firebase

```dart
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  PushPal.configure(appKey: 'pk_…'); // client key — server keys are rejected
  await PushPal.attachFirebase(
    FirebaseMessaging.instance,
    onMessageOpenedApp: FirebaseMessaging.onMessageOpenedApp,
    onMessage: FirebaseMessaging.onMessage,
    onUrl: (url) => launchUrl(Uri.parse(url)), // url_launcher
  );

  PushPal.onNotificationOpened.listen((n) {
    if (n.targetRoute != null) navigatorKey.currentState?.pushNamed(n.targetRoute!);
  });

  runApp(MaterialApp(navigatorKey: navigatorKey, home: const Home()));
}
```

`attachFirebase` asks for permission, registers the token (and re-registers on rotation), and records opens from background and cold-start taps. On iOS pass `useApnsToken: true` to deliver straight through APNs when the app has an APNs key in PushPal (falls back to FCM on simulators).

## 2. Identify

```dart
await PushPal.identify(user.id, signature: sigFromYourBackend, attributes: {'first_name': 'Sita', 'plan': 'pro', 'level': 3});
await PushPal.logout();      // sign-out
await PushPal.unsubscribe(); // durable opt-out — survives sign-in and reinstall; only a server key lifts it
```

`signature` is `hex(HMAC-SHA256(identitySecret, userId))`, computed on your server (Dashboard → Settings → Keys & identity). Turn on "Require signed identify()" before launch.

## 3. Events, purchases, tags

```dart
await PushPal.track('level_up', properties: {'level': 4});
await PushPal.trackPurchase(4.99, currency: 'USD', productId: 'gems_500');
await PushPal.setTags({'theme': 'dark'});
```

`install` and `session_start` are sent automatically (`configure(trackSessions: false)` to turn off).

## 4. In-app messages and inbox

```dart
PushPal.enableInAppMessages(navigatorKey: navigatorKey, onPromptPush: () => FirebaseMessaging.instance.requestPermission());
PushPal.setTrigger('cart_items', 3); // local only
PushPal.pauseInAppMessages(); PushPal.resumeInAppMessages();

final messages = await PushPal.inbox();
await PushPal.inboxMarkRead(messages.map((m) => m.id).toList());
```

Rules are published in the dashboard and cached on the device; frequency caps are tracked on the device. Campaigns sent with the "Live in-app" channel appear instantly in open apps.

## 5. Attribution links

```dart
// In your deep-link handler (app_links / uni_links):
final route = await PushPal.handleDeepLink(uri);
// Android install referrer (play_install_referrer package):
PushPal.setInstallReferrer(details.installReferrer!);
```

## Foreground notifications on Android

FCM doesn't show notifications while the app is open on Android. Show them with `flutter_local_notifications`:

```dart
PushPal.onNotificationReceived.listen((n) {
  localNotifications.show(n.hashCode, n.title, n.body, details, payload: jsonEncode(n.data));
});
// on tap:
PushPal.trackNotificationOpen(jsonDecode(payload), buttonId: response.actionId);
```

`PushPalNotification.parse(message.data)` exposes action buttons and image URLs for building rich notifications.

## Topics (preference center)

```dart
final topics = await PushPal.topics(); // [{key, name, description, subscribed}]
await PushPal.setTopic('offers', false);
```

## Confirmed delivery

Foreground receipts are automatic. For background/terminated pushes add to your background handler:

```dart
@pragma('vm:entry-point')
Future<void> onBackground(RemoteMessage m) => PushPal.reportReceived(m.data);
// main(): FirebaseMessaging.onBackgroundMessage(onBackground);
```

## Check your setup

```dart
if (kDebugMode) await PushPal.runSetupTest(); // prints a checklist
```

## Debug builds on iOS

With a direct APNs key, set it to *Sandbox* in Settings for Xcode debug builds — production APNs rejects sandbox tokens.
