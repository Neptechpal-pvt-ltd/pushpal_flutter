import 'dart:convert';

/// An action button on a notification or in-app message.
class PushPalButton {
  const PushPalButton(
      {required this.id,
      required this.title,
      this.url,
      this.route,
      this.action});

  factory PushPalButton.fromJson(Map<String, dynamic> j) => PushPalButton(
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        url: j['url'] as String?,
        route: j['route'] as String?,
        action: j['action'] as String?,
      );

  final String id;
  final String title;
  final String? url;
  final String? route;

  /// In-app only: "dismiss", "open" or "prompt_push".
  final String? action;
}

/// A received or tapped PushPal notification.
class PushPalNotification {
  const PushPalNotification({
    this.title,
    this.body,
    this.imageUrl,
    this.campaignId,
    this.variant,
    this.route,
    this.url,
    this.buttons = const [],
    this.buttonId,
    this.data = const {},
  });

  /// Parse the `data` map of an FCM/APNs message (and optional notification fields).
  /// Use it with flutter_local_notifications to show buttons and images yourself.
  factory PushPalNotification.parse(Map<String, dynamic> data,
      {String? title, String? body, String? imageUrl, String? buttonId}) {
    final strings = data.map((k, v) => MapEntry(k, '$v'));
    var buttons = <PushPalButton>[];
    final raw = strings['pushpal_buttons'];
    if (raw != null) {
      try {
        buttons = (jsonDecode(raw) as List)
            .map((b) =>
                PushPalButton.fromJson((b as Map).cast<String, dynamic>()))
            .toList();
      } catch (_) {}
    }
    return PushPalNotification(
      title: title ?? strings['title'],
      body: body ?? strings['body'],
      imageUrl: imageUrl ?? strings['pushpal_image'],
      campaignId: strings['pushpal_campaign_id'],
      variant: strings['pushpal_variant'],
      route: strings['route'],
      url: strings['url'],
      buttons: buttons,
      buttonId: buttonId,
      data: strings,
    );
  }

  /// From a firebase_messaging RemoteMessage (typed dynamically, so this
  /// package does not depend on firebase_messaging).
  factory PushPalNotification.fromRemoteMessage(dynamic m) {
    final data = Map<String, dynamic>.from(m.data as Map);
    final n = m.notification;
    String? image;
    try {
      image = (n?.android?.imageUrl ?? n?.apple?.imageUrl) as String?;
    } catch (_) {}
    return PushPalNotification.parse(data,
        title: n?.title as String?, body: n?.body as String?, imageUrl: image);
  }

  final String? title;
  final String? body;
  final String? imageUrl;

  /// Set for pushes sent by PushPal; used for open tracking.
  final String? campaignId;

  /// A/B variant id, when the campaign is an A/B test.
  final String? variant;

  /// In-app route set on the campaign.
  final String? route;

  /// External URL set on the campaign.
  final String? url;

  final List<PushPalButton> buttons;

  /// The tapped action button, if any.
  final String? buttonId;

  /// Every data key/value, including your custom `data`.
  final Map<String, String> data;

  /// Route/url of the tapped button, else of the notification.
  String? get targetRoute =>
      buttons.where((b) => b.id == buttonId).map((b) => b.route).firstOrNull ??
      route;
  String? get targetUrl =>
      buttons.where((b) => b.id == buttonId).map((b) => b.url).firstOrNull ??
      url;

  @override
  String toString() =>
      'PushPalNotification(title: $title, route: $route, url: $url, button: $buttonId)';
}

/// An item in the in-app inbox.
class PushPalInboxMessage {
  PushPalInboxMessage.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        title = j['title'] as String,
        body = j['body'] as String,
        imageUrl = j['imageUrl'] as String?,
        url = j['url'] as String?,
        route = j['route'] as String?,
        read = j['readAt'] != null,
        createdAt = DateTime.parse(j['createdAt'] as String);

  final String id;
  final String title;
  final String body;
  final String? imageUrl;
  final String? url;
  final String? route;
  final bool read;
  final DateTime createdAt;
}

/// One line of [PushPal.runSetupTest].
class PushPalCheck {
  PushPalCheck.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        ok = j['ok'] as bool,
        optional = j['optional'] == true,
        message = j['message'] as String;

  final String id;
  final bool ok;
  final bool optional;
  final String message;

  @override
  String toString() => '${ok ? '✓' : optional ? '–' : '✗'} $message';
}

/// An Android notification channel defined in the PushPal dashboard
/// (Settings → Android channels). Create it with your local-notifications
/// plugin; see [PushPal.androidChannels].
class PushPalAndroidChannel {
  PushPalAndroidChannel.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        description = j['description'] as String?,
        importance = (j['importance'] as String?) ?? 'default',
        sound = j['sound'] as String?,
        vibration = j['vibration'] != false,
        lights = j['lights'] == true;

  final String id;
  final String name;
  final String? description;

  /// One of `min`, `low`, `default`, `high`, `max`.
  final String importance;

  /// Raw resource name (res/raw) or null for the system sound.
  final String? sound;
  final bool vibration;
  final bool lights;

  /// Android `NotificationManager.IMPORTANCE_*` value (1–5).
  int get importanceLevel =>
      const {
        'min': 1,
        'low': 2,
        'default': 3,
        'high': 4,
        'max': 5
      }[importance] ??
      3;
}
