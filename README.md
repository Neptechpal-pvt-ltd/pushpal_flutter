# pushpal_flutter

Flutter SDK for [PushPal](https://push.neptechpal.com.np) — push notifications for Android and iOS on top of your own Firebase project.

- Registers the device and keeps its FCM token fresh
- Links devices to your user ids (`login` / `logout`) and data tags for segments
- Shows notifications while the app is in the foreground (Android heads-up, iOS banner)
- Reports taps so the dashboard shows open rates
- Gives you a stream of tapped notifications with `route`, `url` and `data` for deep links

## Install

```bash
flutter pub add firebase_core
dart pub global activate flutterfire_cli && flutterfire configure
```

```yaml
dependencies:
  pushpal_flutter:
    git:
      url: https://github.com/Neptechpal-pvt-ltd/pushpal_flutter.git
      ref: v0.1.0
```

## Use

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:pushpal_flutter/pushpal_flutter.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await PushPal.initialize(appKey: 'pk_…'); // Dashboard → Settings → App key

  PushPal.onNotificationOpened.listen((n) {
    // n.route, n.url, n.data
  });

  runApp(const MyApp());
}

// Later, at a good moment:
await PushPal.requestPermission();

// After sign-in / sign-out:
await PushPal.login(user.id);
await PushPal.logout();

// Segmentation:
await PushPal.setTags({'plan': 'pro', 'level': 3});
await PushPal.removeTags(['trial']);

// In-app "notifications" switch:
await PushPal.setSubscribed(false);
```

### `initialize` options

| Option | Default | |
|---|---|---|
| `appKey` | — | Public app key (`pk_…`) |
| `showForegroundNotifications` | `true` | Show pushes while the app is open |
| `requestPermission` | `false` | Ask for permission during `initialize` |
| `androidChannelId` | `default` | Must match the channel id in app settings |
| `androidChannelName` | `Notifications` | Shown in Android system settings |
| `androidIcon` | launcher icon | Drawable for foreground notifications, e.g. `ic_notification` |
| `vapidKey` | — | Web only |
| `debug` | `false` | Log requests with `debugPrint` |

## iOS

1. Xcode → Runner → Signing & Capabilities → add **Push Notifications** and **Background Modes → Remote notifications**.
2. Create an APNs key (.p8) in the Apple Developer portal and upload it in Firebase → Project settings → Cloud Messaging.

## Android

Android 13+ needs the runtime permission: call `PushPal.requestPermission()`. Optionally set a monochrome icon:

```xml
<meta-data
  android:name="com.google.firebase.messaging.default_notification_icon"
  android:resource="@drawable/ic_notification" />
```

Full docs: https://push.neptechpal.com.np/docs
