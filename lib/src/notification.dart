import 'package:firebase_messaging/firebase_messaging.dart';

/// A received or tapped PushPal notification.
class PushPalNotification {
  const PushPalNotification({
    this.title,
    this.body,
    this.imageUrl,
    this.campaignId,
    this.route,
    this.url,
    this.data = const {},
  });

  factory PushPalNotification.fromData(
    Map<String, dynamic> data, {
    String? title,
    String? body,
    String? imageUrl,
  }) {
    final strings = data.map((k, v) => MapEntry(k, '$v'));
    return PushPalNotification(
      title: title,
      body: body,
      imageUrl: imageUrl,
      campaignId: strings['pushpal_campaign_id'],
      route: strings['route'],
      url: strings['url'],
      data: strings,
    );
  }

  factory PushPalNotification.fromRemoteMessage(RemoteMessage m) =>
      PushPalNotification.fromData(
        m.data,
        title: m.notification?.title,
        body: m.notification?.body,
        imageUrl:
            m.notification?.android?.imageUrl ?? m.notification?.apple?.imageUrl,
      );

  final String? title;
  final String? body;
  final String? imageUrl;

  /// Set for pushes sent by PushPal; used for open tracking.
  final String? campaignId;

  /// In-app route set on the campaign (`route` field).
  final String? route;

  /// External URL set on the campaign (`url` field).
  final String? url;

  /// Every data key/value, including your custom `data`.
  final Map<String, String> data;

  @override
  String toString() =>
      'PushPalNotification(title: $title, route: $route, url: $url, data: $data)';
}
