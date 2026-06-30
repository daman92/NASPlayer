import 'dart:convert';

import 'package:flutter/material.dart';
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
  late final WebViewController _controller;
  bool _loading = true;
  bool _extracting = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) async {
          setState(() => _loading = false);
          await _tryExtractCookies();
        },
        onWebResourceError: (err) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Load error: ${err.description}')),
            );
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.baseUrl));
  }

  Future<void> _tryExtractCookies() async {
    // Check if we're logged in by looking for NAS-specific indicators
    final result = await _controller.runJavaScriptReturningResult(
      '''
      (function() {
        var cookies = document.cookie;
        var loginForms = document.querySelectorAll('form[action*="login"], input[name="username"], input[name="password"]').length;
        return JSON.stringify({ cookies: cookies, hasLoginForm: loginForms > 0 });
      })()
      ''',
    );

    try {
      final data = jsonDecode(result.toString()) as Map<String, dynamic>;
      final cookies = data['cookies'] as String? ?? '';
      final hasLoginForm = data['hasLoginForm'] as bool? ?? true;

      if (!hasLoginForm && cookies.isNotEmpty) {
        await _authenticateWithCookies(cookies);
      }
    } catch (_) {}
  }

  Future<void> _manualExtract() async {
    setState(() => _extracting = true);
    try {
      final result = await _controller.runJavaScriptReturningResult(
        'document.cookie',
      );
      final cookies = result.toString().replaceAll('"', '');

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
    await ref.read(authenticatedNasProvider.notifier).authenticate(
          widget.nasId,
          widget.baseUrl,
          cookies,
        );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to ${widget.nasName}')),
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
          if (_loading)
            const Center(child: CircularProgressIndicator()),
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
