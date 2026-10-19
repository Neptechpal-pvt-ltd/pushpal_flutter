/// PushPal for Flutter — pure Dart, attaches to your own firebase_messaging.
///
/// ```dart
/// PushPal.configure(appKey: 'pk_…');
/// await PushPal.attachFirebase(FirebaseMessaging.instance,
///     onMessageOpenedApp: FirebaseMessaging.onMessageOpenedApp,
///     onMessage: FirebaseMessaging.onMessage,
///     onUrl: (url) => launchUrl(Uri.parse(url)));
/// ```
library;

export 'src/client.dart';
export 'src/inapp.dart' show PushPalInAppMessage;
export 'src/notification.dart';
