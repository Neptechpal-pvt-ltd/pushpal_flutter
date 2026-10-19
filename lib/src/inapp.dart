import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'client.dart';
import 'notification.dart';

const _kImpressions = 'pushpal.inapp_impressions';

/// A rule-based or live in-app message.
class PushPalInAppMessage {
  PushPalInAppMessage.fromJson(Map<String, dynamic> j, {this.live = false})
      : id = '${j['id']}',
        layout = '${j['layout'] ?? 'MODAL'}',
        title = '${j['title'] ?? ''}',
        body = '${j['body'] ?? ''}',
        imageUrl = j['imageUrl'] as String?,
        route = j['route'] as String?,
        url = j['url'] as String?,
        buttons = ((j['buttons'] as List?) ?? [])
            .map((b) =>
                PushPalButton.fromJson((b as Map).cast<String, dynamic>()))
            .toList(),
        triggerEvent = j['triggerEvent'] as String?,
        triggerRules = ((j['triggerRules'] as List?) ?? [])
            .map((r) => (r as Map).cast<String, dynamic>())
            .toList(),
        maxImpressions = j['maxImpressions'] as int?,
        perDays = j['perDays'] as int?,
        priority = (j['priority'] as int?) ?? 0;

  final String id;
  final String layout;
  final String title;
  final String body;
  final String? imageUrl;
  final String? route;
  final String? url;
  final List<PushPalButton> buttons;
  final String? triggerEvent;
  final List<Map<String, dynamic>> triggerRules;
  final int? maxImpressions;
  final int? perDays;
  final int priority;
  final bool live;
}

/// Internal: fetches rules, evaluates triggers and caps, renders messages.
class InAppController {
  InAppController._();
  static final instance = InAppController._();

  GlobalKey<NavigatorState>? _navigator;
  Future<void> Function()? _onPromptPush;
  bool _enabled = false;
  bool _live = true;
  bool paused = false;
  bool _showing = false;
  List<PushPalInAppMessage> _rules = [];
  DateTime? _fetchedAt;
  final _triggers = <String, Object?>{};
  final _queue = <PushPalInAppMessage>[];
  http.Client? _sse;

  void enable(
      {required GlobalKey<NavigatorState> navigatorKey,
      Future<void> Function()? onPromptPush,
      bool live = true}) {
    _navigator = navigatorKey;
    _onPromptPush = onPromptPush;
    _live = live;
    _enabled = true;
    refresh();
  }

  void setTrigger(String key, Object? value) {
    if (value == null) {
      _triggers.remove(key);
    } else {
      _triggers[key] = value;
    }
    _evaluate(null);
  }

  /// Fetch rules (cached 5 minutes) and evaluate session-start messages.
  Future<void> refresh() async {
    if (!_enabled || PushPal.token == null) return;
    if (_live && _sse == null) unawaited(_connectLive());
    if (_fetchedAt != null &&
        DateTime.now().difference(_fetchedAt!) < const Duration(minutes: 5)) {
      _evaluate(null);
      return;
    }
    final r = await PushPal.get('/api/v1/inapp', {'token': PushPal.token!});
    if (r == null) return;
    _rules = ((r['messages'] as List?) ?? [])
        .map((m) =>
            PushPalInAppMessage.fromJson((m as Map).cast<String, dynamic>()))
        .toList()
      ..sort((a, b) => b.priority.compareTo(a.priority));
    _fetchedAt = DateTime.now();
    _evaluate('session_start');
  }

  void onEvent(String event) => _evaluate(event);

  bool _rulesMatch(PushPalInAppMessage m) {
    for (final r in m.triggerRules) {
      final v = _triggers[r['key']];
      final want = r['value']?.toString();
      switch (r['op']) {
        case 'exists':
          if (v == null) return false;
        case 'neq':
          if (v?.toString() == want) return false;
        case 'gt':
          if (v == null ||
              (num.tryParse('$v') ?? 0) <= (num.tryParse(want ?? '') ?? 0))
            return false;
        case 'lt':
          if (v == null ||
              (num.tryParse('$v') ?? 0) >= (num.tryParse(want ?? '') ?? 0))
            return false;
        default:
          if (v?.toString() != want) return false;
      }
    }
    return true;
  }

  Future<bool> _underCap(PushPalInAppMessage m) async {
    if (m.maxImpressions == null) return true;
    final prefs = await SharedPreferences.getInstance();
    final all = (jsonDecode(prefs.getString(_kImpressions) ?? '{}') as Map)
        .cast<String, dynamic>();
    final times = ((all[m.id] as List?) ?? [])
        .map((t) => DateTime.fromMillisecondsSinceEpoch(t as int));
    final window = m.perDays == null
        ? times
        : times.where((t) => DateTime.now().difference(t).inDays < m.perDays!);
    return window.length < m.maxImpressions!;
  }

  Future<void> _countImpression(PushPalInAppMessage m) async {
    final prefs = await SharedPreferences.getInstance();
    final all = (jsonDecode(prefs.getString(_kImpressions) ?? '{}') as Map)
        .cast<String, dynamic>();
    final list = ((all[m.id] as List?) ?? []).cast<int>().toList()
      ..add(DateTime.now().millisecondsSinceEpoch);
    all[m.id] = list.length > 50 ? list.sublist(list.length - 50) : list;
    await prefs.setString(_kImpressions, jsonEncode(all));
  }

  Future<void> _evaluate(String? event) async {
    if (!_enabled) return;
    for (final m in _rules) {
      final trigger = m.triggerEvent ?? 'session_start';
      if (event != null && trigger != event) continue;
      if (event == null && m.triggerRules.isEmpty) continue;
      if (!_rulesMatch(m) || !await _underCap(m)) continue;
      _show(m);
      return;
    }
  }

  void _show(PushPalInAppMessage m) {
    if (_queue.any((x) => x.id == m.id)) return;
    _queue.add(m);
    flush();
  }

  /// Show the next queued message unless paused or one is already up.
  Future<void> flush() async {
    if (paused || _showing || _queue.isEmpty) return;
    if (_navigator?.currentContext == null) return;
    final m = _queue.removeAt(0);
    _showing = true;
    if (!m.live) {
      await _countImpression(m);
      unawaited(_report(m, 'impression'));
    }
    String? tapped;
    try {
      final ctx = _navigator?.currentContext;
      if (ctx == null || !ctx.mounted) return;
      tapped = await _present(ctx, m);
    } finally {
      _showing = false;
    }
    final button = m.buttons.where((b) => b.id == tapped).firstOrNull;
    if (tapped == null) {
      if (!m.live) unawaited(_report(m, 'dismiss'));
    } else {
      if (!m.live) unawaited(_report(m, 'click', button: tapped));
      if (button?.action == 'prompt_push') await _onPromptPush?.call();
      final route = button?.route ?? (button == null ? m.route : null);
      final url = button?.url ?? (button == null ? m.url : null);
      if (route != null || url != null) {
        PushPal.trackNotificationOpen({
          if (route != null) 'route': route,
          if (url != null) 'url': url,
          if (m.live) 'pushpal_campaign_id': m.id
        });
      }
    }
    unawaited(flush());
  }

  Future<void> _report(PushPalInAppMessage m, String type,
      {String? button}) async {
    if (PushPal.token == null) return;
    await PushPal.post('/api/v1/inapp/event', {
      'token': PushPal.token,
      'id': m.id,
      'type': type,
      if (button != null) 'button': button
    });
  }

  /// Returns the tapped button id ("_body" for a tap on the message), null if dismissed.
  Future<String?> _present(BuildContext ctx, PushPalInAppMessage m) {
    final buttons = m.buttons.isEmpty
        ? [const PushPalButton(id: '_ok', title: 'OK', action: 'dismiss')]
        : m.buttons;
    Widget content(BuildContext c) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (m.imageUrl != null)
              ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(m.imageUrl!,
                      height: 160,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox())),
            const SizedBox(height: 12),
            Text(m.title, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(m.body, style: Theme.of(c).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Row(
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: i == 0
                        ? FilledButton(
                            onPressed: () => Navigator.of(c).pop(
                                buttons[i].action == 'dismiss'
                                    ? null
                                    : buttons[i].id),
                            child: Text(buttons[i].title))
                        : OutlinedButton(
                            onPressed: () => Navigator.of(c).pop(
                                buttons[i].action == 'dismiss'
                                    ? null
                                    : buttons[i].id),
                            child: Text(buttons[i].title)),
                  ),
                ],
              ],
            ),
          ],
        );

    if (m.layout == 'BANNER') {
      final completer = Completer<String?>();
      late OverlayEntry entry;
      Timer? timer;
      void close(String? v) {
        timer?.cancel();
        if (entry.mounted) entry.remove();
        if (!completer.isCompleted) completer.complete(v);
      }

      entry = OverlayEntry(
        builder: (c) => Positioned(
          top: MediaQuery.of(c).padding.top + 8,
          left: 12,
          right: 12,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () =>
                  close(m.buttons.isNotEmpty ? m.buttons.first.id : '_body'),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(m.title,
                              style: Theme.of(c).textTheme.titleSmall),
                          Text(m.body,
                              style: Theme.of(c).textTheme.bodySmall,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis),
                        ]),
                  ),
                  IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => close(null)),
                ]),
              ),
            ),
          ),
        ),
      );
      Overlay.of(ctx).insert(entry);
      timer = Timer(const Duration(seconds: 8), () => close(null));
      return completer.future;
    }
    if (m.layout == 'FULLSCREEN') {
      return Navigator.of(ctx).push<String?>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (c) => Scaffold(
          appBar: AppBar(
              leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(c).pop())),
          body: SafeArea(
              child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(child: content(c)))),
        ),
      ));
    }
    return showDialog<String?>(
      context: ctx,
      builder: (c) => Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(padding: const EdgeInsets.all(20), child: content(c))),
    );
  }

  /// Server-sent events for live in-app messages; reconnects with backoff.
  Future<void> _connectLive() async {
    var delay = 2;
    while (_enabled && _live && PushPal.token != null) {
      final client = http.Client();
      _sse = client;
      try {
        final uri = Uri.parse('${PushPal.baseUrl}/api/v1/live').replace(
            queryParameters: {'key': PushPal.appKey!, 'token': PushPal.token!});
        final res = await client.send(
            http.Request('GET', uri)..headers['Accept'] = 'text/event-stream');
        if (res.statusCode != 200) throw Exception('live ${res.statusCode}');
        delay = 2;
        var event = '';
        await for (final line in res.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (line.startsWith('event:')) event = line.substring(6).trim();
          if (line.startsWith('data:') && event == 'message') {
            final j = (jsonDecode(line.substring(5).trim()) as Map)
                .cast<String, dynamic>();
            _show(PushPalInAppMessage.fromJson(
                {...j, 'layout': j['layout'] ?? 'BANNER'},
                live: true));
          }
        }
      } catch (_) {
      } finally {
        client.close();
        _sse = null;
      }
      await Future<void>.delayed(Duration(seconds: delay));
      delay = (delay * 2).clamp(2, 120);
    }
  }
}
