import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:metadata_god/metadata_god.dart';

import 'app.dart';
import 'database/app_database.dart';
import 'providers/audio_provider.dart';
import 'services/audio_handler.dart';
import 'services/settings_service.dart';

late NasPlayerAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Required before any readMetadata call (metadata_god 1.x).
  MetadataGod.initialize();

  final database = AppDatabase.instance;
  final settings = SettingsService();

  audioHandler = await AudioService.init(
    builder: () => NasPlayerAudioHandler(db: database, settings: settings),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.nasplayer.app.audio',
      androidNotificationChannelName: 'NASPlayer Audio',
      androidNotificationOngoing: true,
      androidShowNotificationBadge: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
      notificationColor: Color(0xFF1A1A2E),
      // Must be true when androidNotificationOngoing is true (plugin assert).
      androidStopForegroundOnPause: true,
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
