import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../providers/nas_provider.dart';

class NasLoginScreen extends ConsumerStatefulWidget {
  final String nasId;
  final String baseUrl;
  final String nasName;

  const NasLoginScreen({
    super.key,
    required this.nasId,
    required this.baseUrl,
    required this.nasName,
  });

  @override
  ConsumerState<NasLoginScreen> createState() => _NasLoginScreenState();
}

class _NasLoginScreenState extends ConsumerState<NasLoginScreen> {
  static const _cookieChannel = MethodChannel('nasplayer/cookies');

  late final WebViewController _controller;
  bool _loading = true;
  bool _extracting = false;
  bool _authenticated = false;
  int _autoDetectPasses = 0;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: (_) async {
          if (mounted) setState(() => _loading = false);
          await _tryAutoDetect();
        },
        onWebResourceError: (err) {
          // Sub-resource errors are common on NAS UIs; only surface
          // main-frame failures.
          if (mounted && err.isForMainFrame == true) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Load error: ${err.description}')),
            );
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.baseUrl));
  }

  /// Read the full cookie string (including HttpOnly session cookies, which
  /// JavaScript cannot see) via the platform CookieManager — design doc 8.2.
  Future<String> _readPlatformCookies() async {
    try {
      final cookies = await _cookieChannel.invokeMethod<String>(
        'getCookies',
        {'url': widget.baseUrl},
      );
      return cookies ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Fallback: JS document.cookie (non-HttpOnly cookies only).
  Future<String> _readJsCookies() async {
    try {
      final result =
          await _controller.runJavaScriptReturningResult('document.cookie');
      return _decodeJsString(result);
    } catch (_) {
      return '';
    }
  }

  /// runJavaScriptReturningResult returns JSON-encoded strings on Android
  /// ("\"a=b\"") and raw strings on other platforms — normalize both.
  String _decodeJsString(Object result) {
    var s = result.toString();
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
      try {
        s = jsonDecode(s) as String;
      } catch (_) {
        s = s.substring(1, s.length - 1);
      }
    }
    return s == 'null' ? '' : s;
  }

  /// Nextcloud requires its CSRF token alongside session cookies for
  /// cookie-authenticated WebDAV/OCS calls.
  Future<Map<String, String>> _readExtraHeaders() async {
    try {
      final result = await _controller.runJavaScriptReturningResult(
        "document.head && document.head.getAttribute('data-requesttoken') || ''",
      );
      final token = _decodeJsString(result);
      if (token.isNotEmpty) return {'requesttoken': token};
    } catch (_) {}
    return {};
  }

  /// Auto-detection is conservative: it needs TWO consecutive page loads
  /// that look logged-in (no login form) AND a session cookie present.
  /// The manual button remains the reliable path.
  Future<void> _tryAutoDetect() async {
    if (_authenticated || _extracting) return;
    try {
      final result = await _controller.runJavaScriptReturningResult(
        '''
        (function() {
          var loginForms = document.querySelectorAll(
            'form[action*="login"], input[name="username"], input[name="password"], input[type="password"]'
          ).length;
          return JSON.stringify({ hasLoginForm: loginForms > 0 });
        })()
        ''',
      );

      // Android double-encodes: unwrap until we get a JSON object.
      dynamic data = result.toString();
      for (var i = 0; i < 2 && data is String; i++) {
        try {
          data = jsonDecode(data);
        } catch (_) {
          break;
        }
      }
      if (data is! Map) return;

      final hasLoginForm = data['hasLoginForm'] as bool? ?? true;
      if (hasLoginForm) {
        _autoDetectPasses = 0;
        return;
      }

      _autoDetectPasses++;
      if (_autoDetectPasses < 2) return;

      final cookies = await _readPlatformCookies();
      if (cookies.isNotEmpty && _looksLikeSession(cookies)) {
        await _authenticateWithCookies(cookies);
      }
    } catch (_) {}
  }

  /// Heuristic: pre-login pages usually only set locale/UI cookies.
  /// Compares exact cookie NAMES so e.g. DSM's pre-login 'did' cookie is
  /// not mistaken for the 'id' session cookie.
  bool _looksLikeSession(String cookies) {
    final names = cookies
        .split(';')
        .map((c) => c.split('=').first.trim().toLowerCase())
        .toSet();
    if (names.contains('id')) return true; // Synology DSM
    if (names.contains('nas_sid') ||
        names.contains('nas_1_sid') ||
        names.contains('qtoken')) {
      return true; // QNAP
    }
    return names.any((n) =>
        n.startsWith('nc_session') || // Nextcloud
        n.startsWith('oc_sess') ||
        n.contains('session') ||
        n.contains('token'));
  }

  Future<void> _manualExtract() async {
    if (_authenticated) return;
    setState(() => _extracting = true);
    try {
      var cookies = await _readPlatformCookies();
      if (cookies.isEmpty) {
        cookies = await _readJsCookies();
      }

      if (cookies.isNotEmpty) {
        await _authenticateWithCookies(cookies);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No session cookies found. Please log in first.'),
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  Future<void> _authenticateWithCookies(String cookies) async {
    // Guard against double-authentication: NAS UIs fire several redirects
    // right after login, and a second pop would dismiss the route BELOW
    // this screen.
    if (_authenticated) return;
    _authenticated = true;

    final extraHeaders = await _readExtraHeaders();
    final vendor =
        await ref.read(authenticatedNasProvider.notifier).authenticate(
              widget.nasId,
              widget.baseUrl,
              cookies,
              extraHeaders: extraHeaders,
            );

    if (mounted) {
      final vendorLabel = vendor != null ? ' (${vendor.name})' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to ${widget.nasName}$vendorLabel')),
      );
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Login — ${widget.nasName}'),
        actions: [
          if (_extracting)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('I\'m logged in'),
              onPressed: _manualExtract,
            ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Log in to your NAS through this browser. '
            'Tap "I\'m logged in" after successfully signing in.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}
