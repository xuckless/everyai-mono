// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'webview_model.dart';

/// Something the native side noticed about a session webview: a browser shortcut typed in it ([key] is `l`, `r`,
/// `[`, `]` or `f`), a key the user pressed while the agent has the view ([blocked]), or the native context menu's
/// "Ask the agent about this" at [x],[y] (CSS pixels).
typedef WebviewNativeEvent = ({String token, String kind, String key, double x, double y});

/// What the webview plugin doesn't give a session browser, per platform: its own cookie store (each session's
/// browser runs in a store of its own), keeping a webview the Preview let go of live in the window, taking the
/// keyboard away from a view while the agent has it, and the browser shortcuts typed in it. Each webview is known
/// by a token the page carries in the browser's own script world ([bind]).
abstract interface class WebviewNative {
  /// The macOS bridge (`everyai/webview` in the Runner), or the plugin's own calls on Windows.
  static WebviewNative forPlatform({required bool macOS, WebViewEnvironment? environment}) =>
      macOS ? MacWebviewNative.instance : PluginWebviewNative(environment);

  Stream<WebviewNativeEvent> get events;

  /// Finds the webview whose page carries [token] (just set by the browser) and keeps hold of it.
  Future<bool> bind(String token, {String? viewId});
  Future<void> release(String token);

  /// The cookies of [token]'s store; [urls] are the addresses to read when the platform reads by address.
  Future<List<NativeCookie>> cookies(String token, {Iterable<Uri> urls = const []});
  Future<void> setCookies(String token, List<NativeCookie> cookies);
  Future<void> deleteCookies(String token, List<NativeCookie> cookies);

  /// Deletes everything [token]'s store holds (cookies, storage, caches).
  Future<void> clearData(String token);

  /// Puts [token]'s view, which the Preview just let go of, back in the window offscreen at [width]×[height] so it
  /// keeps running; true once it is there.
  Future<bool> park(String token, int width, int height);

  /// The view lost the Preview's keyboard: whatever in it had the focus gives it up.
  Future<void> unfocus(String token);

  /// While [locked] (the agent has the view), keys typed in [token]'s view are kept from it.
  Future<void> setLocked(String token, bool locked);

  /// While [on], a new offscreen webview goes into the app's window even when the app isn't the active one.
  Future<void> lendWindow(bool on);

  /// While [shown], the browser shortcuts typed in [token]'s view come as [events].
  Future<void> setShown(String token, bool shown);
}

/// The macOS side: `WebviewBridge` in `macos/Runner/MainFlutterWindow.swift`.
final class MacWebviewNative implements WebviewNative {
  MacWebviewNative._() {
    _channel.setMethodCallHandler((call) async {
      final a = (call.arguments as Map?) ?? const {};
      _events.add((
        token: '${a['token'] ?? ''}',
        kind: call.method,
        key: '${a['key'] ?? ''}',
        x: (a['x'] as num?)?.toDouble() ?? 0,
        y: (a['y'] as num?)?.toDouble() ?? 0,
      ));
      return null;
    });
  }

  static final instance = MacWebviewNative._();
  static const _channel = MethodChannel('everyai/webview');
  final _events = StreamController<WebviewNativeEvent>.broadcast();

  @override
  Stream<WebviewNativeEvent> get events => _events.stream;

  @override
  Future<bool> bind(String token, {String? viewId}) async =>
      await _channel.invokeMethod<bool>('bind', {'token': token, 'viewId': ?viewId}) ?? false;

  @override
  Future<void> release(String token) => _channel.invokeMethod<void>('release', {'token': token});

  @override
  Future<List<NativeCookie>> cookies(String token, {Iterable<Uri> urls = const []}) async {
    final list = await _channel.invokeMethod<List<Object?>>('cookies', {'token': token}) ?? const [];
    return [
      for (final m in list)
        if (m is Map) ?nativeCookieFromMap(m),
    ];
  }

  @override
  Future<void> setCookies(String token, List<NativeCookie> cookies) => _channel.invokeMethod<void>('setCookies', {
    'token': token,
    'cookies': [for (final c in cookies) nativeCookieToMap(c)],
  });

  @override
  Future<void> deleteCookies(String token, List<NativeCookie> cookies) => _channel.invokeMethod<void>('deleteCookies', {
    'token': token,
    'cookies': [for (final c in cookies) nativeCookieToMap(c)],
  });

  @override
  Future<void> clearData(String token) => _channel.invokeMethod<void>('clearData', {'token': token});

  @override
  Future<bool> park(String token, int width, int height) async =>
      await _channel.invokeMethod<bool>('park', {'token': token, 'width': width, 'height': height}) ?? false;

  @override
  Future<void> unfocus(String token) => _channel.invokeMethod<void>('unfocus', {'token': token});

  @override
  Future<void> setLocked(String token, bool locked) =>
      _channel.invokeMethod<void>('lock', {'token': token, 'locked': locked});

  @override
  Future<void> lendWindow(bool on) => _channel.invokeMethod<void>('lend', {'on': on});

  @override
  Future<void> setShown(String token, bool shown) =>
      _channel.invokeMethod<void>('shown', {'token': token, 'shown': shown});
}

/// Windows (WebView2): each session's browser has a WebView2 environment of its own (its own user data folder), so
/// the plugin's cookie manager for that environment is the session's store. The plugin's views there are textures
/// Flutter forwards input to, so nothing needs parking or taking the keyboard away; the Preview's absorbing layer
/// is enough. Written against the plugin's API and not run on Windows.
final class PluginWebviewNative implements WebviewNative {
  PluginWebviewNative(this.environment);

  final WebViewEnvironment? environment;

  CookieManager get _cookies => CookieManager.instance(webViewEnvironment: environment);

  @override
  Stream<WebviewNativeEvent> get events => const Stream.empty();

  @override
  Future<bool> bind(String token, {String? viewId}) async => true;

  @override
  Future<void> release(String token) async {}

  @override
  Future<List<NativeCookie>> cookies(String token, {Iterable<Uri> urls = const []}) async {
    final seen = <String, NativeCookie>{};
    for (final u in urls) {
      for (final c in await _cookies.getCookies(url: WebUri.uri(u))) {
        final n = (
          name: c.name,
          value: '${c.value ?? ''}',
          domain: c.domain ?? u.host,
          path: c.path ?? '/',
          expiresMs: c.isSessionOnly == true ? null : c.expiresDate,
          secure: c.isSecure == true,
          httpOnly: c.isHttpOnly == true,
          sameSite: c.sameSite?.toNativeValue(),
        );
        seen['${n.name}|${n.domain}|${n.path}'] = n;
      }
    }
    return seen.values.toList();
  }

  @override
  Future<void> setCookies(String token, List<NativeCookie> cookies) async {
    for (final c in cookies) {
      final host = c.domain.startsWith('.') ? c.domain.substring(1) : c.domain;
      await _cookies.setCookie(
        url: WebUri('${c.secure ? 'https' : 'http'}://$host${c.path}'),
        name: c.name,
        value: c.value,
        domain: c.domain.startsWith('.') ? c.domain : null,
        path: c.path,
        expiresDate: c.expiresMs,
        isSecure: c.secure,
        isHttpOnly: c.httpOnly,
        sameSite: c.sameSite == null ? null : HTTPCookieSameSitePolicy.fromNativeValue(c.sameSite!),
      );
    }
  }

  @override
  Future<void> deleteCookies(String token, List<NativeCookie> cookies) async {
    for (final c in cookies) {
      final host = c.domain.startsWith('.') ? c.domain.substring(1) : c.domain;
      await _cookies.deleteCookie(url: WebUri('https://$host${c.path}'), name: c.name, domain: c.domain, path: c.path);
    }
  }

  @override
  Future<void> clearData(String token) async => _cookies.deleteAllCookies();

  @override
  Future<bool> park(String token, int width, int height) async => true;

  @override
  Future<void> unfocus(String token) async {}

  @override
  Future<void> setLocked(String token, bool locked) async {}

  @override
  Future<void> lendWindow(bool on) async {}

  @override
  Future<void> setShown(String token, bool shown) async {}
}
