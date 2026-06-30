import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'services/audio_handler.dart';
import 'providers/audio_provider.dart';

late NasPlayerAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  audioHandler = await AudioService.init(
    builder: () => NasPlayerAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.nas_player.audio',
      androidNotificationChannelName: 'NASPlayer Audio',
      androidNotificationOngoing: true,
      androidShowNotificationBadge: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
      notificationColor: Color(0xFF1A1A2E),
      androidStopForegroundOnPause: false,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const NasPlayerApp(),
    ),
  );
}
