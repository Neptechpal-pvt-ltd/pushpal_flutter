/// PushPal push notifications for Flutter (Android, iOS).
///
/// ```dart
/// await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
/// await PushPal.initialize(appKey: 'pk_…');
/// PushPal.onNotificationOpened.listen((n) => router.go(n.route ?? '/'));
/// ```
library;

export 'src/notification.dart';
export 'src/pushpal.dart';
