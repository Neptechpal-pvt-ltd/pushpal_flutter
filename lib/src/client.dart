import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'inapp.dart';
import 'notification.dart';

const _kToken = 'pushpal.token';
const _kChannel = 'pushpal.channel';
const _kUserId = 'pushpal.user_id';
const _kSubscribed = 'pushpal.subscribed';
const _kPendingTags = 'pushpal.pending_tags';
const _kPendingOpens = 'pushpal.pending_opens';
const _kInstalled = 'pushpal.installed';

/// Delivery route for a registered token.
enum PushPalChannel { fcm, apns, webpush }

/// PushPal client. Call [configure] once, then [attachFirebase] (or
/// [registerPushToken] if you manage tokens yourself).
class PushPal {
  PushPal._();

  static const sdkVersion = '1.1.0';
  static const defaultBaseUrl = 'https://push.neptechpal.com.np';

  static String? _appKey;
  static String _baseUrl = defaultBaseUrl;
  static bool _debug = false;
  static bool _trackSessions = true;
  static String? _appVersion;
  static String? _appBuild;
  static String? _deviceModel;
  static String? _timezone;

  static String? _token;
  static PushPalChannel _channel = PushPalChannel.fcm;
  static String? _userId;
  static bool _subscribed = true;
  static bool? _permission;
  static bool _sessionCounted = false;
  static String? _pendingClickId;
  static Future<void>? _registering;
  static bool _again = false;

  static void Function(String url)? _onUrl;
  static final _openedQueue = <PushPalNotification>[];
  static final StreamController<PushPalNotification> _opened =
      StreamController.broadcast(
    onListen: () {
      for (final n in _openedQueue) {
        _opened.add(n);
      }
      _openedQueue.clear();
    },
  );
  static final _received = StreamController<PushPalNotification>.broadcast();

  /// Tapped notifications, including the one that launched the app.
  static Stream<PushPalNotification> get onNotificationOpened => _opened.stream;

  /// Notifications that arrive while the app is in the foreground. On Android,
  /// show them yourself (e.g. flutter_local_notifications) — see the README.
  static Stream<PushPalNotification> get onNotificationReceived =>
      _received.stream;

  static String? get token => _token;
  static String? get userId => _userId;
  static bool get isSubscribed => _subscribed;

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static String get _platform => kIsWeb ? 'WEB' : (_isIOS ? 'IOS' : 'ANDROID');

  /// Set up the client. [appKey] is the public client key (`pk_…`); server
  /// keys are rejected. [appVersion]/[deviceModel]/[timezone] are optional
  /// facts for segments (pass package_info_plus / flutter_timezone values).
  static void configure({
    required String appKey,
    String baseUrl = defaultBaseUrl,
    bool debug = false,
    bool trackSessions = true,
    String? appVersion,
    String? appBuild,
    String? deviceModel,
    String? timezone,
  }) {
    if (appKey.startsWith('sk_')) {
      throw ArgumentError(
          'PushPal: that is a server key. Use the client key (pk_…) in apps.');
    }
    _appKey = appKey;
    _baseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    _debug = debug;
    _trackSessions = trackSessions;
    _appVersion = appVersion;
    _appBuild = appBuild;
    _deviceModel = deviceModel;
    _timezone = timezone;
    unawaited(_restore());
  }

  /// Wire up firebase_messaging: permission, token (and rotation), opens from
  /// background and cold-start taps. Pass `FirebaseMessaging.instance` and its
  /// static streams; the types are dynamic so any firebase_messaging version works.
  static Future<void> attachFirebase(
    dynamic messaging, {
    Stream<dynamic>? onMessageOpenedApp,
    Stream<dynamic>? onMessage,
    void Function(String url)? onUrl,
    bool requestPermission = true,
    bool useApnsToken = false,
    String? vapidKey,
  }) async {
    _requireConfigured();
    _onUrl = onUrl;
    if (_isIOS) {
      try {
        await messaging.setForegroundNotificationPresentationOptions(
            alert: true, badge: true, sound: true);
      } catch (_) {}
    }
    if (requestPermission) {
      try {
        final s = await messaging.requestPermission();
        _permission = '${s.authorizationStatus}'.contains('authorized') ||
            '${s.authorizationStatus}'.contains('provisional');
      } catch (e) {
        _log('requestPermission failed: $e');
      }
    }
    onMessageOpenedApp
        ?.listen((m) => _handleOpen(PushPalNotification.fromRemoteMessage(m)));
    onMessage?.listen((m) {
      final n = PushPalNotification.fromRemoteMessage(m);
      unawaited(reportReceived(n.data));
      _received.add(n);
    });
    try {
      final initial = await messaging.getInitialMessage();
      if (initial != null)
        _handleOpen(PushPalNotification.fromRemoteMessage(initial));
    } catch (_) {}
    try {
      (messaging.onTokenRefresh as Stream)
          .listen((t) => registerPushToken('$t'));
    } catch (_) {}

    String? token;
    var channel = PushPalChannel.fcm;
    try {
      if (_isIOS) {
        // Wait for APNs; FCM's getToken fails until it arrives.
        String? apns;
        for (var i = 0; i < 10 && apns == null; i++) {
          apns = await messaging.getAPNSToken() as String?;
          if (apns == null)
            await Future<void>.delayed(const Duration(seconds: 1));
        }
        if (useApnsToken && apns != null) {
          token = apns;
          channel = PushPalChannel.apns;
        } else if (useApnsToken) {
          _log(
              'No APNs token (simulator or missing Push Notifications capability); falling back to FCM.');
        }
      }
      token ??= await messaging.getToken(vapidKey: vapidKey) as String?;
    } catch (e) {
      _log('getToken failed: $e');
    }
    if (token != null) await registerPushToken(token, channel: channel);
  }

  /// Register a token you obtained yourself (FCM, raw APNs hex, or a web push subscription JSON).
  static Future<void> registerPushToken(String token,
      {PushPalChannel? channel, bool? notificationsEnabled}) async {
    _requireConfigured();
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_kToken);
    _channel = channel ?? channelForToken(token);
    if (notificationsEnabled != null) _permission = notificationsEnabled;
    _token = token;
    await prefs.setString(_kToken, token);
    await prefs.setString(_kChannel, _channel.name);
    final firstInstall = !(prefs.getBool(_kInstalled) ?? false);
    await _register(
        previousToken: previous != token ? previous : null,
        sessionStart: !_sessionCounted);
    _sessionCounted = true;
    if (firstInstall) await prefs.setBool(_kInstalled, true);
    unawaited(_flushOpens());
    InAppController.instance.refresh();
  }

  /// Guess the channel: 64 hex chars = APNs, JSON = web push, else FCM.
  static PushPalChannel channelForToken(String token) {
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(token))
      return PushPalChannel.apns;
    if (token.trimLeft().startsWith('{')) return PushPalChannel.webpush;
    return PushPalChannel.fcm;
  }

  /// Tie this device to a person. [signature] = hex HMAC-SHA256(identity
  /// secret, userId) from YOUR backend; required when identity verification is on.
  static Future<Map<String, dynamic>?> identify(String userId,
      {String? signature,
      Map<String, Object?>? attributes,
      String? email,
      String? phone}) async {
    _userId = userId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserId, userId);
    if (_token == null) return null;
    return _post('/api/v1/identify', {
      'token': _token,
      'externalUserId': userId,
      if (signature != null) 'signature': signature,
      if (attributes != null) 'attributes': attributes,
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
    });
  }

  /// Detach the device from the person (sign-out). Not an unsubscribe.
  static Future<void> logout() async {
    _userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserId);
    if (_token != null) await _post('/api/v1/logout', {'token': _token});
  }

  /// Durable opt-out: survives sign-in and reinstall for identified people.
  /// Only a server key can lift it. Don't use it for sign-out.
  static Future<void> unsubscribe() async {
    _subscribed = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSubscribed, false);
    if (_token != null) await _post('/api/v1/unsubscribe', {'token': _token});
  }

  /// Soft, device-level switch (e.g. a settings toggle).
  static Future<void> setSubscribed(bool subscribed) async {
    _subscribed = subscribed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSubscribed, subscribed);
    await _register();
  }

  /// Data tags (string values) for segments. A null value removes a tag.
  static Future<void> setTags(Map<String, Object?> tags) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = _readMap(prefs.getString(_kPendingTags));
    tags.forEach((k, v) => pending[k] = v?.toString());
    await prefs.setString(_kPendingTags, jsonEncode(pending));
    await _register();
  }

  static Future<void> removeTags(List<String> keys) =>
      setTags({for (final k in keys) k: null});

  /// Custom event for segments, journeys and in-app triggers.
  static Future<void> track(String event,
      {Map<String, Object?>? properties}) async {
    InAppController.instance.onEvent(event);
    if (_token == null) return;
    await _post('/api/v1/track', {
      'token': _token,
      'event': event,
      if (properties != null) 'properties': properties
    });
  }

  /// Revenue, attributed to the last opened campaign and the install's tracking link.
  static Future<void> trackPurchase(double amount,
      {String currency = 'USD',
      String? productId,
      Map<String, Object?>? properties}) async {
    if (_token == null) return;
    await _post('/api/v1/purchase', {
      'token': _token,
      'amount': amount,
      'currency': currency,
      if (productId != null) 'productId': productId,
      if (properties != null) 'properties': properties
    });
  }

  /// Attribute an app open to a PushPal tracking link (call from your deep-link handler).
  static Future<String?> handleDeepLink(Uri url) async {
    final click = url.queryParameters['pp_click'];
    if (_token == null) {
      _pendingClickId = click;
      return null;
    }
    final r = await _post(
        '/api/v1/deeplink', {'token': _token, 'url': url.toString()});
    return r?['deepLink'] as String?;
  }

  /// Android Play install referrer (from the play_install_referrer package).
  static void setInstallReferrer(String referrer) {
    final m =
        RegExp(r'pp_click=([\w-]+)').firstMatch(Uri.decodeComponent(referrer));
    if (m != null) _pendingClickId = m.group(1);
  }

  /// Manually report a tapped notification (when you show notifications yourself).
  static void trackNotificationOpen(Map<String, dynamic> data,
          {String? buttonId}) =>
      _handleOpen(PushPalNotification.parse(data, buttonId: buttonId));

  /// Confirmed delivery. Called automatically for foreground messages; call it
  /// from your `FirebaseMessaging.onBackgroundMessage` handler too (works
  /// without [configure] — the receipt URL travels in the push).
  static Future<void> reportReceived(Map<String, dynamic> data) async {
    final id = data['pushpal_msg']?.toString();
    final base = data['pushpal_base']?.toString();
    if (id == null || base == null) return;
    try {
      await http
          .post(Uri.parse('$base/api/v1/r/$id'))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  // ------------------------------------------------------------ topics

  /// Preference center: the app's topics with this device's choice.
  static Future<List<Map<String, dynamic>>> topics() async {
    if (_token == null) return [];
    final r = await _get('/api/v1/topics', {'token': _token!});
    return ((r?['topics'] as List?) ?? [])
        .map((t) => (t as Map).cast<String, dynamic>())
        .toList();
  }

  static Future<void> setTopic(String key, bool subscribed) async {
    if (_token == null) return;
    await _post('/api/v1/topics',
        {'token': _token, 'topic': key, 'subscribed': subscribed});
  }

  // ------------------------------------------------------------- inbox

  static Future<List<PushPalInboxMessage>> inbox({int limit = 50}) async {
    if (_token == null) return [];
    final r =
        await _get('/api/v1/inbox', {'token': _token!, 'limit': '$limit'});
    final list = (r?['messages'] as List?) ?? [];
    return list
        .map((m) =>
            PushPalInboxMessage.fromJson((m as Map).cast<String, dynamic>()))
        .toList();
  }

  static Future<void> inboxMarkRead(List<String> ids) async {
    if (_token == null || ids.isEmpty) return;
    await _post('/api/v1/inbox/read', {'token': _token, 'ids': ids});
  }

  // ------------------------------------------------------------ in-app

  /// Show rule-based in-app messages as routes in your navigator, and live
  /// messages pushed from campaigns with the "Live in-app" channel.
  static void enableInAppMessages(
      {required GlobalKey<NavigatorState> navigatorKey,
      Future<void> Function()? onPromptPush,
      bool live = true}) {
    InAppController.instance.enable(
        navigatorKey: navigatorKey, onPromptPush: onPromptPush, live: live);
  }

  /// Local values tested by in-app trigger rules. They never leave the device.
  static void setTrigger(String key, Object? value) =>
      InAppController.instance.setTrigger(key, value);

  static void pauseInAppMessages() => InAppController.instance.paused = true;
  static void resumeInAppMessages() {
    InAppController.instance.paused = false;
    InAppController.instance.flush();
  }

  static bool get inAppMessagesPaused => InAppController.instance.paused;

  // --------------------------------------------------------- diagnostics

  /// Prints a checklist (debug builds) and returns it.
  static Future<List<PushPalCheck>> runSetupTest() async {
    _requireConfigured();
    final r =
        await _get('/api/v1/sdk/check', {if (_token != null) 'token': _token!});
    final checks = ((r?['checks'] as List?) ?? [])
        .map((c) => PushPalCheck.fromJson((c as Map).cast<String, dynamic>()))
        .toList();
    if (kDebugMode) {
      debugPrint(
          '[PushPal] setup test for ${r?['app'] ?? '?'} (SDK $sdkVersion):');
      for (final c in checks) {
        debugPrint('[PushPal]   $c');
      }
      if (_onUrl == null)
        debugPrint(
            '[PushPal]   – No onUrl handler: URLs from notifications will be dropped.');
    }
    return checks;
  }

  // ----------------------------------------------------------- internals

  static void _requireConfigured() {
    if (_appKey == null)
      throw StateError('Call PushPal.configure(appKey: …) first.');
  }

  static void _log(String m) {
    if (_debug) debugPrint('[PushPal] $m');
  }

  static Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString(_kUserId);
    _subscribed = prefs.getBool(_kSubscribed) ?? true;
    _token ??= prefs.getString(_kToken);
  }

  static void _handleOpen(PushPalNotification n) {
    if (_opened.hasListener) {
      _opened.add(n);
    } else {
      _openedQueue.add(n);
    }
    final url = n.targetUrl;
    if (url != null) {
      if (_onUrl != null) {
        _onUrl!(url);
      } else {
        _log('Notification URL dropped (no onUrl handler): $url');
      }
    }
    if (n.campaignId != null) unawaited(_queueOpen(n));
  }

  static Future<void> _queueOpen(PushPalNotification n) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_kPendingOpens) ?? [];
    pending.add(jsonEncode({
      'campaignId': n.campaignId,
      'variant': n.variant,
      'button': n.buttonId
    }));
    await prefs.setStringList(_kPendingOpens, pending);
    await _flushOpens();
  }

  /// Opens are queued so a tap before the token is known still counts.
  static Future<void> _flushOpens() async {
    if (_token == null) return;
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_kPendingOpens) ?? [];
    final left = <String>[];
    for (final raw in pending) {
      final o = jsonDecode(raw) as Map<String, dynamic>;
      final r = await _post('/api/v1/events/open', {
        'token': _token,
        'campaignId': o['campaignId'],
        if (o['variant'] != null) 'variant': o['variant'],
        if (o['button'] != null) 'button': o['button'],
      });
      if (r == null) left.add(raw);
    }
    await prefs.setStringList(_kPendingOpens, left);
  }

  static Future<void> _register(
      {String? previousToken, bool sessionStart = false}) async {
    if (_token == null || _appKey == null) return;
    if (_registering != null) {
      _again = true;
      return _registering;
    }
    final run = _doRegister(previousToken, sessionStart);
    _registering = run;
    try {
      await run;
    } finally {
      _registering = null;
    }
    if (_again) {
      _again = false;
      await _register();
    }
  }

  static Future<void> _doRegister(
      String? previousToken, bool sessionStart) async {
    final prefs = await SharedPreferences.getInstance();
    final tags = _readMap(prefs.getString(_kPendingTags));
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    final body = <String, dynamic>{
      'token': _token,
      'platform': _platform,
      'channel': _channel.name.toUpperCase(),
      'sdkVersion': 'flutter-$sdkVersion',
      'subscribed': _subscribed,
      'trackSessions': _trackSessions,
      'utcOffsetMin': DateTime.now().timeZoneOffset.inMinutes,
      'locale': locale.countryCode != null
          ? '${locale.languageCode}_${locale.countryCode}'
          : locale.languageCode,
      if (locale.countryCode?.length == 2 &&
          RegExp(r'^[A-Z]{2}$').hasMatch(locale.countryCode!))
        'country': locale.countryCode,
      if (_timezone != null) 'timezone': _timezone,
      if (_appVersion != null) 'appVersion': _appVersion,
      if (_appBuild != null) 'appBuild': _appBuild,
      if (_deviceModel != null) 'deviceModel': _deviceModel,
      if (_permission != null) 'notificationsEnabled': _permission,
      if (previousToken != null) 'previousToken': previousToken,
      if (sessionStart) 'sessionStart': true,
      if (_pendingClickId != null) 'clickId': _pendingClickId,
      if (tags.isNotEmpty) 'tags': tags,
    };
    final r = await _post('/api/v1/devices', body);
    if (r == null) return;
    _pendingClickId = null;
    final deepLink = (r['attribution'] as Map?)?['deepLink'] as String?;
    if (deepLink != null)
      _handleOpen(PushPalNotification(
          route: deepLink,
          data: {'route': deepLink, 'pushpal_attribution': 'install'}));
    if (tags.isNotEmpty) {
      final now = _readMap(prefs.getString(_kPendingTags));
      tags.forEach((k, v) {
        if (now.containsKey(k) && now[k] == v) now.remove(k);
      });
      await prefs.setString(_kPendingTags, jsonEncode(now));
    }
    // Re-link the person after a reinstall / token change.
    if (_userId != null && r['externalUserId'] != _userId)
      await identify(_userId!);
  }

  static Map<String, dynamic> _readMap(String? raw) {
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  static Map<String, String> get _headers =>
      {'Content-Type': 'application/json', 'X-App-Key': _appKey!};

  /// Internal: used by the in-app controller too.
  static Future<Map<String, dynamic>?> get(
          String path, Map<String, String> query) =>
      _get(path, query);
  static Future<Map<String, dynamic>?> post(
          String path, Map<String, dynamic> body) =>
      _post(path, body);
  static String get baseUrl => _baseUrl;
  static String? get appKey => _appKey;

  static Future<Map<String, dynamic>?> _get(
      String path, Map<String, String> query) async {
    try {
      final res = await http
          .get(Uri.parse('$_baseUrl$path').replace(queryParameters: query),
              headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 300)
        return ((jsonDecode(res.body) as Map)['data'] as Map?)
                ?.cast<String, dynamic>() ??
            {};
      _log('$path → ${res.statusCode} ${res.body}');
    } catch (e) {
      _log('$path failed: $e');
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _post(
      String path, Map<String, dynamic> body) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await http
            .post(Uri.parse('$_baseUrl$path'),
                headers: _headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 15));
        if (res.statusCode < 300) {
          final data = (jsonDecode(res.body) as Map)['data'];
          return data is Map
              ? data.cast<String, dynamic>()
              : <String, dynamic>{};
        }
        _log('$path → ${res.statusCode} ${res.body}');
        if (res.statusCode < 500 && res.statusCode != 429) return null;
      } catch (e) {
        _log('$path failed: $e');
      }
      await Future<void>.delayed(Duration(seconds: 2 << attempt));
    }
    return null;
  }
}
