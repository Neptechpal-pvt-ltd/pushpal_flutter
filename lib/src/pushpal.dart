import 'dart:async';
import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification.dart';

const _prefix = 'pushpal.';
const _kToken = '${_prefix}token';
const _kUserId = '${_prefix}external_user_id';
const _kSubscribed = '${_prefix}subscribed';
const _kPendingTags = '${_prefix}pending_tags';
const _kPendingOpens = '${_prefix}pending_opens';

/// PushPal client. Call [initialize] once, after `Firebase.initializeApp`.
class PushPal {
  PushPal._();

  static const sdkVersion = '0.1.0';
  static const defaultBaseUrl = 'https://push.neptechpal.com.np';

  static String? _appKey;
  static String _baseUrl = defaultBaseUrl;
  static String? _vapidKey;
  static bool _showForeground = true;
  static bool _debug = false;
  static bool _initialized = false;
  static String _channelId = 'default';
  static String? _androidIcon;

  static String? _token;
  static String? _externalUserId;
  static bool _subscribed = true;
  static Map<String, dynamic>? _facts;
  static Future<void>? _registering;
  static bool _registerAgain = false;

  static final _local = FlutterLocalNotificationsPlugin();
  static final _openedPending = <PushPalNotification>[];
  static final StreamController<PushPalNotification> _opened =
      StreamController<PushPalNotification>.broadcast(
        // The notification that launched the app may arrive before anyone
        // listens; hold it for the first listener.
        onListen: () {
          for (final n in _openedPending) {
            _opened.add(n);
          }
          _openedPending.clear();
        },
      );
  static final _received = StreamController<PushPalNotification>.broadcast();

  /// Tapped notifications, including the one that launched the app.
  static Stream<PushPalNotification> get onNotificationOpened => _opened.stream;

  /// Notifications that arrive while the app is in the foreground.
  static Stream<PushPalNotification> get onNotificationReceived =>
      _received.stream;

  /// The current FCM token, once known.
  static String? get token => _token;

  /// The id passed to [login], if any.
  static String? get externalUserId => _externalUserId;

  /// Whether this device opted in to pushes ([setSubscribed]).
  static bool get isSubscribed => _subscribed;

  /// Registers this install with PushPal and wires up notification handling.
  ///
  /// * [appKey] — the public app key from the dashboard (`pk_…`).
  /// * [showForegroundNotifications] — show pushes while the app is open
  ///   (a heads-up on Android, a banner on iOS).
  /// * [requestPermission] — ask for notification permission right away.
  ///   Leave false to call [requestPermission] at a better moment.
  /// * [androidChannelId]/[androidChannelName] — must match the channel id
  ///   in the app's PushPal settings (default "default").
  /// * [androidIcon] — drawable resource name for foreground notifications,
  ///   e.g. `ic_notification`; defaults to the launcher icon.
  /// * [vapidKey] — only for web: the Firebase Web Push certificate key.
  static Future<void> initialize({
    required String appKey,
    String baseUrl = defaultBaseUrl,
    bool showForegroundNotifications = true,
    bool requestPermission = false,
    String androidChannelId = 'default',
    String androidChannelName = 'Notifications',
    String? androidIcon,
    String? vapidKey,
    bool debug = false,
  }) async {
    if (_initialized) return;
    _initialized = true;
    _appKey = appKey;
    _baseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    _showForeground = showForegroundNotifications;
    _channelId = androidChannelId;
    _androidIcon = androidIcon;
    _vapidKey = vapidKey;
    _debug = debug;

    final prefs = await SharedPreferences.getInstance();
    _externalUserId = prefs.getString(_kUserId);
    _subscribed = prefs.getBool(_kSubscribed) ?? true;

    final messaging = FirebaseMessaging.instance;
    if (requestPermission) await messaging.requestPermission();

    if (!kIsWeb) await _setupLocalNotifications(androidChannelName);
    if (_isIOS && showForegroundNotifications) {
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(
      (m) => _handleOpen(PushPalNotification.fromRemoteMessage(m)),
    );
    final initial = await messaging.getInitialMessage();
    if (initial != null) {
      _handleOpen(PushPalNotification.fromRemoteMessage(initial));
    }

    messaging.onTokenRefresh.listen((t) => _setToken(t, sessionStart: false));
    unawaited(_fetchTokenAndRegister());
    unawaited(_flushOpens());
  }

  /// Asks for notification permission (Android 13+, iOS). Returns true when
  /// granted, and reports the result to PushPal.
  static Future<bool> requestPermission() async {
    final s = await FirebaseMessaging.instance.requestPermission();
    final granted = _granted(s.authorizationStatus);
    if (_token == null) {
      await _fetchTokenAndRegister();
    } else {
      await _register();
    }
    return granted;
  }

  /// Links this device to your user id so your server can target it.
  static Future<void> login(String externalUserId) async {
    _externalUserId = externalUserId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserId, externalUserId);
    await _register();
  }

  /// Unlinks the user. The device keeps receiving pushes sent to everyone.
  static Future<void> logout() async {
    _externalUserId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserId);
    await _register(clearUser: true);
  }

  /// Sets data tags for segmentation. A null value removes that tag.
  /// Values are stored as strings.
  static Future<void> setTags(Map<String, Object?> tags) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = _readMap(prefs.getString(_kPendingTags));
    tags.forEach((k, v) => pending[k] = v?.toString());
    await prefs.setString(_kPendingTags, jsonEncode(pending));
    await _register();
  }

  static Future<void> removeTags(List<String> keys) =>
      setTags({for (final k in keys) k: null});

  /// App-level opt in/out, e.g. for a "Notifications" switch in settings.
  static Future<void> setSubscribed(bool subscribed) async {
    _subscribed = subscribed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSubscribed, subscribed);
    await _register();
  }

  /// Removes this device from PushPal and deletes its FCM token.
  static Future<void> unregister() async {
    final t = _token;
    if (t == null) return;
    await _post('/api/v1/devices/unregister', {'token': t});
    await FirebaseMessaging.instance.deleteToken();
    _token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
  }

  // ------------------------------------------------------------- internals

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static String get _platform => kIsWeb
      ? 'WEB'
      : _isIOS
      ? 'IOS'
      : 'ANDROID';

  static bool _granted(AuthorizationStatus s) =>
      s == AuthorizationStatus.authorized ||
      s == AuthorizationStatus.provisional;

  static void _log(String m) {
    if (_debug) debugPrint('[PushPal] $m');
  }

  static Future<void> _setupLocalNotifications(String channelName) async {
    await _local.initialize(
      settings: InitializationSettings(
        android: AndroidInitializationSettings(
          _androidIcon ?? '@mipmap/ic_launcher',
        ),
        iOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) => _handleLocalTap(r.payload),
    );
    if (_isAndroid) {
      await _local
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            AndroidNotificationChannel(
              _channelId,
              channelName,
              importance: Importance.high,
            ),
          );
      // App launched by tapping a foreground notification we showed.
      final launch = await _local.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _handleLocalTap(launch!.notificationResponse?.payload);
      }
    }
  }

  static void _handleLocalTap(String? payload) {
    if (payload == null) return;
    try {
      final p = jsonDecode(payload) as Map<String, dynamic>;
      _handleOpen(
        PushPalNotification.fromData(
          (p['data'] as Map?)?.cast<String, dynamic>() ?? {},
          title: p['title'] as String?,
          body: p['body'] as String?,
          imageUrl: p['image'] as String?,
        ),
      );
    } catch (_) {}
  }

  static Future<void> _onForegroundMessage(RemoteMessage m) async {
    final n = PushPalNotification.fromRemoteMessage(m);
    _received.add(n);
    // iOS shows it via presentation options; Android needs a local one.
    if (!_isAndroid || !_showForeground || m.notification == null) return;
    AndroidBitmap<Object>? picture;
    if (n.imageUrl != null) {
      try {
        final res = await http
            .get(Uri.parse(n.imageUrl!))
            .timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          picture = ByteArrayAndroidBitmap(res.bodyBytes);
        }
      } catch (_) {}
    }
    await _local.show(
      id: m.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch,
      title: n.title,
      body: n.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Notifications',
          importance: Importance.high,
          priority: Priority.high,
          icon: _androidIcon,
          styleInformation: picture != null
              ? BigPictureStyleInformation(picture, hideExpandedLargeIcon: true)
              : BigTextStyleInformation(n.body ?? ''),
        ),
      ),
      payload: jsonEncode({
        'title': n.title,
        'body': n.body,
        'image': n.imageUrl,
        'data': n.data,
      }),
    );
  }

  static void _handleOpen(PushPalNotification n) {
    if (_opened.hasListener) {
      _opened.add(n);
    } else {
      _openedPending.add(n);
    }
    final id = n.campaignId;
    if (id != null) unawaited(_trackOpen(id));
  }

  static Future<void> _trackOpen(String campaignId) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_kPendingOpens) ?? [];
    if (!pending.contains(campaignId)) pending.add(campaignId);
    await prefs.setStringList(_kPendingOpens, pending);
    await _flushOpens();
  }

  /// Opens are queued so a tap before the token is known still counts.
  static Future<void> _flushOpens() async {
    final t = _token;
    if (t == null) return;
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_kPendingOpens) ?? [];
    final left = <String>[];
    for (final id in pending) {
      final ok = await _post('/api/v1/events/open', {
        'token': t,
        'campaignId': id,
      });
      if (!ok) left.add(id);
    }
    await prefs.setStringList(_kPendingOpens, left);
  }

  static Future<void> _fetchTokenAndRegister() async {
    try {
      final messaging = FirebaseMessaging.instance;
      if (_isIOS) {
        // getToken fails on iOS until APNs hands over its token.
        for (var i = 0; i < 10; i++) {
          if (await messaging.getAPNSToken() != null) break;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      final t = await messaging.getToken(vapidKey: _vapidKey);
      if (t != null) await _setToken(t, sessionStart: true);
    } catch (e) {
      _log('getToken failed: $e');
    }
  }

  static bool _sessionCounted = false;

  static Future<void> _setToken(String t, {required bool sessionStart}) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_kToken);
    _token = t;
    await prefs.setString(_kToken, t);
    await _register(
      previousToken: previous != t ? previous : null,
      sessionStart: sessionStart && !_sessionCounted,
    );
    if (sessionStart) _sessionCounted = true;
    unawaited(_flushOpens());
  }

  /// Serialises registrations; a call made while one is in flight runs once
  /// more afterwards with the latest state.
  static Future<void> _register({
    String? previousToken,
    bool sessionStart = false,
    bool clearUser = false,
  }) async {
    if (_token == null || _appKey == null) return;
    if (_registering != null) {
      _registerAgain = true;
      return _registering;
    }
    final run = _doRegister(previousToken, sessionStart, clearUser);
    _registering = run;
    try {
      await run;
    } finally {
      _registering = null;
    }
    if (_registerAgain) {
      _registerAgain = false;
      await _register();
    }
  }

  static Future<void> _doRegister(
    String? previousToken,
    bool sessionStart,
    bool clearUser,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final tags = _readMap(prefs.getString(_kPendingTags));
    NotificationSettings? settings;
    try {
      settings = await FirebaseMessaging.instance.getNotificationSettings();
    } catch (_) {}

    final body = <String, dynamic>{
      ...await _deviceFacts(),
      'token': _token,
      'platform': _platform,
      'subscribed': _subscribed,
      if (settings != null)
        'notificationsEnabled': _granted(settings.authorizationStatus),
      if (_externalUserId != null || clearUser)
        'externalUserId': _externalUserId,
      if (previousToken != null) 'previousToken': previousToken,
      if (sessionStart) 'sessionStart': true,
      if (tags.isNotEmpty) 'tags': tags,
    };
    final ok = await _post('/api/v1/devices', body);
    if (ok && tags.isNotEmpty) {
      // Keep tags set while this request was in flight.
      final now = _readMap(prefs.getString(_kPendingTags));
      tags.forEach((k, v) {
        if (now.containsKey(k) && now[k] == v) now.remove(k);
      });
      await prefs.setString(_kPendingTags, jsonEncode(now));
    }
  }

  static Future<Map<String, dynamic>> _deviceFacts() async {
    if (_facts != null) return _facts!;
    final facts = <String, dynamic>{'sdkVersion': sdkVersion};
    try {
      final info = await PackageInfo.fromPlatform();
      facts['appVersion'] = info.version;
      facts['appBuild'] = info.buildNumber;
    } catch (_) {}
    try {
      final d = DeviceInfoPlugin();
      if (_isAndroid) {
        final a = await d.androidInfo;
        facts['deviceModel'] = '${a.manufacturer} ${a.model}';
        facts['osVersion'] = 'Android ${a.version.release}';
      } else if (_isIOS) {
        final i = await d.iosInfo;
        facts['deviceModel'] = i.utsname.machine;
        facts['osVersion'] = '${i.systemName} ${i.systemVersion}';
      } else if (kIsWeb) {
        final w = await d.webBrowserInfo;
        facts['deviceModel'] = w.browserName.name;
      }
    } catch (_) {}
    try {
      facts['timezone'] = (await FlutterTimezone.getLocalTimezone()).identifier;
    } catch (_) {}
    final locale = PlatformDispatcher.instance.locale;
    facts['locale'] = locale.countryCode != null
        ? '${locale.languageCode}_${locale.countryCode}'
        : locale.languageCode;
    if (locale.countryCode?.length == 2) facts['country'] = locale.countryCode;
    for (final k in ['appVersion', 'appBuild', 'deviceModel', 'osVersion']) {
      final v = facts[k];
      if (v is String && v.length > 32 && k != 'deviceModel') {
        facts[k] = v.substring(0, 32);
      }
    }
    return _facts = facts;
  }

  static Map<String, dynamic> _readMap(String? raw) {
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  static Future<bool> _post(String path, Map<String, dynamic> body) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await http
            .post(
              Uri.parse('$_baseUrl$path'),
              headers: {
                'Content-Type': 'application/json',
                'X-App-Key': _appKey!,
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode < 300) return true;
        _log('$path → ${res.statusCode} ${res.body}');
        // Client errors will not fix themselves on retry.
        if (res.statusCode < 500 && res.statusCode != 429) return false;
      } catch (e) {
        _log('$path failed: $e');
      }
      await Future<void>.delayed(Duration(seconds: 2 << attempt));
    }
    return false;
  }
}
